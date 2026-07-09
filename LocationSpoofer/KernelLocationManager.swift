import Foundation
import Combine
import CoreLocation
import UIKit
import Darwin

final class KernelLocationManager: NSObject, ObservableObject {
    static let shared = KernelLocationManager()

    @Published var isConnected: Bool     = false
    @Published var status: String        = "Idle"
    @Published var progress: Double      = 0.0
    @Published var logs: [String]        = []
    @Published var isRunning: Bool       = false
    @Published var exploitReady: Bool    = false
    @Published var exploitError: String? = nil
    @Published var t1szBootDisplay: String = "Auto"
    @Published var logFilePath: String   = ""

    private let kLastLat      = "spoofer_last_lat"
    private let kLastLon      = "spoofer_last_lon"
    private let kWasConnected = "spoofer_was_connected"
    private let kT1szOverride = "spoofer_t1sz_override"
    private let kLaraT1sz     = "lara.t1sz_boot"

    private var cancelRequested = false
    private var workItem: DispatchWorkItem?
    private let bgLocationManager = CLLocationManager()

    private var spoofLat: Double = 0
    private var spoofLon: Double = 0
    private var spoofTimer: DispatchSourceTimer?
    private let spoofQueue = DispatchQueue(label: "com.locationspoofer.spoof", qos: .userInitiated)
    private var didActivateSpoof = false
    private var lastTimerRestart: Date = .distantPast
    private let kTimerRestartInterval: Double = 5.0
    private var timerTickCount = 0

    private override init() {
        super.init()
        filelog_init()
        logFilePath = String(cString: filelog_path())
        loadT1szDisplay()
        logDeviceInfo()
        setupBackgroundLocation()
    }

    private func setupBackgroundLocation() {
        bgLocationManager.delegate = self
        bgLocationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        bgLocationManager.distanceFilter = kCLDistanceFilterNone
        bgLocationManager.allowsBackgroundLocationUpdates = true
        bgLocationManager.pausesLocationUpdatesAutomatically = false
        bgLocationManager.requestAlwaysAuthorization()
        bgLocationManager.startUpdatingLocation()
    }

    // MARK: - Device diagnostics

    private func logDeviceInfo() {
        let device = UIDevice.current
        flog("--- Device Info ---")
        flog("Model     : \(device.model)")
        flog("iOS       : \(device.systemVersion)")
        flog("Name      : \(device.name)")
        flog("t1sz cfg  : \(t1szBootDisplay)")
        flog("Log file  : \(logFilePath)")
        flog("-------------------")
        filelog_flush()
    }

    // MARK: - t1sz_boot

    private func loadT1szDisplay() {
        let stored = UserDefaults.standard.object(forKey: kT1szOverride) as? UInt64 ?? 0
        if stored != 0 {
            t1szBootDisplay = String(format: "0x%02X (manual)", stored)
        } else {
            let lara = UserDefaults.standard.object(forKey: kLaraT1sz) as? UInt64 ?? 0
            t1szBootDisplay = lara != 0
                ? String(format: "0x%02X (auto-detected)", lara)
                : "Auto (not yet resolved)"
        }
    }

    /// Main-thread helper for SwiftUI lifecycle callbacks.
    func loadT1szDisplayFromMain() {
        loadT1szDisplay()
    }

    @discardableResult
    func setT1szBootOverride(_ hexString: String) -> Bool {
        let cleaned = hexString.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard let value = UInt64(cleaned, radix: 16), value > 0 else { return false }
        UserDefaults.standard.set(value, forKey: kT1szOverride)
        UserDefaults.standard.set(value, forKey: kLaraT1sz)
        UserDefaults.standard.synchronize()
        t1szBootDisplay = String(format: "0x%02X (manual)", value)
        flog("t1sz_boot override set to 0x\(String(format: "%02X", value))")
        return true
    }

