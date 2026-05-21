import NetworkExtension
import Combine

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var isConnected: Bool = false
    @Published var status: String = "Disconnected"

    private let tunnelBundleID = "com.personal.locationspoofer.packettunnel"
    private let appGroupID = "group.com.personal.locationspoofer"

    private init() {
        loadStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusChanged),
            name: NSNotification.Name.NEVPNStatusDidChange,
            object: nil
        )
    }

    func saveCoordinates(lat: Double, lon: Double) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(lat, forKey: "spoofLat")
        defaults?.set(lon, forKey: "spoofLon")
        defaults?.synchronize()
    }

    func connect() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.status = "Error: \(error.localizedDescription)" }
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleID
            proto.serverAddress = "127.0.0.1"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Location Spoofer"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    DispatchQueue.main.async { self.status = "Save error: \(error.localizedDescription)" }
                    return
                }
                manager.loadFromPreferences { error in
                    if let error = error {
                        DispatchQueue.main.async { self.status = "Load error: \(error.localizedDescription)" }
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        DispatchQueue.main.async { self.status = "Start error: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    func disconnect() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            managers?.first?.connection.stopVPNTunnel()
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.status = "Disconnected"
            }
        }
    }

    @objc private func vpnStatusChanged() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let manager = managers?.first else { return }
            DispatchQueue.main.async {
                switch manager.connection.status {
                case .connected:
                    self?.isConnected = true
                    self?.status = "Connected"
                case .connecting:
                    self?.status = "Connecting..."
                case .disconnecting:
                    self?.status = "Disconnecting..."
                case .disconnected:
                    self?.isConnected = false
                    self?.status = "Disconnected"
                case .invalid:
                    self?.isConnected = false
                    self?.status = "Invalid"
                case .reasserting:
                    self?.status = "Reconnecting..."
                @unknown default:
                    break
                }
            }
        }
    }

    private func loadStatus() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let manager = managers?.first else { return }
            DispatchQueue.main.async {
                self?.isConnected = manager.connection.status == .connected
                switch manager.connection.status {
                case .connected: self?.status = "Connected"
                case .connecting: self?.status = "Connecting..."
                case .disconnected: self?.status = "Disconnected"
                default: self?.status = "Disconnected"
                }
            }
        }
    }
}
