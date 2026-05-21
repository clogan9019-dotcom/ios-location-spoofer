import Foundation
import Combine
import CoreLocation
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

    // Continuous spoof state
    private var spoofLat: Double = 0
    private var spoofLon: Double = 0
    private var spoofTimer: DispatchSourceTimer?
    private let spoofQueue = DispatchQueue(label: "com.locationspoofer.spoof", qos: .userInitiated)
    private var didActivateSpoof = false   // tracks whether locationd was restarted into sim mode

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

            // Escape the app sandbox so we can write to protected paths.
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
            // Full activation: write plist then restart locationd
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
            // Location changed — update plist and restart locationd to apply
            spoofQueue.async { self.activateSpoof(lat: lat, lon: lon) }
        }
    }

    func disconnect() {
        flog("disconnect: clearing spoof")
        stopSpoofTimer()
        didActivateSpoof = false

        // Write a disabled simulation plist so locationd won't simulate on next start
        writeSpoofPlist(lat: 0, lon: 0, enabled: false)

        // Restart locationd so it picks up the disabled plist and reverts to real GPS
        restartLocationd(reason: "disconnect — restoring real GPS")

        isConnected = false
        status = "Disconnected"
        UserDefaults.standard.set(false, forKey: kWasConnected)
        filelog_flush()
    }

    // MARK: - Continuous spoof timer

    // Timer re-writes the simulation plist every 3s and fires an RC reload to
    // keep locationd continuously pointed at our fake coords.
    private let kSpoofInterval: Double = 3.0

    private func startSpoofTimer() {
        stopSpoofTimer()
        let timer = DispatchSource.makeTimerSource(queue: spoofQueue)
        timer.schedule(deadline: .now() + kSpoofInterval,
                       repeating: kSpoofInterval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.writeSpoofPlist(lat: self.spoofLat, lon: self.spoofLon, enabled: true)
            // Try RC reload (task-port injection into locationd) first.
            let rcRet = rc_locationd_reload_plist()
            if rcRet != 0 {
                filelog("(spoofTimer) RC reload returned \(rcRet) — trying direct notify fallback")
                // Direct cross-process notify: locationd may still honour some of these.
                let directRet = notify_locationd_direct()
                if directRet != 0 {
                    filelog("(spoofTimer) direct notify also returned \(directRet)")
                }
            }
        }
        timer.resume()
        spoofTimer = timer
        flog("spoofTimer: started (interval \(Int(kSpoofInterval))s)")
    }

    private func stopSpoofTimer() {
        spoofTimer?.cancel()
        spoofTimer = nil
    }

    // MARK: - Core write + RC-reload / restart logic

    /// Full activation: write simulation plist, then try RC to reload it
    /// instantly inside locationd.  If RC fails (e.g. first run), fall back
    /// to restarting locationd so launchd respawns it with the new plist.
    private func activateSpoof(lat: Double, lon: Double) {
        flog(String(format: "activateSpoof: %.5f, %.5f", lat, lon))

        let writeOk = writeSpoofPlist(lat: lat, lon: lon, enabled: true)
        if !writeOk {
            flog("activateSpoof: plist write failed — cannot proceed")
            return
        }

        // ── Try RC path first (instant, no restart) ──────────────────────
        flog("activateSpoof: trying RC pref-reload inside locationd...")
        let rcRet = rc_locationd_reload_plist()
        if rcRet == 0 {
            flog("activateSpoof: RC reload succeeded — no locationd restart needed")
            if !didActivateSpoof {
                // First activation — give locationd 0.5 s to process the reload
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else {
            // ── RC failed — fall back to restarting locationd ─────────────
            flog("activateSpoof: RC failed (\(rcRet)) — falling back to locationd restart")
            restartLocationd(reason: "activating spoof at \(String(format: "%.5f", lat)), \(String(format: "%.5f", lon))")
            flog("activateSpoof: waiting for locationd to restart...")
            Thread.sleep(forTimeInterval: 3.0)
            flog("activateSpoof: locationd should be back — spoof active")
        }

        didActivateSpoof = true
        startSpoofTimer()

        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
        filelog_flush()
    }

    /// Write the locationd simulation plist.
    /// locationd reads this at startup; with SimulationEnabled=true it uses
    /// SimulatedLatitude/SimulatedLongitude instead of real GPS.
    @discardableResult
    private func writeSpoofPlist(lat: Double, lon: Double, enabled: Bool) -> Bool {
        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"

        let dict: NSDictionary = [
            "SimulatedLatitude":  lat,
            "SimulatedLongitude": lon,
            "SimulationEnabled":  enabled
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0) else {
            flog("writeSpoofPlist: serialization failed")
            return false
        }

        do {
            let dir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil)
            try data.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])
            flog(String(format: "writeSpoofPlist: ok (enabled=\(enabled), %.5f, %.5f)", lat, lon))
            return true
        } catch {
            flog("writeSpoofPlist: failed — \(error.localizedDescription)")
            return false
        }
    }

    /// Restart locationd so launchd respawns it with the updated simulation plist.
    /// Strategy:
    ///   1. Try kernel-read PID + userspace kill() — fast, works if we have permission.
    ///   2. If kill() fails (EPERM running as mobile), use launchctl kickstart -k
    ///      which talks to launchd via XPC and can forcibly restart any system service.
    private func restartLocationd(reason: String) {
        flog("restartLocationd: \(reason)")

        // Look up locationd's kernel proc structure
        let locationdProc = procbyname("locationd")
        guard locationdProc != 0 else {
            flog("restartLocationd: procbyname('locationd') returned 0 — trying launchctl")
            launchctlKickstartLocationd()
            return
        }

        // Read the PID from the proc struct (off_proc_p_pid is the uint32 offset)
        let pid = pid_t(bitPattern: UInt32(ds_kread32(locationdProc + UInt64(off_proc_p_pid))))
        flog("restartLocationd: locationd pid = \(pid)")

        guard pid > 1 else {
            flog("restartLocationd: invalid pid \(pid) — trying launchctl")
            launchctlKickstartLocationd()
            return
        }

        // SIGKILL — launchd will restart locationd automatically
        let ret = kill(pid, SIGKILL)
        if ret == 0 {
            flog("restartLocationd: kill(\(pid), SIGKILL) = ok — launchd will restart locationd")
        } else {
            let err = errno
            flog("restartLocationd: kill(\(pid), SIGKILL) = \(ret) (errno \(err)) — falling back to launchctl")
            launchctlKickstartLocationd()
        }
    }

    /// Use `launchctl kickstart -k system/com.apple.locationd` to force-restart
    /// locationd via launchd's XPC interface, bypassing EPERM from userspace kill().
    private func launchctlKickstartLocationd() {
        flog("restartLocationd: using launchctl kickstart -k system/com.apple.locationd")
        let ret = restart_locationd_via_launchctl()
        if ret == 0 {
            flog("restartLocationd: launchctl kickstart succeeded")
        } else {
            flog("restartLocationd: launchctl kickstart returned \(ret)")
        }
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
