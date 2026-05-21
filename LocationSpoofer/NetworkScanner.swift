import Foundation
import Network
import Darwin

// MARK: - Types

enum ScanType: String, CaseIterable, Identifiable {
    case tcpConnect = "TCP Connect"
    case udp        = "UDP"
    case stealth    = "SYN Stealth"

    var id: String { rawValue }

    var requiresExploit: Bool { self == .stealth }

    var icon: String {
        switch self {
        case .tcpConnect: return "network"
        case .udp:        return "arrow.left.arrow.right.circle.fill"
        case .stealth:    return "eye.slash.fill"
        }
    }

    var detail: String {
        switch self {
        case .tcpConnect: return "Full 3-way handshake. Reliable, detectable."
        case .udp:        return "UDP probe. open|filtered if no response."
        case .stealth:    return "SYN only, never completes handshake. Requires kernel exploit."
        }
    }
}

enum PortStatus: String {
    case open         = "open"
    case closed       = "closed"
    case filtered     = "filtered"
    case openFiltered = "open|filtered"
}

struct ScanResult: Identifiable {
    let id        = UUID()
    let port      : Int
    let proto     : String
    let status    : PortStatus
    let latencyMs : Double?
}

enum PortPreset: String, CaseIterable, Identifiable {
    case top20    = "Top 20"
    case top100   = "Top 100"
    case top1000  = "Top 1000"
    case custom   = "Custom"

    var id: String { rawValue }

    var ports: [Int] {
        switch self {
        case .top20:
            return [21,22,23,25,53,80,110,111,135,139,143,443,445,993,995,1723,3306,3389,5900,8080]
        case .top100:
            return [1,7,9,13,21,22,23,25,26,37,53,79,80,81,88,106,110,111,113,119,
                    135,139,143,144,179,199,389,427,443,444,445,465,513,514,515,543,
                    544,548,554,587,631,646,873,990,993,995,1080,1099,1433,1521,1720,
                    1723,1755,1900,2000,2001,2049,2121,2717,3000,3128,3306,3389,3986,
                    4899,5000,5009,5051,5060,5101,5190,5357,5432,5631,5666,5800,5900,
                    6000,6001,6646,7070,8000,8008,8009,8080,8081,8443,8888,9100,9999,
                    10000,32768,49152,49153,49154,49155,49156,49157]
        case .top1000:
            return Array(1...1000)
        case .custom:
            return []
        }
    }
}

// MARK: - Scanner Engine

final class NetworkScanner: ObservableObject {
    @Published var results    : [ScanResult] = []
    @Published var isScanning : Bool         = false
    @Published var progress   : Double       = 0
    @Published var logLines   : [String]     = []
    @Published var openCount  : Int          = 0

    private var cancelFlag = false
    private let lock = NSLock()

    func cancel() { cancelFlag = true }

    private func appendLog(_ msg: String) {
        DispatchQueue.main.async { self.logLines.append(msg) }
    }

    // MARK: Public entry

