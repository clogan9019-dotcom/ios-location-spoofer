//
//  DDIMountManager.swift
//  LocationSpoofer
//
//  Downloads and mounts the Developer Disk Image for the current iOS version,
//  mirroring the preparatory step StikDebug performs before calling
//  location_simulation_new().
//
//  Flow:
//   1. Check if DDI is already mounted (imagemounterd LookupImage + DTServiceHub)
//   2. Detect iOS version
//   3. Try the *personalized* DDI from doronz88's main branch (iOS 17+). This
//      is the single Image.dmg published by Apple that works for any 17+ build
//      (it's signed for personalisation on-device — the same file Xcode uses).
//   4. Fall back to version-tagged release DDIs for pre-17 builds, then the
//      mspvirajpatel mirror.
//   5. Mount via imagemounterd XPC (ddi_mount())
//   6. Poll until DTServiceHub appears (up to 6 s)
//

import Foundation
import UIKit

private let kDDIStatusUnknown: Int32     = 0
private let kDDIStatusNotMounted: Int32 = 1
private let kDDIStatusMounted: Int32    = 2

@MainActor
final class DDIMountManager: ObservableObject {

    static let shared = DDIMountManager()

    enum DDIStatus: Equatable {
        case unknown
        case checking
        case notMounted
        case downloading
        case mounting
        case mounted
        case failed(String)

