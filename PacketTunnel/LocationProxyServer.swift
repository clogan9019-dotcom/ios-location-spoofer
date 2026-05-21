import Foundation
import Network

class LocationProxyServer {
    private let port: Int
    private var spoofLat: Double
    private var spoofLon: Double
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.personal.locationspoofer.proxy", qos: .userInitiated)

    private let appleLocationHosts: Set<String> = [
        "gsp-ssl.ls.apple.com",
        "gspe1.apple.com",
        "gspe35-ssl.ls.apple.com",
        "configuration.ls.apple.com",
        "gs.apple.com"
    ]

    init(port: Int, spoofLat: Double, spoofLon: Double) {
        self.port = port
        self.spoofLat = spoofLat
        self.spoofLon = spoofLon
    }

    func updateCoordinates(lat: Double, lon: Double) {
        spoofLat = lat
        spoofLon = lon
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else { return }

        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPConnect(connection: connection)
    }

    private func readHTTPConnect(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            if request.hasPrefix("CONNECT ") {
                self.handleCONNECT(request: request, clientConnection: connection, requestData: data)
            } else {
                self.handleHTTP(request: request, clientConnection: connection, requestData: data)
            }
        }
    }

    private func handleCONNECT(request: String, clientConnection: NWConnection, requestData: Data) {
        guard let hostPort = extractHostPort(from: request) else {
            clientConnection.cancel()
            return
        }

        let isAppleLocation = appleLocationHosts.contains(hostPort.host)

        let serverEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostPort.host),
            port: NWEndpoint.Port(rawValue: UInt16(hostPort.port) ?? 443) ?? 443
        )
        let serverConnection = NWConnection(to: serverEndpoint, using: .tls)

        serverConnection.start(queue: queue)

        let okResponse = "HTTP/1.1 200 Connection Established\r\n\r\n"
        clientConnection.send(content: okResponse.data(using: .utf8)!, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            if isAppleLocation {
                self.tunnelWithLocationInterception(client: clientConnection, server: serverConnection)
            } else {
                self.forwardBidirectional(client: clientConnection, server: serverConnection)
            }
        })
    }

    private func handleHTTP(request: String, clientConnection: NWConnection, requestData: Data) {
        guard let hostPort = extractHostFromHTTP(from: request) else {
            clientConnection.cancel()
            return
        }

        let serverEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostPort.host),
            port: NWEndpoint.Port(rawValue: UInt16(hostPort.port) ?? 80) ?? 80
        )
        let serverConnection = NWConnection(to: serverEndpoint, using: .tcp)
        serverConnection.start(queue: queue)
        serverConnection.send(content: requestData, completion: .contentProcessed { _ in })
        forwardBidirectional(client: clientConnection, server: serverConnection)
    }

    private func tunnelWithLocationInterception(client: NWConnection, server: NWConnection) {
        pipeData(from: client, to: server)
        receiveAndPatchLocationResponse(server: server, client: client)
    }

    private func receiveAndPatchLocationResponse(server: NWConnection, client: NWConnection) {
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete { client.cancel() }
                return
            }
            let patched = self.patchLocationData(data)
            client.send(content: patched, completion: .contentProcessed { _ in })
            if !isComplete {
                self.receiveAndPatchLocationResponse(server: server, client: client)
            }
        }
    }

    private func pipeData(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if !isComplete && error == nil {
                self.pipeData(from: source, to: destination)
            } else {
                destination.cancel()
            }
        }
    }

    private func forwardBidirectional(client: NWConnection, server: NWConnection) {
        pipeData(from: client, to: server)
        pipeData(from: server, to: client)
    }

    // MARK: - Location Data Patching

    private func patchLocationData(_ data: Data) -> Data {
        var bytes = [UInt8](data)

        // Apple's WiFi location protocol response contains coordinates as
        // IEEE 754 little-endian doubles. Scan for plausible lat/lon pairs.
        // Latitude range: -90.0 to 90.0  Longitude range: -180.0 to 180.0
        guard bytes.count >= 16 else { return data }

        for i in 0...(bytes.count - 16) {
            guard let candidateLat = readDouble(bytes: bytes, offset: i),
                  let candidateLon = readDouble(bytes: bytes, offset: i + 8) else { continue }

            if isValidLatitude(candidateLat) && isValidLongitude(candidateLon) &&
               abs(candidateLat) > 0.001 && abs(candidateLon) > 0.001 {
                writeDouble(value: spoofLat, into: &bytes, offset: i)
                writeDouble(value: spoofLon, into: &bytes, offset: i + 8)
            }
        }

        return Data(bytes)
    }

    private func readDouble(bytes: [UInt8], offset: Int) -> Double? {
        guard offset + 8 <= bytes.count else { return nil }
        var raw: UInt64 = 0
        for i in 0..<8 {
            raw |= UInt64(bytes[offset + i]) << (i * 8)
        }
        let value = Double(bitPattern: raw)
        guard value.isFinite else { return nil }
        return value
    }

    private func writeDouble(value: Double, into bytes: inout [UInt8], offset: Int) {
        let raw = value.bitPattern
        for i in 0..<8 {
            bytes[offset + i] = UInt8((raw >> (i * 8)) & 0xFF)
        }
    }

    private func isValidLatitude(_ v: Double) -> Bool { v >= -90.0 && v <= 90.0 }
    private func isValidLongitude(_ v: Double) -> Bool { v >= -180.0 && v <= 180.0 }

    // MARK: - Helpers

    private func extractHostPort(from connectRequest: String) -> (host: String, port: Int)? {
        let lines = connectRequest.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let hostPort = parts[1]
        let components = hostPort.components(separatedBy: ":")
        if components.count == 2, let port = Int(components[1]) {
            return (components[0], port)
        }
        return (hostPort, 443)
    }

    private func extractHostFromHTTP(from request: String) -> (host: String, port: Int)? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("host:") {
                let hostValue = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let parts = hostValue.components(separatedBy: ":")
                if parts.count == 2, let port = Int(parts[1]) {
                    return (parts[0], port)
                }
                return (hostValue, 80)
            }
        }
        return nil
    }
}
