//
//  DDIMountManager.swift
//  LocationSpoofer
//
//  DDI (Developer Disk Image) mount helper.
//
//  NOTE: iOS 17+ "Personalized" DDIs require device-specific signing against
//  Apple's TSS server (BuildManifest + trustcache + per-device nonce + IM4M
//  payload) — they CANNOT be mounted from a static Image.dmg alone. The only
//  way to get com.apple.dt.simulatelocation on iOS 17+ without a host Mac is
//  to have the image mounted already (e.g. by Xcode). The Darksword krw
//  path (VFS plist + heap patch + RemoteCall) is what works on every iOS
//  version regardless of DDI state, so that is our primary spoof method.
//
//  This manager still exposes a check + a "try mount" button for users
//  who are on iOS 16 or earlier (where the old DDI + signature works), and
//  reports personalized-OS users a clear message.
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
        case mounted
        case personalizationRequired
        case failed(String)

        static func == (lhs: DDIStatus, rhs: DDIStatus) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown), (.checking, .checking),
                 (.notMounted, .notMounted), (.mounted, .mounted),
                 (.personalizationRequired, .personalizationRequired): return true
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    @Published var ddiStatus:     DDIStatus = .unknown
    @Published var statusMessage: String   = "Not checked"
    @Published var lastError:     String?  = nil
    @Published var isChecking:    Bool     = false

    var statusIcon: String {
        switch ddiStatus {
        case .mounted:                  return "checkmark.seal.fill"
        case .failed:                   return "exclamationmark.triangle.fill"
        case .personalizationRequired:  return "lock.shield.fill"
        case .notMounted:               return "externaldrive.badge.exclamationmark"
        default:                        return "questionmark.circle.fill"
        }
    }

    var statusIsOk: Bool { ddiStatus == .mounted }
    var canMount:    Bool {
        if case .personalizationRequired = ddiStatus { return false }
        return !isChecking
    }

    private init() {}

    func checkStatus() {
        guard !isChecking else { return }
        isChecking = true
        ddiStatus  = .checking
        statusMessage = "Checking DDI status…"
        lastError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let xpc = ddi_check_status()
            let dt  = procbyname("DTServiceHub") != 0
            filelog(String(format: "[DDI] check: xpc=%d DTServiceHub=%@",
                           xpc, dt ? "running" : "absent"))
            await MainActor.run {
                self.isChecking = false
                if xpc == kDDIStatusMounted || dt {
                    self.ddiStatus     = .mounted
                    self.statusMessage = "DDI mounted — com.apple.dt.simulatelocation available"
                } else if ProcessInfo.processInfo.isIOS17OrLater {
                    self.ddiStatus     = .personalizationRequired
                    self.statusMessage = "iOS 17+ requires a personalized DDI (mount once via Xcode). Spoof works via Darksword krw without it."
                } else {
                    self.ddiStatus     = .notMounted
                    self.statusMessage = "DDI not mounted"
                }
            }
        }
    }
}

private extension ProcessInfo {
    var isIOS17OrLater: Bool {
        let parts = operatingSystemVersionString
            .split(separator: " ").first?
            .split(separator: ".") ?? []
        if let major = parts.first, let v = Int(major), v >= 17 { return true }
        return operatingSystemVersion.majorVersion >= 17
    }
}
