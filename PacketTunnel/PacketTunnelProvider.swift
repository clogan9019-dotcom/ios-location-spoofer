import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var proxyServer: LocationProxyServer?
    private let proxyPort: Int = 8890
    private let appGroupID = "group.com.personal.locationspoofer"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let defaults = UserDefaults(suiteName: appGroupID)
        let lat = defaults?.double(forKey: "spoofLat") ?? 37.3318
        let lon = defaults?.double(forKey: "spoofLon") ?? -122.0312

        proxyServer = LocationProxyServer(port: proxyPort, spoofLat: lat, spoofLon: lon)
        proxyServer?.start()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let proxySettings = NEProxySettings()
        let proxyHost = NEProxyServer(address: "127.0.0.1", port: proxyPort)
        proxySettings.httpsServer = proxyHost
        proxySettings.httpsEnabled = true
        proxySettings.httpServer = proxyHost
        proxySettings.httpEnabled = true
        proxySettings.matchDomains = [
            "gsp-ssl.ls.apple.com",
            "gspe1.apple.com",
            "gspe35-ssl.ls.apple.com",
            "configuration.ls.apple.com",
            "gs.apple.com"
        ]
        settings.proxySettings = proxySettings

        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        proxyServer?.stop()
        proxyServer = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let dict = try? JSONSerialization.jsonObject(with: messageData) as? [String: Double],
              let lat = dict["lat"], let lon = dict["lon"] else {
            completionHandler?(nil)
            return
        }
        proxyServer?.updateCoordinates(lat: lat, lon: lon)
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(lat, forKey: "spoofLat")
        defaults?.set(lon, forKey: "spoofLon")
        completionHandler?(messageData)
    }
}