    func clearT1szBootOverride() {
        UserDefaults.standard.removeObject(forKey: kT1szOverride)
        UserDefaults.standard.removeObject(forKey: kLaraT1sz)
        UserDefaults.standard.synchronize()
        t1szBootDisplay = "Auto (not yet resolved)"
        flog("t1sz_boot override cleared — will auto-detect")
    }

    // MARK: - Logging helpers

    private func flog(_ msg: String) {
        filelog(msg)
        appendLog(msg)
    }

    func appendLog(_ msg: String) {
        DispatchQueue.main.async { self.logs.append(msg) }
    }

    func clearLogs() {
        logs = []
        filelog_clear()
        filelog_init()
        logFilePath = String(cString: filelog_path())
        flog("Log cleared by user")
    }

    // MARK: - Exploit runner

    func runExploit(completion: ((Bool) -> Void)? = nil) {
        guard !isRunning else { flog("runExploit: already running, ignoring"); return }

        DispatchQueue.main.async {
            self.isRunning       = true
            self.exploitReady    = false
            self.exploitError    = nil
            self.progress        = 0.0
            self.status          = "Starting exploit..."
            self.cancelRequested = false
        }

        let override = UserDefaults.standard.object(forKey: kT1szOverride) as? UInt64 ?? 0
        if override != 0 {
            UserDefaults.standard.set(override, forKey: kLaraT1sz)
            flog(String(format: "runExploit: applying t1sz_boot override 0x%02X", override))
        } else {
            flog("runExploit: using auto t1sz_boot")
        }

        flog("runExploit: setting log/progress callbacks")
        ds_set_log_callback { msg in
            guard let msg else { return }
            let s = String(cString: msg)
            filelog(("[ds_run] " + s))
            KernelLocationManager.shared.appendLog(s)
            DispatchQueue.main.async { KernelLocationManager.shared.status = s }
        }
        ds_set_progress_callback { pct in
            let p = Double(pct)
            filelog(String(format: "[ds_run] progress: %.1f%%", p * 100))
            DispatchQueue.main.async { KernelLocationManager.shared.progress = p }
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }

            if self.cancelRequested {
                self.flog("runExploit: cancelled before start")
                DispatchQueue.main.async { self.isRunning = false; self.status = "Cancelled"; self.progress = 0 }
                completion?(false); return
            }

            self.flog("runExploit: calling ds_run_safe()...")
            filelog_flush()

            let ret = ds_run_safe()

            if ret < 0 {
                let sigName = String(cString: ds_run_safe_signal_name())
                let err = "Exploit crashed — caught \(sigName)"
                self.flog("CRASH: \(err)")
                filelog_flush()
                LogUploader.shared.uploadLog()
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            if self.cancelRequested {
                self.flog("runExploit: cancelled after ds_run")
                DispatchQueue.main.async { self.isRunning = false; self.status = "Stopped"; self.progress = 0 }
                completion?(false); return
            }

            let resolvedT1sz = UserDefaults.standard.object(forKey: "lara.t1sz_boot") as? UInt64 ?? 0
            self.flog(String(format: "runExploit: ds_run_safe() returned %d, ds_is_ready=%@, resolved_t1sz=0x%02X",
                             ret, ds_is_ready() ? "YES" : "NO", resolvedT1sz))

            guard ret == 0, ds_is_ready() else {
                let err = "Exploit failed (code \(ret))"
                self.flog("ERROR: \(err)")
                filelog_flush()
                LogUploader.shared.uploadLog()
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            self.flog("Kernel R/W acquired — initialising VFS...")
            DispatchQueue.main.async { self.status = "Kernel R/W ready — initialising VFS..." }

            let vfsRet = vfs_init()
            let vfsReady = vfs_isready()
            self.flog("vfs_init() = \(vfsRet), vfs_isready() = \(vfsReady)")
            filelog_flush()

            guard vfsRet == 0 || vfsReady else {
                let err = "VFS init failed (\(vfsRet))"
                self.flog("ERROR: \(err)")
                LogUploader.shared.uploadLog()
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            self.flog("Escaping sandbox...")
            DispatchQueue.main.async { self.status = "Escaping sandbox..." }
            sbx_setlogcallback({ (msg: UnsafePointer<CChar>?) -> Void in
                guard let msg else { return }
                let s = String(cString: msg)
                filelog("[sbx] " + s)
                KernelLocationManager.shared.appendLog("[sbx] " + s)
            })
            let selfProc = ds_get_our_proc()
            let sbxRet = sbx_escape(selfProc)
            self.flog("sbx_escape() = \(sbxRet == 0 ? "ok — sandbox removed" : "failed (\(sbxRet))")")
            filelog_flush()

            self.flog("All systems ready — exploit complete")
            filelog_flush()

            LogUploader.shared.startAutoUpload()
            LogUploader.shared.uploadLog()

            DispatchQueue.main.async {
                self.isRunning = false; self.exploitReady = true
                self.progress = 1.0; self.status = "Kernel ready"
                UserDefaults.standard.synchronize()
                self.loadT1szDisplay()
                self.flog("t1sz after exploit: \(self.t1szBootDisplay)")
            }
            completion?(true)
        }

        workItem = item
        DispatchQueue.global(qos: .userInitiated).async(execute: item)
    }

    func cancelExploit() {
        flog("cancelExploit: force-stop requested")
        cancelRequested = true
        workItem?.cancel()
        DispatchQueue.main.async { self.isRunning = false; self.status = "Stopped by user"; self.progress = 0 }
    }

    // MARK: - Location spoofing

    func connect(lat: Double, lon: Double) {
        UserDefaults.standard.set(lat,  forKey: kLastLat)
        UserDefaults.standard.set(lon,  forKey: kLastLon)
        UserDefaults.standard.set(true, forKey: kWasConnected)

        spoofLat = lat
        spoofLon = lon

        if exploitReady {
            flog("connect: kernel ready — activating spoof immediately")
            spoofQueue.async { self.activateSpoof(lat: lat, lon: lon) }
        } else {
            flog("connect: kernel not ready, running exploit first")
            runExploit { [weak self] success in
                guard let self, success else { return }
                self.applySpoof(lat: lat, lon: lon)
            }
        }
    }

    func applySpoof(lat: Double, lon: Double) {
        UserDefaults.standard.set(lat,  forKey: kLastLat)
        UserDefaults.standard.set(lon,  forKey: kLastLon)
        UserDefaults.standard.set(true, forKey: kWasConnected)
        flog(String(format: "applySpoof: %.5f, %.5f", lat, lon))
        spoofLat = lat
        spoofLon = lon
        spoofQueue.async { self.activateSpoof(lat: lat, lon: lon) }
    }

    func updateLocation(lat: Double, lon: Double) {
        guard isConnected else { return }
        UserDefaults.standard.set(lat, forKey: kLastLat)
        UserDefaults.standard.set(lon, forKey: kLastLon)
        let changed = abs(lat - spoofLat) > 0.00001 || abs(lon - spoofLon) > 0.00001
        spoofLat = lat
        spoofLon = lon
        if changed {
            spoofQueue.async { self.activateSpoof(lat: lat, lon: lon) }
        }
    }

    func disconnect() {
        flog("disconnect: clearing spoof")
        stopSpoofTimer()

        let simClearRet = simlocation_clear()
        flog("disconnect: simlocation_clear() = \(simClearRet)")

        LogUploader.shared.stopAutoUpload()
        didActivateSpoof = false

        writeSpoofPlist(lat: 0, lon: 0, enabled: false)
        restartLocationd(reason: "disconnect — restoring real GPS")

        isConnected = false
        status = "Disconnected"
        UserDefaults.standard.set(false, forKey: kWasConnected)
        filelog_flush()
        LogUploader.shared.uploadLog()
    }

    // MARK: - Continuous spoof timer

    private let kSpoofInterval: Double = 3.0

    private func startSpoofTimer() {
        stopSpoofTimer()
        let timer = DispatchSource.makeTimerSource(queue: spoofQueue)
        timer.schedule(deadline: .now() + kSpoofInterval,
                       repeating: kSpoofInterval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.timerTickCount += 1
            let tick = self.timerTickCount

            if simlocation_is_active() != 0 {
                let simRet = simlocation_set(self.spoofLat, self.spoofLon)
                filelog(String(format: "[tick %d] simlocation_set=%.6f,%.6f ret=%d (%@)",
                               tick, self.spoofLat, self.spoofLon, simRet,
                               simRet == 0 ? "OK" : "session dead"))
                if simRet == 0 { return }
            }

            filelog(String(format: "[tick %d] writing plist lat=%.6f lon=%.6f",
                           tick, self.spoofLat, self.spoofLon))
            let writeOk = self.writeSpoofPlist(lat: self.spoofLat, lon: self.spoofLon, enabled: true)
            guard writeOk else { return }
            self.writeSpoofViaCFPrefs(lat: self.spoofLat, lon: self.spoofLon, enabled: true)

            let rcRet = rc_locationd_reload_plist()
            if rcRet == 0 { return }

            let notifyRet = notify_locationd_direct()
            if notifyRet == 0 { return }

            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastTimerRestart)
            guard elapsed > self.kTimerRestartInterval else { return }
            self.lastTimerRestart = now

            let flushRet = flush_cfprefsd_and_signal_locationd()
            if flushRet == 0 { return }

            let preProc = procbyname("locationd")
            let prePid  = preProc != 0 ? pid_t(bitPattern: UInt32(ds_kread32(preProc + UInt64(off_proc_p_pid)))) : 0
            filelog(String(format: "[tick %d] restarting locationd (PID %d)", tick, prePid))
            self.restartLocationd(reason: "tick \(tick)")
            Thread.sleep(forTimeInterval: 3.0)
        }
        timer.resume()
        spoofTimer = timer
        flog("spoofTimer: started (interval \(Int(kSpoofInterval))s)")
    }

    private func stopSpoofTimer() {
        spoofTimer?.cancel()
        spoofTimer = nil
    }

    // MARK: - Core spoof activation

    private func activateSpoof(lat: Double, lon: Double) {
        flog(String(format: "activateSpoof: %.5f, %.5f", lat, lon))

        // If simlocation service is already up (e.g. DDI mounted via Xcode),
        // send the binary payload straight through lockdownd. We don't try to
        // download/mount the DDI ourselves — iOS 17+ requires device-specific
        // TSS signing.
        let simAlreadyUp = (simlocation_is_active() != 0) || (procbyname("DTServiceHub") != 0)
        if simAlreadyUp {
            let simRet = simlocation_set(lat, lon)
            flog(String(format: "activateSpoof: simlocation_set()=%d (DTServiceHub present)", simRet))
            if simRet == 0 {
                if !didActivateSpoof { Thread.sleep(forTimeInterval: 0.3) }
                didActivateSpoof = true
                startSpoofTimer()
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.status = String(format: "Spoofing %.5f, %.5f (sim-svc)", lat, lon)
                }
                filelog_flush()
                LogUploader.shared.uploadLog()
                return
            }
        }

        flog("activateSpoof: using Darksword VFS+heap-patch+RC path")

        // Step 2 (README): write plist (VFS if available, else direct disk write)
        let writeOk = writeSpoofPlist(lat: lat, lon: lon, enabled: true)
        if !writeOk {
            flog("activateSpoof: plist write failed")
            LogUploader.shared.uploadLog()
            return
        }
        writeSpoofViaCFPrefs(lat: lat, lon: lon, enabled: true)

        // Step 3 (README): in-memory heap patch of locationd's coordinate pairs
        flog("activateSpoof: patching locationd memory")
        let patched = locationd_patch_coordinates(lat, lon)
        flog("activateSpoof: patched \(patched) pair(s)")

        // Step 4 (README): RemoteCall inside locationd to post prefsChanged
        flog("activateSpoof: RemoteCall post notification inside locationd")
        let rcRet = rc_locationd_reload_plist()
        if rcRet == 0 {
            flog("activateSpoof: RC reload OK")
            if !didActivateSpoof { Thread.sleep(forTimeInterval: 0.5) }
        } else {
            flog("activateSpoof: RC failed (\(rcRet)) — flushing cfprefsd")
            let flushRet = flush_cfprefsd_and_signal_locationd()
            if flushRet != 0 {
                flog("activateSpoof: cfprefsd flush failed — restarting locationd")
                restartLocationd(reason: "activateSpoof")
                Thread.sleep(forTimeInterval: 3.0)
            }
        }

        didActivateSpoof = true
        startSpoofTimer()
        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
        filelog_flush()
        LogUploader.shared.uploadLog()
    }

