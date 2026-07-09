import SwiftUI

@main
struct LocationSpooferApp: App {
    @StateObject private var kernelManager = KernelLocationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(kernelManager)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                LogUploader.shared.uploadLog()
            } else if phase == .active {
                // Refresh the auto-detected t1sz_boot display when we come to
                // the foreground (offsets.m writes the resolved value under
                // kLaraT1sz during ds_run_safe()).
                UserDefaults.standard.synchronize()
                kernelManager.loadT1szDisplayFromMain()
            }
        }
    }
}
