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

    private let kLastLat      = "spoofer_last_lat"
    private let kLastLon      = "spoofer_last_lon"
    private let kWasConnected = "spoofer_was_connected"
    private let kT1szOverride = "spoofer_t1sz_override"
    private let kLaraT1sz     = "lara.t1sz_boot"

    private var cancelRequested = false
    private var workItem: DispatchWorkItem?

    private init() {
        loadT1szDisplay()
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
        return true
    }

    func clearT1szBootOverride() {
        UserDefaults.standard.removeObject(forKey: kT1szOverride)
        UserDefaults.standard.removeObject(forKey: kLaraT1sz)
        UserDefaults.standard.synchronize()
        t1szBootDisplay = "Auto (not yet resolved)"
    }

    // MARK: - Logs

    func appendLog(_ msg: String) {
        DispatchQueue.main.async { self.logs.append(msg) }
    }

    func clearLogs() { logs = [] }

    // MARK: - Foreground restore

    func restoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: kWasConnected) else { return }
        let lat = UserDefaults.standard.double(forKey: kLastLat)
        let lon = UserDefaults.standard.double(forKey: kLastLon)
        guard lat != 0 || lon != 0 else { return }

        if ds_is_ready() {
            DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
        } else {
            runExploit { [weak self] success in
                guard let self, success else { return }
                self.applySpoof(lat: lat, lon: lon)
            }
        }
    }

    // MARK: - Exploit runner

    func runExploit(completion: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }

        DispatchQueue.main.async {
            self.isRunning       = true
            self.exploitReady    = false
            self.exploitError    = nil
            self.progress        = 0.0
            self.status          = "Starting exploit..."
            self.cancelRequested = false
        }

        let override = UserDefaults.standard.object(forKey: kT1szOverride) as? UInt64 ?? 0
        if override != 0 { UserDefaults.standard.set(override, forKey: kLaraT1sz) }

        ds_set_log_callback { msg in
            guard let msg else { return }
            let s = String(cString: msg)
            KernelLocationManager.shared.appendLog(s)
            DispatchQueue.main.async { KernelLocationManager.shared.status = s }
        }
        ds_set_progress_callback { pct in
            DispatchQueue.main.async { KernelLocationManager.shared.progress = Double(pct) }
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }

            if self.cancelRequested {
                DispatchQueue.main.async {
                    self.isRunning = false; self.status = "Cancelled"; self.progress = 0
                }
                completion?(false); return
            }

            // ── ds_run() wrapped in signal-based crash guard ──────────────
            let ret = ds_run_safe()

            if ret < 0 {
                // A signal was caught (SIGSEGV / SIGBUS / SIGILL etc.)
                let sigName = String(cString: ds_run_safe_signal_name())
                let err = "Exploit crashed — caught \(sigName)"
                self.appendLog("CRASH: \(err)")
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            if self.cancelRequested {
                DispatchQueue.main.async {
                    self.isRunning = false; self.status = "Stopped"; self.progress = 0
                }
                completion?(false); return
            }

            guard ret == 0, ds_is_ready() else {
                let err = "Exploit failed (code \(ret))"
                self.appendLog("ERROR: \(err)")
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            self.appendLog("Kernel R/W ready — initialising VFS...")
            DispatchQueue.main.async { self.status = "Kernel R/W ready — initialising VFS..." }

            let vfsRet = vfs_init()
            guard vfsRet == 0 || vfs_isready() else {
                let err = "VFS init failed (\(vfsRet))"
                self.appendLog("ERROR: \(err)")
                DispatchQueue.main.async {
                    self.isRunning = false; self.exploitError = err
                    self.status = err; self.progress = 0
                }
                completion?(false); return
            }

            self.appendLog("Exploit complete — kernel ready")
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
        cancelRequested = true
        workItem?.cancel()
        DispatchQueue.main.async {
            self.isRunning = false; self.status = "Stopped by user"; self.progress = 0
        }
    }

    // MARK: - Location spoofing

    func connect(lat: Double, lon: Double) {
        UserDefaults.standard.set(lat,  forKey: kLastLat)
        UserDefaults.standard.set(lon,  forKey: kLastLon)
        UserDefaults.standard.set(true, forKey: kWasConnected)
        if exploitReady {
            DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
        } else {
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
        DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
    }

    func updateLocation(lat: Double, lon: Double) {
        guard isConnected else { return }
        UserDefaults.standard.set(lat, forKey: kLastLat)
        UserDefaults.standard.set(lon, forKey: kLastLon)
        DispatchQueue.global(qos: .userInitiated).async { self.writeLocation(lat: lat, lon: lon) }
    }

    func disconnect() {
        isConnected = false
        status = "Disconnected"
        UserDefaults.standard.set(false, forKey: kWasConnected)
    }

    // MARK: - Private

    private func writeLocation(lat: Double, lon: Double) {
        // 1. Write the simulated-location plist via VFS
        var plist = locationPlist(lat: lat, lon: lon)
        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"
        plist.withUTF8 { ptr in
            _ = vfs_write(plistPath, ptr.baseAddress!, ptr.count, 0)
        }
        appendLog("VFS: plist written")

        // 2. Kernel heap-scan patch (existing reliable path)
        patchLocationdInKernel(lat: lat, lon: lon)

        // 3. RemoteCall: notify locationd from inside its own process so it
        //    flushes its preference cache and picks up the plist immediately.
        DispatchQueue.global(qos: .background).async { [weak self] in
            let rcRet = rc_locationd_reload_plist()
            self?.appendLog(rcRet == 0
                ? "RC: locationd plist reload triggered"
                : "RC: notify skipped (code \(rcRet)) — heap patch still active")
        }

        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
    }

    private func patchLocationdInKernel(lat: Double, lon: Double) {
        guard ds_is_ready() else { return }
        let procPtr = proc_find_by_name("locationd")
        guard procPtr != 0 else { return }
        scanAndPatch(procPtr: procPtr, lat: lat, lon: lon)
    }

    private func scanAndPatch(procPtr: UInt64, lat: Double, lon: Double) {
        let task  = proc_task(procPtr)
        guard task != 0 else { return }
        let vmMap = task_get_vm_map(task)
        guard vmMap != 0 else { return }

        let hdr      = vmMap + UInt64(off_vm_map_hdr)
        var entry    = ds_kread64(hdr + UInt64(off_vm_map_header_links_next))
        let sentinel = hdr

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
                    }
                    addr &+= 8
                }
            }
            entry = ds_kread64(entry + UInt64(off_vm_map_entry_links_next))
        }
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