    @discardableResult
    private func writeSpoofViaCFPrefs(lat: Double, lon: Double, enabled: Bool) -> Bool {
        let domain = "com.apple.locationd" as CFString
        let user   = kCFPreferencesCurrentUser
        let host   = kCFPreferencesCurrentHost
        CFPreferencesSetValue("SimulationEnabled" as CFString,
                              NSNumber(value: enabled), domain, user, host)
        CFPreferencesSetValue("LocationSimulatorEnabled" as CFString,
                              NSNumber(value: enabled), domain, user, host)
        CFPreferencesSetValue("SimulatedLatitude" as CFString,
                              enabled ? NSNumber(value: lat) : nil, domain, user, host)
        CFPreferencesSetValue("SimulatedLongitude" as CFString,
                              enabled ? NSNumber(value: lon) : nil, domain, user, host)
        let synced = CFPreferencesSynchronize(domain, user, host)
        flog(String(format: "writeSpoofViaCFPrefs: sync=%@ enabled=%@ lat=%.6f lon=%.6f",
                    synced ? "OK" : "FAILED", enabled ? "YES" : "NO", lat, lon))
        return synced
    }

    @discardableResult
    private func writeSpoofPlist(lat: Double, lon: Double, enabled: Bool) -> Bool {
        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"

        let dict: NSDictionary = [
            "SimulatedLatitude":        lat,
            "SimulatedLongitude":       lon,
            "SimulationEnabled":        enabled,
            "LocationSimulatorEnabled": enabled
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0) else {
            flog("writeSpoofPlist: serialization failed")
            return false
        }

        if exploitReady && vfs_isready() {
            let tmp = NSTemporaryDirectory() + "lspoof_\(arc4random()).plist"
            do {
                try data.write(to: URL(fileURLWithPath: tmp))
                let r = vfs_overwritefile(plistPath, tmp)
                let ok = (r == 0)
                flog(String(format: "writeSpoofPlist(VFS): r=%d (%@)", r, ok ? "OK" : "FAIL"))
                try? FileManager.default.removeItem(atPath: tmp)
                if ok { return true }
            } catch {
                flog("writeSpoofPlist(VFS): \(error.localizedDescription)")
            }
        }

        do {
            let dir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir,
               withIntermediateDirectories: true, attributes: nil)
            try data.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])
            return true
        } catch {
            flog("writeSpoofPlist: FAILED — \(error.localizedDescription)")
            return false
        }
    }

    private func restartLocationd(reason: String) {
        flog("restartLocationd: \(reason)")
        if crashproc("locationd") == 0 { return }
        if let proc = procbyname("locationd") as? UInt64, proc != 0 {
            let pid = pid_t(bitPattern: UInt32(ds_kread32(proc + UInt64(off_proc_p_pid))))
            if pid > 1 { kill(pid, SIGKILL); return }
        }
        restart_locationd_via_launchctl()
    }
}

// MARK: - CLLocationManagerDelegate

extension KernelLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }
    func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}
    func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
}
