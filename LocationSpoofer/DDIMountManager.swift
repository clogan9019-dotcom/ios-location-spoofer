//
//  DDIMountManager.swift
//  LocationSpoofer
//
//  Downloads and mounts the Developer Disk Image for the current iOS version,
//  mirroring the preparatory step StikDebug (StephenDev0/StikDebug) performs
//  before calling location_simulation_new().
//
//  Flow:
//   1. Check if DDI is already mounted (imagemounterd LookupImage + DTServiceHub)
//   2. Detect iOS version (e.g. "18.7.1")
//   3. Download from doronz88/DeveloperDiskImage GitHub releases:
//        iOS-{version}/DeveloperDiskImage.dmg
//        iOS-{version}/DeveloperDiskImage.dmg.signature
//      Falls back to iOS-{major.minor} then iOS-{major} if exact tag is absent.
//   4. Mount via imagemounterd XPC (ddi_mount())
//   5. Poll until DTServiceHub appears in process list (up to 6 s)
//   6. Set status → .mounted; simlocation_set() will now reach locationd directly
//
//  iOS 17+ note: doronz88 distributes pre-personalised DDIs for common releases.
//  If imagemounterd rejects the DDI (needs on-device personalisation), the user
//  must mount via Xcode once — after that subsequent boots keep the image cached.
//

import Foundation
import UIKit

// Mirrors the ddi_mount_status_t anonymous enum in ddi_mount.h.
private let kDDIStatusUnknown: Int32     = 0
private let kDDIStatusNotMounted: Int32 = 1
private let kDDIStatusMounted: Int32    = 2

@MainActor
final class DDIMountManager: ObservableObject {

    static let shared = DDIMountManager()

    // MARK: - Published state

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

    // MARK: - Computed helpers for UI

    var statusIcon: String {
        switch ddiStatus {
        case .mounted:              return "checkmark.seal.fill"
        case .failed:               return "exclamationmark.triangle.fill"
        case .downloading:          return "arrow.down.circle.fill"
        case .mounting:             return "archivebox.fill"
        case .notMounted:           return "externaldrive.badge.exclamationmark"
        default:                    return "questionmark.circle.fill"
        }
    }

    var statusIsOk: Bool { ddiStatus == .mounted }

    // MARK: - Private

    private let ddiDir = NSTemporaryDirectory() + "ddi/"
    private let dmgFilename = "DeveloperDiskImage.dmg"
    private let sigFilename = "DeveloperDiskImage.dmg.signature"
    private let baseURL = "https://github.com/doronz88/DeveloperDiskImage/releases/download"

    private init() {}

    // MARK: - Public

    func checkStatus() {
        guard ddiStatus != .checking else { return }
        ddiStatus    = .checking
        statusMessage = "Checking DDI status…"
        lastError    = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let xpcStatus = ddi_check_status()
            let dtProc    = procbyname("DTServiceHub")
            let mounted   = xpcStatus == kDDIStatusMounted || dtProc != 0
            filelog(String(format: "[DDI] check: xpc=%d DTServiceHub=%@",
                           xpcStatus.rawValue, dtProc != 0 ? "running" : "absent"))
            await MainActor.run {
                if mounted {
                    self.ddiStatus    = .mounted
                    self.statusMessage = "DDI mounted — com.apple.dt.simulatelocation available"
                } else {
                    self.ddiStatus    = .notMounted
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

    // MARK: - Mount flow (runs off main thread)

    private func runMountFlow() async {
        // Check if already mounted
        if ddi_check_status() == kDDIStatusMounted || procbyname("DTServiceHub") != 0 {
            await update(.mounted, "DDI already mounted — ready")
            return
        }

        // Resolve iOS version
        let sysVer = await MainActor.run { UIDevice.current.systemVersion }
        filelog("[DDI] iOS version: \(sysVer)")

        // Try version candidates from most- to least-specific
        let candidates = versionCandidates(from: sysVer)
        var downloadedOk = false
        var lastDownloadErr = "no candidates"

        try? FileManager.default.createDirectory(atPath: ddiDir,
             withIntermediateDirectories: true, attributes: nil)
        let dmgPath = ddiDir + dmgFilename
        let sigPath = ddiDir + sigFilename

        for tag in candidates {
            let dmgURL = "\(baseURL)/iOS-\(tag)/\(dmgFilename)"
            let sigURL = "\(baseURL)/iOS-\(tag)/\(sigFilename)"
            filelog("[DDI] trying tag iOS-\(tag)")

            await update(.downloading, "Downloading iOS \(tag) DDI…")

            do {
                try await downloadFile(from: dmgURL, to: dmgPath, from: 0.0, to: 0.82)
                try await downloadFile(from: sigURL, to: sigPath, from: 0.82, to: 1.0)

                let sz = (try? FileManager.default.attributesOfItem(atPath: dmgPath)[.size] as? Int) ?? 0
                filelog("[DDI] dmg size=\(sz)")
                guard sz > 65536 else {
                    lastDownloadErr = "Downloaded file too small for tag iOS-\(tag) (\(sz) bytes)"
                    filelog("[DDI] \(lastDownloadErr) — trying next candidate")
                    continue
                }
                downloadedOk = true
                break
            } catch {
                lastDownloadErr = error.localizedDescription
                filelog("[DDI] download error for tag iOS-\(tag): \(lastDownloadErr)")
            }
        }

        guard downloadedOk else {
            await update(.failed("Download failed: \(lastDownloadErr)"),
                         "DDI download failed — \(lastDownloadErr)")
            return
        }

        // Mount
        await update(.mounting, "Mounting DDI via imagemounterd…")
        let ret = ddi_mount(dmgPath, sigPath)
        filelog("[DDI] ddi_mount() = \(ret)")

        if ret != 0 {
            let errStr = String(cString: ddi_last_error())
            // Error 14 = already mounted (handled inside ddi_mount as success, just in case)
            await update(.failed("imagemounterd error: \(errStr)"),
                         "Mount failed: \(errStr)\n\nFor iOS 17+, pre-personalised DDIs from doronz88 are required. If this fails, mount the DDI once via Xcode.")
            return
        }

        // Poll for DTServiceHub to confirm
        var dtUp = false
        for i in 0..<20 {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
            if procbyname("DTServiceHub") != 0 {
                filelog("[DDI] DTServiceHub appeared after \(i+1) polls — DDI active")
                dtUp = true
                break
            }
        }

        if dtUp {
            await update(.mounted,
                "DDI mounted — DTServiceHub running — simlocation_set() will now work")
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
        ddiStatus    = status
        statusMessage = message
        if case .failed(let err) = status { lastError = err }
        filelog("[DDI] \(message)")
    }

    private func downloadFile(from urlStr: String, to path: String,
                               from pStart: Double, to pEnd: Double) async throws {
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        let (asyncBytes, response) = try await URLSession.shared.bytes(for:
            URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let expected = response.expectedContentLength
        let total: Double = (expected > 0) ? Double(expected) : Double.greatestFiniteMagnitude

        FileManager.default.createFile(atPath: path, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? fh.close() }

        // Manual chunking — avoids reliance on AsyncSequence.chunks(ofCount:)
        // which is only available in the iOS 18 / Xcode 16 SDKs.
        let chunkSize = 64 * 1024
        var buf = Data(capacity: chunkSize)
        var got: Double = 0
        var reportedPct: Double = pStart

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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
