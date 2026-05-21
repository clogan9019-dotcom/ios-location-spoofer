import Foundation
import Combine

final class KernelLocationManager: ObservableObject {
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

    private init() {
        filelog_init()
        logFilePath = String(cString: filelog_path())
        loadT1szDisplay()
        logDeviceInfo()
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

    // MARK: - Foreground restore

    func restoreIfNeeded() {
        flog("restoreIfNeeded: checking...")
        guard UserDefaults.standard.bool(forKey: kWasConnected) else {
            flog("restoreIfNeeded: was not connected, skipping")
            return
        }
        let lat = UserDefaults.standard.double(forKey: kLastLat)
        let lon = UserDefaults.standard.double(forKey: kLastLon)
        guard lat != 0 || lon != 0 else {
            flog("restoreIfNeeded: no saved coords, skipping")
            return
        }
        flog(String(format: "restoreIfNeeded: restoring %.5f, %.5f", lat, lon))
        if ds_is_ready() {
            flog("restoreIfNeeded: kernel still ready, re-writing location")
            DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
        } else {
            flog("restoreIfNeeded: kernel not ready, re-running exploit")
            runExploit { [weak self] success in
                guard let self, success else { return }
                self.applySpoof(lat: lat, lon: lon)
            }
        }
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
            DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
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
        DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
    }

    func updateLocation(lat: Double, lon: Double) {
        guard isConnected else { return }
        UserDefaults.standard.set(lat, forKey: kLastLat)
        UserDefaults.standard.set(lon, forKey: kLastLon)
        DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
    }

    func disconnect() {
        flog("disconnect: clearing spoof")
        isConnected = false
        status = "Disconnected"
        UserDefaults.standard.set(false, forKey: kWasConnected)
    }

    // MARK: - Private

    private func writeLocation(lat: Double, lon: Double) {
        flog(String(format: "writeLocation: %.5f, %.5f", lat, lon))

        var plist = locationPlist(lat: lat, lon: lon)
        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"
        var vfsResult: Int64 = -1
        plist.withUTF8 { ptr in
            vfsResult = vfs_write(plistPath, ptr.baseAddress!, ptr.count, 0)
        }
        flog("writeLocation: vfs_write plist -> \(vfsResult)")

        patchLocationdInKernel(lat: lat, lon: lon)

        DispatchQueue.global(qos: .background).async { [weak self] in
            let rcRet = rc_locationd_reload_plist()
            self?.flog("writeLocation: rc_locationd_reload -> \(rcRet == 0 ? "ok" : "skipped (code \(rcRet))")")
        }

        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
        filelog_flush()
    }

    private func patchLocationdInKernel(lat: Double, lon: Double) {
        guard ds_is_ready() else { flog("patchLocationdInKernel: ds not ready, skipping"); return }
        let procPtr = proc_find_by_name("locationd")
        guard procPtr != 0 else { flog("patchLocationdInKernel: locationd proc not found"); return }
        flog(String(format: "patchLocationdInKernel: found locationd proc @ 0x%llX", procPtr))
        scanAndPatch(procPtr: procPtr, lat: lat, lon: lon)
    }

    private func scanAndPatch(procPtr: UInt64, lat: Double, lon: Double) {
        let task  = proc_task(procPtr)
        guard task != 0 else { flog("scanAndPatch: proc_task == 0"); return }
        let vmMap = task_get_vm_map(task)
        guard vmMap != 0 else { flog("scanAndPatch: vm_map == 0"); return }

        let hdr      = vmMap + UInt64(off_vm_map_hdr)
        var entry    = ds_kread64(hdr + UInt64(off_vm_map_header_links_next))
        let sentinel = hdr
        var patched  = 0

        for _ in 0..<2048 {
            guard entry != 0, entry != sentinel else { break }
            let start     = ds_kread64(entry + 0x10)
            let end       = ds_kread64(entry + 0x18)
            let size      = end &- start
            let flagsWord = ds_kread64(entry + UInt64(off_vm_map_entry_vme_alias))
            let curProt   = UInt8((flagsWord >> 7) & 0x7)
            if curProt & 0x3 == 0x3, size >= 16, size <= 0x800_000 {
                var addr = start
                while addr &+ 16 <= end {
                    let rLat = Double(bitPattern: ds_kread64(addr))
                    let rLon = Double(bitPattern: ds_kread64(addr &+ 8))
                    if rLat.isFinite && rLon.isFinite
                        && rLat >= -90  && rLat <= 90
                        && rLon >= -180 && rLon <= 180
                        && abs(rLat) > 0.01 && abs(rLon) > 0.01 {
                        ds_kwrite64(addr,      lat.bitPattern)
                        ds_kwrite64(addr &+ 8, lon.bitPattern)
                        patched += 1
                    }
                    addr &+= 8
                }
            }
            entry = ds_kread64(entry + UInt64(off_vm_map_entry_links_next))
        }
        flog("scanAndPatch: patched \(patched) coordinate pair(s)")
    }

    private func locationPlist(lat: Double, lon: Double) -> String {
        """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>SimulatedLatitude</key><real>\(lat)</real>
            <key>SimulatedLongitude</key><real>\(lon)</real>
            <key>SimulationEnabled</key><true/>
        </dict>
        </plist>
        """
    }
}
