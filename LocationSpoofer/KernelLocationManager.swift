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

        // Close any active simulatelocation service session first.
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

            // ── Fast path: simulatelocation session ──────────────────────
            // If we already have an active session with the service, just
            // resend the coordinates. This is the StikDebug approach — no
            // plist writes, no cfprefsd involved at all.
            if simlocation_is_active() != 0 {
                let simRet = simlocation_set(self.spoofLat, self.spoofLon)
                filelog(String(format: "[tick %d] simlocation_set=%.6f,%.6f ret=%d (%@)",
                               tick, self.spoofLat, self.spoofLon, simRet,
                               simRet == 0 ? "OK" : "session dead"))
                if simRet == 0 { return }
                filelog(String(format: "[tick %d] simlocation session died — falling back to plist", tick))
            }

            // ── Plist write ──────────────────────────────────────────────
            filelog(String(format: "[tick %d] spoofTimer: writing plist lat=%.6f lon=%.6f",
                           tick, self.spoofLat, self.spoofLon))
            let writeOk = self.writeSpoofPlist(lat: self.spoofLat, lon: self.spoofLon, enabled: true)
            filelog(String(format: "[tick %d] writeSpoofPlist = %@", tick, writeOk ? "OK" : "FAILED"))
            guard writeOk else { return }

            self.writeSpoofViaCFPrefs(lat: self.spoofLat, lon: self.spoofLon, enabled: true)

            // ── RC reload ────────────────────────────────────────────────
            let rcRet = rc_locationd_reload_plist()
            filelog(String(format: "[tick %d] rc_locationd_reload_plist = %d (%@)",
                           tick, rcRet, rcRet == 0 ? "SUCCESS" : "FAIL"))
            if rcRet == 0 { return }

            // ── notify_locationd_direct (cross-process Darwin notify) ───
            let notifyRet = notify_locationd_direct()
            filelog(String(format: "[tick %d] notify_locationd_direct = %d (%@)",
                           tick, notifyRet, notifyRet == 0 ? "ok" : "failed"))
            if notifyRet == 0 { return }

            // ── cfprefsd flush (DS-native, kills cache) ──────────────────
            // Last resort before locationd restart: kill cfprefsd so it
            // restarts with a clean cache, then notify locationd.
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastTimerRestart)
            guard elapsed > self.kTimerRestartInterval else {
                filelog(String(format: "[tick %d] all fallbacks failed — cooldown (%.0fs left)",
                               tick, self.kTimerRestartInterval - elapsed))
                return
            }
            self.lastTimerRestart = now

            filelog(String(format: "[tick %d] RC+notify failed — trying cfprefsd flush", tick))
            let flushRet = flush_cfprefsd_and_signal_locationd()
            filelog(String(format: "[tick %d] flush_cfprefsd_and_signal_locationd = %d (%@)",
                           tick, flushRet, flushRet == 0 ? "OK" : "FAIL"))
            if flushRet == 0 { return }

            // ── locationd restart (last resort) ──────────────────────────
            let preProc = procbyname("locationd")
            let prePid  = preProc != 0 ? pid_t(bitPattern: UInt32(ds_kread32(preProc + UInt64(off_proc_p_pid)))) : 0
            filelog(String(format: "[tick %d] restarting locationd (PID %d) — all methods failed", tick, prePid))
            self.restartLocationd(reason: "spoof timer tick \(tick): RC=\(rcRet) notify=\(notifyRet) flush=\(flushRet)")
            Thread.sleep(forTimeInterval: 3.0)
            let postProc = procbyname("locationd")
            let postPid  = postProc != 0 ? pid_t(bitPattern: UInt32(ds_kread32(postProc + UInt64(off_proc_p_pid)))) : 0
            filelog(String(format: "[tick %d] locationd after restart: PID %d (%@)",
                           tick, postPid, postPid != prePid ? "new ✓" : "SAME — restart may have failed"))
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

        // ── PRIMARY: StikDebug-style com.apple.dt.simulatelocation ────────
        // We connect directly to lockdownd (no usbmuxd needed — we're already
        // on device after sbx_escape), issue StartService("com.apple.dt.
        // simulatelocation"), open the TCP port it returns, and send the
        // identical 20-byte binary payload Xcode/StikDebug send. This goes
        // straight through DTServiceHub into locationd — cfprefsd is not
        // involved at all, so the spoof applies instantly and survives
        // settings resets. Claude says this is the Lara path.
        var simRet = simlocation_set(lat, lon)
        flog(String(format: "activateSpoof: simlocation_set() = %d", simRet))

        // If the service isn't available yet, try one-shot auto-mounting the
        // DDI (the DeveloperDiskImage provides com.apple.dt.simulatelocation).
        // This mirrors exactly what StikDebug does from the Mac, just without
        // the USB/tunnel hop.
        if simRet != 0 {
            flog("activateSpoof: sim-svc unavailable — attempting on-demand DDI mount then retrying")
            let mounted = attemptDDIMountSync()
            if mounted {
                flog("activateSpoof: DDI mounted, retrying simlocation_set()")
                Thread.sleep(forTimeInterval: 1.0) // let DTServiceHub come up
                simRet = simlocation_set(lat, lon)
                flog(String(format: "activateSpoof: retry simlocation_set() = %d", simRet))
            }
        }

        if simRet == 0 {
            flog("activateSpoof: simlocation OK — StikDebug path active (lockdownd → sim-svc → locationd)")
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

        flog("activateSpoof: sim-svc unavailable — using Darksword plist+heap-patch+RC flow (README steps 2-4)")

        // ── Step 2: VFS plist write ─────────────────────────────────────
        let writeOk = writeSpoofPlist(lat: lat, lon: lon, enabled: true)
        if !writeOk {
            flog("activateSpoof: plist write failed — cannot proceed")
            LogUploader.shared.uploadLog()
            return
        }
        writeSpoofViaCFPrefs(lat: lat, lon: lon, enabled: true)

        // ── Step 3: In-memory heap patch of locationd's coordinate pairs
        flog("activateSpoof: scanning locationd RW regions for (lat,lon) double pairs to overwrite (Darksword krw)")
        let patched = locationd_patch_coordinates(lat, lon)
        flog("activateSpoof: locationd_patch_coordinates patched \(patched) pair(s) in memory")

        // ── Step 4: RemoteCall reload from inside locationd ────────────
        flog("activateSpoof: RemoteCall post pref-reload notification inside locationd")
        let rcRet = rc_locationd_reload_plist()
        flog(String(format: "activateSpoof: rc_locationd_reload_plist() = %d (%@)",
                    rcRet, rcRet == 0 ? "SUCCESS" : "FAIL"))

        if rcRet == 0 {
            flog("activateSpoof: RC reload succeeded")
            if !didActivateSpoof { Thread.sleep(forTimeInterval: 0.5) }
        } else {
            // RC failed — kill cfprefsd to purge its stale cache
            flog("activateSpoof: RC failed (\(rcRet)) — trying cfprefsd cache flush")
            let flushRet = flush_cfprefsd_and_signal_locationd()
            flog(String(format: "activateSpoof: flush_cfprefsd_and_signal_locationd() = %d (%@)",
                        flushRet, flushRet == 0 ? "OK — cfprefsd restarted, locationd signalled" : "FAIL"))

            if flushRet != 0 {
                // All DS-based methods failed — restart locationd as last resort
                flog("activateSpoof: cfprefsd flush failed — restarting locationd")
                let preProc = procbyname("locationd")
                let prePid  = preProc != 0 ? pid_t(bitPattern: UInt32(ds_kread32(preProc + UInt64(off_proc_p_pid)))) : 0
                flog("activateSpoof: locationd PID before restart = \(prePid)")
                restartLocationd(reason: "activating spoof: RC=\(rcRet) flush=\(flushRet)")
                flog("activateSpoof: waiting 3s for locationd to restart...")
                Thread.sleep(forTimeInterval: 3.0)
                let postProc = procbyname("locationd")
                let postPid  = postProc != 0 ? pid_t(bitPattern: UInt32(ds_kread32(postProc + UInt64(off_proc_p_pid)))) : 0
                flog("activateSpoof: locationd after restart: PID \(postPid) (\(postPid != prePid ? "NEW ✓" : "SAME — restart may have failed"))")
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
        flog(String(format: "writeSpoofViaCFPrefs: sync=%@, enabled=%@, lat=%.6f, lon=%.6f",
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
            var vfsOk = false
            do {
                try data.write(to: URL(fileURLWithPath: tmp))
                let r = vfs_overwritefile(plistPath, tmp)
                vfsOk = (r == 0)
                flog(String(format: "writeSpoofPlist(VFS): r=%d (%@) lat=%.6f lon=%.6f",
                            r, vfsOk ? "OK" : "FAIL", lat, lon))
            } catch {
                flog("writeSpoofPlist(VFS): temp write failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(atPath: tmp)
            if vfsOk { return true }
            flog("writeSpoofPlist(VFS): failed — falling back to direct write")
        }

        do {
            let dir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil)
            try data.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])
            let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: plistPath)[.size] as? Int) ?? -1
            flog(String(format: "writeSpoofPlist(direct): wrote %d bytes enabled=%@ lat=%.6f lon=%.6f",
                        onDiskSize, enabled ? "YES" : "NO", lat, lon))
            return true
        } catch {
            flog("writeSpoofPlist: FAILED — \(error.localizedDescription)")
            return false
        }
    }

    private func restartLocationd(reason: String) {
        flog("restartLocationd: \(reason)")

        flog("restartLocationd: calling crashproc(locationd) via kernel r/w")
        let kret = crashproc("locationd")
        if kret == 0 {
            flog("restartLocationd: crashproc() succeeded — launchd will respawn locationd")
            return
        }
        flog("restartLocationd: crashproc() returned \(kret) — trying userspace kill")

        let locationdProc = procbyname("locationd")
        if locationdProc != 0 {
            let pid = pid_t(bitPattern: UInt32(ds_kread32(locationdProc + UInt64(off_proc_p_pid))))
            flog("restartLocationd: userspace kill(\(pid), SIGKILL)")
            let ret = kill(pid, SIGKILL)
            if ret == 0 { flog("restartLocationd: kill() succeeded"); return }
            flog("restartLocationd: kill() = \(ret) errno=\(errno)")
        } else {
            flog("restartLocationd: procbyname returned 0")
        }

        flog("restartLocationd: trying launchctl kickstart -k system/com.apple.locationd")
        let lcret = restart_locationd_via_launchctl()
        flog("restartLocationd: launchctl returned \(lcret)")
    }

    // MARK: - On-demand DDI mount (for the StikDebug simlocation path)
    //
    // If simlocation_set fails because com.apple.dt.simulatelocation isn't
    // registered yet, we attempt a full DDI download+mount inline (same flow
    // the Settings tab exposes) and return true if ddi_check_status() reports
    // mounted afterward. This lets the Spoof toggle auto-install the DDI the
    // first time it's needed, just like Xcode does on a Mac.

    private func attemptDDIMountSync() -> Bool {
        // Already mounted?
        if ddi_check_status() == DDI_STATUS_MOUNTED || procbyname("DTServiceHub") != 0 {
            flog("attemptDDIMountSync: DDI already mounted — DTServiceHub present")
            return true
        }

        let ddi = DDIMountManager.shared

        // Detect iOS version.
        let sysVer = UIDevice.current.systemVersion
        flog("attemptDDIMountSync: iOS \(sysVer)")

        let baseURL = "https://github.com/doronz88/DeveloperDiskImage/releases/download"
        let ddiDir = NSTemporaryDirectory() + "ddi/"
        let dmgPath = ddiDir + "DeveloperDiskImage.dmg"
        let sigPath = ddiDir + "DeveloperDiskImage.dmg.signature"

        do {
            try FileManager.default.createDirectory(atPath: ddiDir,
                                                    withIntermediateDirectories: true)
        } catch {
            flog("attemptDDIMountSync: could not create \(ddiDir): \(error.localizedDescription)")
            return false
        }

        // Version candidates from most- to least-specific.
        let parts = sysVer.split(separator: ".")
        var candidates = [sysVer]
        if parts.count >= 3 { candidates.append("\(parts[0]).\(parts[1])") }
        if parts.count >= 2 { candidates.append("\(parts[0])") }

        var downloaded = false
        for tag in candidates {
            let dmgURL = "\(baseURL)/iOS-\(tag)/DeveloperDiskImage.dmg"
            let sigURL = "\(baseURL)/iOS-\(tag)/DeveloperDiskImage.dmg.signature"
            flog("attemptDDIMountSync: trying tag iOS-\(tag)")

            func syncDownload(_ urlStr: String, to path: String) -> Bool {
                guard let url = URL(string: urlStr) else { return false }
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                let task = URLSession.shared.downloadTask(with: url) { loc, resp, err in
                    defer { sem.signal() }
                    guard let loc = loc,
                          let http = resp as? HTTPURLResponse,
                          http.statusCode == 200,
                          err == nil else { return }
                    do {
                        if FileManager.default.fileExists(atPath: path) {
                            try? FileManager.default.removeItem(atPath: path)
                        }
                        try FileManager.default.moveItem(at: loc, to: URL(fileURLWithPath: path))
                        ok = true
                    } catch {
                        self.flog("attemptDDIMountSync: move failed: \(error.localizedDescription)")
                    }
                }
                task.resume()
                sem.wait()
                return ok
            }

            if syncDownload(dmgURL, to: dmgPath) && syncDownload(sigURL, to: sigPath) {
                let sz = (try? FileManager.default.attributesOfItem(atPath: dmgPath)[.size] as? Int) ?? 0
                flog("attemptDDIMountSync: dmg downloaded (\(sz) bytes)")
                if sz > 65536 { downloaded = true; break }
            }
            flog("attemptDDIMountSync: tag iOS-\(tag) not available — trying next")
        }

        guard downloaded else {
            flog("attemptDDIMountSync: could not download DDI for iOS \(sysVer)")
            return false
        }

        // Mount via imagemounterd XPC.
        flog("attemptDDIMountSync: calling ddi_mount()...")
        let ret = ddi_mount(dmgPath, sigPath)
        flog("attemptDDIMountSync: ddi_mount() = \(ret)")
        if ret != 0 {
            let errStr = String(cString: ddi_last_error())
            flog("attemptDDIMountSync: mount error: \(errStr)")
        }

        // Wait up to 6 s for DTServiceHub.
        for i in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            if ddi_check_status() == DDI_STATUS_MOUNTED || procbyname("DTServiceHub") != 0 {
                flog("attemptDDIMountSync: DDI active after \(i+1) polls")
                // Refresh UI status on the main actor.
                DispatchQueue.main.async { ddi.checkStatus() }
                return true
            }
        }
        DispatchQueue.main.async { ddi.checkStatus() }
        flog("attemptDDIMountSync: DTServiceHub never appeared — mount may have failed")
        return false
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
                         didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {}
}