        static func == (lhs: DDIStatus, rhs: DDIStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown), (.checking, .checking),
                 (.notMounted, .notMounted), (.downloading, .downloading),
                 (.mounting, .mounting), (.mounted, .mounted): return true
            case let (.failed(a), .failed(b)):               return a == b
            default:                                          return false
            }
        }
    }

    @Published var ddiStatus:        DDIStatus = .unknown
    @Published var downloadProgress: Double    = 0.0
    @Published var isMounting:       Bool      = false
    @Published var statusMessage:    String    = "Not checked"
    @Published var lastError:        String?   = nil

    var statusIcon: String {
        switch ddiStatus {
        case .mounted:     return "checkmark.seal.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .mounting:    return "archivebox.fill"
        case .notMounted:  return "externaldrive.badge.exclamationmark"
        default:           return "questionmark.circle.fill"
        }
    }

    var statusIsOk: Bool { ddiStatus == .mounted }

    private let ddiDir = NSTemporaryDirectory() + "ddi/"
    private let dmgFilename = "DeveloperDiskImage.dmg"
    private let sigFilename = "DeveloperDiskImage.dmg.signature"
    private let releaseBaseURL = "https://github.com/doronz88/DeveloperDiskImage/releases/download"
    private let personalizedBase =
        "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized"

    private init() {}

    // MARK: - Public

    func checkStatus() {
        guard ddiStatus != .checking else { return }
        ddiStatus     = .checking
        statusMessage = "Checking DDI status…"
        lastError     = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let xpc = ddi_check_status()
            let dt  = procbyname("DTServiceHub")
            let mounted = xpc == kDDIStatusMounted || dt != 0
            filelog(String(format: "[DDI] check: xpc=%d DTServiceHub=%@",
                           xpc, dt != 0 ? "running" : "absent"))
            await MainActor.run {
                if mounted {
                    self.ddiStatus     = .mounted
                    self.statusMessage = "DDI mounted — com.apple.dt.simulatelocation available"
                } else {
                    self.ddiStatus     = .notMounted
                    self.statusMessage = "DDI not mounted — tap Mount to enable the StikDebug path"
                }
            }
        }
    }

    func mountDDI() {
        guard !isMounting else { return }
        isMounting       = true
        ddiStatus        = .downloading
        statusMessage    = "Starting DDI mount…"
        lastError        = nil
        downloadProgress = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runMountFlow()
            await MainActor.run { self.isMounting = false }
        }
    }

    // MARK: - Mount flow

    private struct Source { let label: String; let dmg: String; let sig: String }

    private func runMountFlow() async {
        if ddi_check_status() == kDDIStatusMounted || procbyname("DTServiceHub") != 0 {
            await update(.mounted, "DDI already mounted — ready")
            return
        }

        let sysVer = await MainActor.run { UIDevice.current.systemVersion }
        filelog("[DDI] iOS version: \(sysVer)")
        let parts = sysVer.split(separator: ".")
        let major = Int(parts[0]) ?? 0

        try? FileManager.default.createDirectory(atPath: ddiDir,
             withIntermediateDirectories: true, attributes: nil)
        let dmgPath = ddiDir + dmgFilename
        let sigPath = ddiDir + sigFilename

        await update(.downloading, "Downloading DDI…")

        var sources: [Source] = []

        // iOS 17+ uses the single personalized DDI that ships with Xcode.
        if major >= 17 {
            sources.append(Source(
                label: "personalized (iOS 17+)",
                dmg: "\(personalizedBase)/Image.dmg",
                sig: "\(personalizedBase)/Image.dmg.signature"
            ))
        }

        // Version-tagged release DDIs (pre-17 mostly).
        for tag in versionCandidates(from: sysVer) {
            sources.append(Source(
                label: "iOS-\(tag)",
                dmg: "\(releaseBaseURL)/iOS-\(tag)/\(dmgFilename)",
                sig: "\(releaseBaseURL)/iOS-\(tag)/\(sigFilename)"
            ))
        }

        // Mirror fallback (mspvirajpatel's Xcode_Developer_Disk_Images repo).
        if parts.count >= 2 {
            let mm = "\(parts[0]).\(parts[1])"
            let encMm = mm.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mm
            sources.append(Source(
                label: "mirror iOS-\(mm)",
                dmg: "https://github.com/mspvirajpatel/Xcode_Developer_Disk_Images/raw/master/Developer%20Disk%20Image/\(encMm)/DeveloperDiskImage.dmg",
                sig: "https://github.com/mspvirajpatel/Xcode_Developer_Disk_Images/raw/master/Developer%20Disk%20Image/\(encMm)/DeveloperDiskImage.dmg.signature"
            ))
        }

        var downloaded = false
        var lastErr = "no sources"
        for src in sources {
            filelog("[DDI] trying source: \(src.label)")
            do {
                try? FileManager.default.removeItem(atPath: dmgPath)
                try? FileManager.default.removeItem(atPath: sigPath)

                try await downloadFile(from: src.dmg, to: dmgPath, from: 0.0, to: 0.85)
                try await downloadFile(from: src.sig, to: sigPath, from: 0.85, to: 1.0)

                let sz  = (try? FileManager.default.attributesOfItem(atPath: dmgPath)[.size] as? Int) ?? 0
                let ssz = (try? FileManager.default.attributesOfItem(atPath: sigPath)[.size] as? Int) ?? 0
                filelog("[DDI] source \(src.label): dmg=\(sz) sig=\(ssz)")
                guard sz > 65536, ssz > 16 else {
                    lastErr = "source \(src.label) returned unusable files"
                    continue
                }
                downloaded = true
                break
            } catch {
                lastErr = "\(src.label): \(error.localizedDescription)"
                filelog("[DDI] source \(src.label) failed: \(lastErr)")
            }
        }

        guard downloaded else {
            await update(.failed("Download failed: \(lastErr)"),
                         "DDI download failed — \(lastErr)")
            return
        }

        await update(.mounting, "Mounting DDI via imagemounterd…")
        let ret = ddi_mount(dmgPath, sigPath)
        filelog("[DDI] ddi_mount() = \(ret)")

        if ret != 0 {
            let errStr = String(cString: ddi_last_error())
            await update(.failed("imagemounterd error: \(errStr)"),
                         "Mount failed: \(errStr)\n\nIf the personalized DDI is rejected, mount once via Xcode then retry.")
            return
        }

        var dtUp = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if procbyname("DTServiceHub") != 0 { dtUp = true; break }
        }

        if dtUp {
            filelog("[DDI] DTServiceHub appeared — DDI active")
            await update(.mounted,
                "DDI mounted — DTServiceHub running — simlocation_set() ready")
        } else {
            await update(.mounted,
                "DDI mounted (DTServiceHub may take a moment to start)")
        }
    }

    // MARK: - Helpers

    private func versionCandidates(from version: String) -> [String] {
        var result = [version]
        let parts = version.split(separator: ".")
        if parts.count >= 3 { result.append("\(parts[0]).\(parts[1])") }
        if parts.count >= 2 { result.append("\(parts[0])") }
        return result
    }

    @MainActor
    private func update(_ status: DDIStatus, _ message: String) {
        ddiStatus     = status
        statusMessage = message
        if case .failed(let err) = status { lastError = err }
        else                            { lastError = nil }
        filelog("[DDI] \(message)")
    }

    private func downloadFile(from urlStr: String, to path: String,
                               from pStart: Double, to pEnd: Double) async throws {
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        // GitHub raw/release URLs 302-redirect to S3/camo; URLSession handles
        // redirects by default. We disallow cached responses so a 404 from a
        // previous attempt doesn't stick.
        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 180)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            filelog("[DDI] HTTP \(code) for \(urlStr)")
            throw URLError(.badServerResponse)
        }
        let expected = response.expectedContentLength
        let total: Double = (expected > 0) ? Double(expected) : Double.greatestFiniteMagnitude

        FileManager.default.createFile(atPath: path, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? fh.close() }

        let chunkSize = 64 * 1024
        var buf = Data(capacity: chunkSize)
        var got: Double = 0
        var reportedPct = pStart

        for try await byte in asyncBytes {
            buf.append(byte)
            if buf.count >= chunkSize {
                fh.write(buf)
                got += Double(buf.count)
                buf.removeAll(keepingCapacity: true)
                if total.isFinite {
                    let p = pStart + min(got / total, 1.0) * (pEnd - pStart)
                    if p - reportedPct >= 0.01 {
                        reportedPct = p
                        await MainActor.run { self.downloadProgress = p }
                    }
                }
            }
        }
        if !buf.isEmpty {
            fh.write(buf)
            got += Double(buf.count)
        }
        await MainActor.run { self.downloadProgress = pEnd }
    }
}
