import Foundation
import Combine

final class KernelLocationManager: ObservableObject {
    static let shared = KernelLocationManager()

    @Published var isConnected: Bool = false
    @Published var status: String = "Disconnected"

    private init() {}

    func saveCoordinates(lat: Double, lon: Double) {
        // Coordinates are passed directly to activate()
    }

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
        let plist = locationPlist(lat: lat, lon: lon)
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

        // Walk the kernel proc list starting from our own proc
        var procPtr = ds_get_our_proc()
        guard procPtr != 0 else { return }

        for _ in 0..<512 {
            var name = [CChar](repeating: 0, count: 64)
            ds_kread(procPtr &+ 0x56c, &name, 16)
            if String(cString: name).hasPrefix("locationd") {
                scanAndPatch(procPtr: procPtr, lat: lat, lon: lon)
                return
            }
            let next = ds_kread64(procPtr &+ 0x8)
            guard next != 0 else { break }
            procPtr = next
        }
    }

    private func scanAndPatch(procPtr: UInt64, lat: Double, lon: Double) {
        let procRo  = ds_kread64(procPtr &+ 0x18)
        let task    = ds_kread64(procRo  &+ 0x08)
        let vmMap   = ds_kread64(task    &+ 0x28)
        var entry   = ds_kread64(vmMap   &+ 0x18)

        for _ in 0..<2048 {
            guard entry != 0, entry != vmMap &+ 0x10 else { break }

            let start = ds_kread64(entry &+ 0x10)
            let end   = ds_kread64(entry &+ 0x18)
            let flags = ds_kread64(entry &+ 0x48)
            let prot  = (flags >> 7) & 0xF
            let size  = end &- start

            if prot & 0x3 == 0x3, size >= 16, size <= 0x800_000 {
                var addr = start
                while addr &+ 16 <= end {
                    let rLat = Double(bitPattern: ds_kread64(addr))
                    let rLon = Double(bitPattern: ds_kread64(addr &+ 8))
                    if rLat.isFinite && rLon.isFinite
                        && rLat >= -90 && rLat <= 90
                        && rLon >= -180 && rLon <= 180
                        && abs(rLat) > 0.01 && abs(rLon) > 0.01 {
                        ds_kwrite64(addr,       lat.bitPattern)
                        ds_kwrite64(addr &+ 8,  lon.bitPattern)
                    }
                    addr &+= 8
                }
            }
            entry = ds_kread64(entry &+ 0x08)
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
