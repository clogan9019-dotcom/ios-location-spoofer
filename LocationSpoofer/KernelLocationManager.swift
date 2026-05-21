import Foundation
import Combine

final class KernelLocationManager: ObservableObject {
    static let shared = KernelLocationManager()

    @Published var isConnected: Bool = false
    @Published var status: String = "Disconnected"

    private init() {}

    func connect(lat: Double, lon: Double) {
        DispatchQueue.main.async {
            self.status = "Starting exploit..."
            self.isConnected = false
        }

        ds_set_log_callback { msg in
            guard let msg else { return }
            let s = String(cString: msg)
            DispatchQueue.main.async { KernelLocationManager.shared.status = s }
        }

        ds_set_progress_callback { _ in }

        DispatchQueue.global(qos: .userInitiated).async {
            let ret = ds_run()
            guard ret == 0, ds_is_ready() else {
                DispatchQueue.main.async {
                    self.status = "Exploit failed (code \(ret))"
                }
                return
            }

            DispatchQueue.main.async { self.status = "Kernel R/W ready — initialising VFS..." }

            let vfsRet = vfs_init()
            guard vfsRet == 0 || vfs_isready() else {
                DispatchQueue.main.async { self.status = "VFS init failed (\(vfsRet))" }
                return
            }

            DispatchQueue.main.async { self.status = "Injecting location..." }
            self.writeLocation(lat: lat, lon: lon)
        }
    }

    func updateLocation(lat: Double, lon: Double) {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.writeLocation(lat: lat, lon: lon)
        }
    }

    func disconnect() {
        isConnected = false
        status = "Disconnected"
    }

    // MARK: - Private

    private func writeLocation(lat: Double, lon: Double) {
        // 1. VFS path — write simulated location plist that locationd respects
        var plist = locationPlist(lat: lat, lon: lon)
        let plistPath = "/private/var/mobile/Library/Preferences/com.apple.locationd.plist"
        plist.withUTF8 { ptr in
            _ = vfs_write(plistPath, ptr.baseAddress!, ptr.count, 0)
        }

        // 2. Kernel direct path — scan locationd heap and overwrite coordinate pairs
        patchLocationdInKernel(lat: lat, lon: lon)

        DispatchQueue.main.async {
            self.isConnected = true
            self.status = String(format: "Spoofing %.5f, %.5f", lat, lon)
        }
    }

    private func patchLocationdInKernel(lat: Double, lon: Double) {
        guard ds_is_ready() else { return }

        // Use the utility function — it uses the correct off_proc_* offsets internally
        let procPtr = proc_find_by_name("locationd")
        guard procPtr != 0 else { return }

        scanAndPatch(procPtr: procPtr, lat: lat, lon: lon)
    }

    private func scanAndPatch(procPtr: UInt64, lat: Double, lon: Double) {
        // Use utility helpers that already apply the correct kernel struct offsets
        let task  = proc_task(procPtr)
        guard task != 0 else { return }
        let vmMap = task_get_vm_map(task)
        guard vmMap != 0 else { return }

        // vm_map circular linked list.
        // Sentinel = address of the header's links node (hdr is the first field of vm_map).
        let hdr      = vmMap + UInt64(off_vm_map_hdr)
        var entry    = ds_kread64(hdr + UInt64(off_vm_map_header_links_next))
        let sentinel = hdr

        for _ in 0..<2048 {
            guard entry != 0, entry != sentinel else { break }

            // vm_map_links is always the first field of vm_map_entry:
            //   +0x00 prev, +0x08 next, +0x10 start, +0x18 end
            let start = ds_kread64(entry + 0x10)
            let end   = ds_kread64(entry + 0x18)
            let size  = end &- start

            // Protection bits live in the vme_alias word.
            // cur_protection is bits [9:7] per XNU vm_map_entry bitfield layout.
            let flagsWord = ds_kread64(entry + UInt64(off_vm_map_entry_vme_alias))
            let curProt   = UInt8((flagsWord >> 7) & 0x7)

            // Only scan readable+writable regions of sane size
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

    // MARK: - Helpers

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
