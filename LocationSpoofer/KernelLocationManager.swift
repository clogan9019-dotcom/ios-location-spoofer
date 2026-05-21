import Foundation
import Combine
import CoreLocation

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

    // Continuous spoof state
    private var spoofLat: Double = 0
    private var spoofLon: Double = 0
    private var spoofTimer: DispatchSourceTimer?
    private let spoofQueue = DispatchQueue(label: "com.locationspoofer.spoof", qos: .userInitiated)

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
                self.flog("CRASH: Check log file at \(filelog_path() != nil ? String(cString: filelog_path()) : "unknown")")
                filelog_flush()
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

            self.flog("runExploit: ds_run_safe() returned \(ret), ds_is_ready=\(ds_is_ready())")

            guard ret == 0, ds_is_ready() else {
                let err = "Exploit failed (code \(ret))"
                self.flog("ERROR: \(err)")
                filelog_flush()
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
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            // Escape the app sandbox so we can write to locationd's preference path.
            // sbx_escape() patches kernel sandbox extension structures for our process,
            // granting read-write access to the full filesystem.
            self.flog("Escaping sandbox...")
            DispatchQueue.main.async { self.status = "Escaping sandbox..." }
            sbx_setlogcallback { msg in
                guard let msg else { return }
                let s = String(cString: msg)
                filelog("[sbx] " + s)
                KernelLocationManager.shared.appendLog("[sbx] " + s)
            }
            let selfProc = ds_get_our_proc()
            let sbxRet = sbx_escape(selfProc)
            self.flog("sbx_escape() = \(sbxRet == 0 ? "ok — sandbox removed" : "failed (\(sbxRet))")")
            filelog_flush()

            self.flog("All systems ready — exploit complete")
            filelog_flush()
            DispatchQueue.main.async {
                self.isRunning = false; self.exploitReady = true
                self.progress = 1.0; self.status = "Kernel ready"
                self.loadT1szDisplay()
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
        if exploitReady {
            spoofLat = lat
            spoofLon = lon
            spoofQueue.async { self.writeLocation(lat: lat, lon: lon) }
            startSpoofTimer()
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
        spoofQueue.async { self.writeLocation(lat: lat, lon: lon) }
        startSpoofTimer()
    }

    func updateLocation(lat: Double, lon: Double) {
        guard isConnected else { return }
        UserDefaults.standard.set(lat, forKey: kLastLat)
        UserDefaults.standard.set(lon, forKey: kLastLon)
        spoofLat = lat
        spoofLon = lon
        spoofQueue.async { self.writeLocation(lat: lat, lon: lon) }
    }

    func disconnect() {
        flog("disconnect: clearing spoof")
        stopSpoofTimer()
        isConnected = false
        status = "Disconnected"
        UserDefaults.standard.set(false, forKey: kWasConnected)
    }

    // MARK: - Continuous spoof timer

    // locationd gets real GPS updates from the hardware continuously.
    // We fight back by re-writing the plist and notifying locationd every
    // kSpoofInterval seconds so the fake coordinates always win.
    private let kSpoofInterval: Double = 3.0

    private func startSpoofTimer() {
        stopSpoofTimer()
        let timer = DispatchSource.makeTimerSource(queue: spoofQueue)
        timer.schedule(deadline: .now() + kSpoofInterval,
                       repeating: kSpoofInterval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.writeLocation(lat: self.spoofLat, lon: self.spoofLon, silent: true)
        }
        timer.resume()
        spoofTimer = timer
        flog("spoofTimer: started (interval \(Int(kSpoofInterval))s)")
    }

    private func stopSpoofTimer() {
        spoofTimer?.cancel()
        spoofTimer = nil
    }

    // MARK: - Private write

    private func writeLocation(lat: Double, lon: Double, silent: Bool = false) {
        if !silent {
            flog(String(format: "writeLocation: %.5f, %.5f", lat, lon))
        }

        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"
        let plistData = locationPlistData(lat: lat, lon: lon)

        var writeOk = false

        // Primary: direct write — works after sbx_escape() removes sandbox.
        do {
            let dir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir,
                withIntermediateDirectories: true, attributes: nil)
            try plistData.write(to: URL(fileURLWithPath: plistPath),
                                options: [.atomic])
            writeOk = true
            if !silent { flog("writeLocation: plist written ok (direct)") }
        } catch {
            if !silent { flog("writeLocation: direct write failed — \(error.localizedDescription)") }
        }

        // Fallback: write to a temp file in our sandbox, then use kernel VFS
        // to overwrite the system plist.  vfs_overwritefile requires the
        // destination to already exist, so we only use this if direct write
        // succeeded at least once (meaning the file now exists).
        if !writeOk && vfs_isready() {
            let tmpPath = NSTemporaryDirectory() + "com.apple.locationd.plist.tmp"
            do {
                try plistData.write(to: URL(fileURLWithPath: tmpPath), options: [.atomic])
                let vfsRet = vfs_overwritefile(plistPath, tmpPath)
                writeOk = (vfsRet == 0)
                if !silent {
                    flog("writeLocation: vfs_overwritefile -> \(vfsRet == 0 ? "ok" : "failed (\(vfsRet))")")
                }
                try? FileManager.default.removeItem(atPath: tmpPath)
            } catch {
                if !silent { flog("writeLocation: vfs fallback failed — \(error.localizedDescription)") }
            }
        }

        // Notify locationd to reload its preferences.
        let rcRet = rc_locationd_reload_plist()
        if rcRet != 0 { notify_locationd_direct() }
        if !silent {
            flog("writeLocation: locationd notify -> \(rcRet == 0 ? "ok (rc)" : "fallback (code \(rcRet))")")
        }

        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
        filelog_flush()
    }

    private func locationPlistData(lat: Double, lon: Double) -> Data {
        let dict: NSDictionary = [
            "SimulatedLatitude":  lat,
            "SimulatedLongitude": lon,
            "SimulationEnabled":  true
        ]
        var err: NSError?
        let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                        format: .xml,
                                                        options: 0)
        if let data { return data }
        _ = err
        // Fallback: hand-rolled XML plist
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>SimulatedLatitude</key><real>\(lat)</real>
            <key>SimulatedLongitude</key><real>\(lon)</real>
            <key>SimulationEnabled</key><true/>
        </dict>
        </plist>
        """
        return xml.data(using: .utf8)!
    }
}

// MARK: - CLLocationManagerDelegate (background keep-alive)

extension KernelLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        // intentionally empty — keeps the app alive in the background
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        // ignore — GPS unavailability does not affect kernel-level spoofing
    }
}