    func start(host: String, ports: [Int], type: ScanType, concurrency: Int = 64) {
        guard !host.isEmpty, !ports.isEmpty, !isScanning else { return }
        DispatchQueue.main.async {
            self.isScanning  = true
            self.cancelFlag  = false
            self.results     = []
            self.logLines    = []
            self.progress    = 0
            self.openCount   = 0
        }
        appendLog("[\(type.rawValue)] Scanning \(host) — \(ports.count) port(s)")

        let total = Double(ports.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let sem   = DispatchSemaphore(value: concurrency)
            let group = DispatchGroup()
            var done  = 0
            let dlock = NSLock()

            for port in ports {
                if self.cancelFlag { break }
                sem.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { sem.signal(); group.leave() }
                    guard !self.cancelFlag else { return }

                    let result: ScanResult
                    switch type {
                    case .tcpConnect: result = self.tcpConnect(host: host, port: port)
                    case .udp:        result = self.udpProbe(host: host, port: port)
                    case .stealth:    result = self.synScan(host: host, port: port)
                    }

                    dlock.lock(); done += 1
                    let p = Double(done) / total
                    dlock.unlock()

                    if result.status == .open || result.status == .openFiltered {
                        DispatchQueue.main.async {
                            self.results.append(result)
                            self.openCount += 1
                        }
                        let lat = result.latencyMs.map { String(format: " %.0fms", $0) } ?? ""
                        self.appendLog("  \(port)/\(result.proto.lowercased()) \(result.status.rawValue)\(lat)")
                    }
                    DispatchQueue.main.async { self.progress = p }
                }
            }

            group.wait()
            DispatchQueue.main.async {
                self.isScanning = false
                self.progress   = 1.0
                self.appendLog("Done — \(self.openCount) open of \(ports.count) scanned")
            }
        }
    }

    // MARK: TCP Connect

    private func tcpConnect(host: String, port: Int) -> ScanResult {
        let sem   = DispatchSemaphore(value: 0)
        var status: PortStatus = .filtered
        var latency: Double?   = nil
        let t0 = Date()

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp)

        conn.stateUpdateHandler = { [weak conn] state in
            switch state {
            case .ready:
                latency = Date().timeIntervalSince(t0) * 1000
                status  = .open
                conn?.cancel()
                sem.signal()
            case .failed(let err):
                latency = Date().timeIntervalSince(t0) * 1000
                status  = self.nwErrStatus(err)
                sem.signal()
            case .waiting(let err):
                if case .posix(let e) = err, e == .ECONNREFUSED {
                    status = .closed
                    conn?.cancel()
                    sem.signal()
                }
            default: break
            }
        }
        conn.start(queue: .global(qos: .background))
        if sem.wait(timeout: .now() + 2.5) == .timedOut {
            status = .filtered
            conn.cancel()
        }
        return ScanResult(port: port, proto: "TCP", status: status, latencyMs: latency)
    }

    // MARK: UDP

    private func udpProbe(host: String, port: Int) -> ScanResult {
        let sem    = DispatchSemaphore(value: 0)
        var status : PortStatus = .openFiltered

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .udp)

        conn.stateUpdateHandler = { [weak conn] state in
            switch state {
            case .ready:
                conn?.send(content: Data([0x00, 0x00]), completion: .contentProcessed { _ in })
                conn?.receiveMessage { _, _, _, error in
                    if let err = error {
                        let s = self.nwErrStatus(err)
                        status = (s == .filtered) ? .openFiltered : s
                    } else {
                        status = .open
                    }
                    conn?.cancel()
                    sem.signal()
                }
            case .failed(let err):
                let s = self.nwErrStatus(err)
                status = (s == .closed) ? .closed : .openFiltered
                sem.signal()
            default: break
            }
        }
        conn.start(queue: .global(qos: .background))
        if sem.wait(timeout: .now() + 3.0) == .timedOut {
            status = .openFiltered
            conn.cancel()
        }
        return ScanResult(port: port, proto: "UDP", status: status, latencyMs: nil)
    }

    // MARK: SYN Stealth (requires SOCK_RAW — sandbox escape must have run first)

    private func synScan(host: String, port: Int) -> ScanResult {
        let sock = Darwin.socket(AF_INET, SOCK_RAW, IPPROTO_TCP)
        guard sock >= 0 else {
            return ScanResult(port: port, proto: "TCP", status: .filtered, latencyMs: nil)
        }
        defer { Darwin.close(sock) }

        var one: Int32 = 1
        Darwin.setsockopt(sock, IPPROTO_IP, IP_HDRINCL, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        Darwin.setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dstAddr = sockaddr_in()
        withUnsafeMutableBytes(of: &dstAddr) { memset($0.baseAddress, 0, $0.count) }
        dstAddr.sin_family = sa_family_t(AF_INET)
        dstAddr.sin_port   = 0

        if Darwin.inet_aton(host, &dstAddr.sin_addr) == 0 {
            var hints = addrinfo()
            hints.ai_family   = AF_INET
            hints.ai_socktype = SOCK_RAW
            var res: UnsafeMutablePointer<addrinfo>? = nil
            guard Darwin.getaddrinfo(host, nil, &hints, &res) == 0, let res else {
                return ScanResult(port: port, proto: "TCP", status: .filtered, latencyMs: nil)
            }
            defer { Darwin.freeaddrinfo(res) }
            let sa = res.pointee.ai_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            dstAddr.sin_addr = sa.sin_addr
        }

        let srcAddr = localIPv4Addr()
        let srcPort = UInt16.random(in: 49152...65535)
        let packet  = buildSYN(srcAddr: srcAddr, srcPort: srcPort,
                               dstAddr: dstAddr.sin_addr.s_addr, dstPort: UInt16(port))

        let sent: ssize_t = packet.withUnsafeBytes { pkt in
            withUnsafeBytes(of: dstAddr) { dst in
                Darwin.sendto(sock, pkt.baseAddress, packet.count, 0,
                              dst.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                              socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else {
            return ScanResult(port: port, proto: "TCP", status: .filtered, latencyMs: nil)
        }

        let t0  = Date()
        var buf = [UInt8](repeating: 0, count: 65536)
        var status: PortStatus = .filtered

        while Date().timeIntervalSince(t0) < 2.0 {
            let n = Darwin.recv(sock, &buf, buf.count, 0)
            guard n >= 40 else { continue }
            let ipHL = Int(buf[0] & 0x0F) * 4
            guard n >= ipHL + 20 else { continue }
            let rSrc   = (UInt16(buf[ipHL])     << 8) | UInt16(buf[ipHL + 1])
            let rDst   = (UInt16(buf[ipHL + 2]) << 8) | UInt16(buf[ipHL + 3])
            let flags  = buf[ipHL + 13]
            guard rSrc == UInt16(port), rDst == srcPort else { continue }
            if flags & 0x12 == 0x12 { status = .open }
            else if flags & 0x04 != 0 { status = .closed }
            break
        }

        let lat = Date().timeIntervalSince(t0) * 1000
        return ScanResult(port: port, proto: "TCP", status: status,
                          latencyMs: status == .open ? lat : nil)
    }

    // MARK: Packet builder

    private func buildSYN(srcAddr: UInt32, srcPort: UInt16,
                          dstAddr: UInt32, dstPort: UInt16) -> Data {
        let seq = UInt32.random(in: 0...UInt32.max)
        var pkt = Data(count: 40)

        // IP header (bytes 0–19)
        pkt[0]  = 0x45
        pkt[1]  = 0x00
        pkt[2]  = 0x00; pkt[3] = 0x28
        pkt[4]  = UInt8.random(in: 0...255)
        pkt[5]  = UInt8.random(in: 0...255)
        pkt[6]  = 0x40; pkt[7] = 0x00
        pkt[8]  = 64
        pkt[9]  = 6
        pkt[10] = 0x00; pkt[11] = 0x00
        let srcB = uint32Bytes(srcAddr)
        pkt[12] = srcB[0]; pkt[13] = srcB[1]; pkt[14] = srcB[2]; pkt[15] = srcB[3]
        let dstB = uint32Bytes(dstAddr)
        pkt[16] = dstB[0]; pkt[17] = dstB[1]; pkt[18] = dstB[2]; pkt[19] = dstB[3]

        // TCP header (bytes 20–39)
        pkt[20] = UInt8(srcPort >> 8);  pkt[21] = UInt8(srcPort & 0xFF)
        pkt[22] = UInt8(dstPort >> 8);  pkt[23] = UInt8(dstPort & 0xFF)
        pkt[24] = UInt8(seq >> 24);     pkt[25] = UInt8((seq >> 16) & 0xFF)
        pkt[26] = UInt8((seq >> 8) & 0xFF); pkt[27] = UInt8(seq & 0xFF)
        pkt[28] = 0; pkt[29] = 0; pkt[30] = 0; pkt[31] = 0
        pkt[32] = 0x50
        pkt[33] = 0x02
        pkt[34] = 0xFF; pkt[35] = 0xFF
        pkt[36] = 0x00; pkt[37] = 0x00
        pkt[38] = 0x00; pkt[39] = 0x00

        let tc = tcpChecksum(pkt: pkt, src: srcAddr, dst: dstAddr)
        pkt[36] = UInt8(tc >> 8); pkt[37] = UInt8(tc & 0xFF)

        let ic = ipChecksum(pkt: pkt, offset: 0, len: 20)
        pkt[10] = UInt8(ic >> 8); pkt[11] = UInt8(ic & 0xFF)

        return pkt
    }

    private func uint32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func ipChecksum(pkt: Data, offset: Int, len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = offset
        while i < offset + len - 1 {
            sum += UInt32(pkt[i]) << 8 | UInt32(pkt[i + 1])
            i += 2
        }
        if len % 2 != 0 { sum += UInt32(pkt[offset + len - 1]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    private func tcpChecksum(pkt: Data, src: UInt32, dst: UInt32) -> UInt16 {
        var pseudo = Data(count: 32)
        let sB = uint32Bytes(src), dB = uint32Bytes(dst)
        pseudo[0]  = sB[0]; pseudo[1]  = sB[1]; pseudo[2]  = sB[2]; pseudo[3]  = sB[3]
        pseudo[4]  = dB[0]; pseudo[5]  = dB[1]; pseudo[6]  = dB[2]; pseudo[7]  = dB[3]
        pseudo[8]  = 0
        pseudo[9]  = 6
        pseudo[10] = 0; pseudo[11] = 20
        for i in 0..<20 { pseudo[12 + i] = pkt[20 + i] }
        return ipChecksum(pkt: pseudo, offset: 0, len: 32)
    }

    private func localIPv4Addr() -> UInt32 {
        var addrs: UnsafeMutablePointer<ifaddrs>? = nil
        guard Darwin.getifaddrs(&addrs) == 0 else { return 0 }
        defer { Darwin.freeifaddrs(addrs) }
        var cur = addrs
        while let a = cur {
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let name = String(cString: a.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    return sin.sin_addr.s_addr
                }
            }
            cur = a.pointee.ifa_next
        }
        return 0
    }

    // MARK: Helpers

    private func nwErrStatus(_ err: NWError) -> PortStatus {
        if case .posix(let e) = err {
            if e == .ECONNREFUSED                    { return .closed   }
            if e == .ETIMEDOUT                       { return .filtered }
            if e == .ENETUNREACH || e == .EHOSTUNREACH { return .filtered }
        }
        return .filtered
    }
}
