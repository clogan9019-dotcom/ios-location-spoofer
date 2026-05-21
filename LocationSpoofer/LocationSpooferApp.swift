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
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                kernelManager.restoreIfNeeded()
            }
        }
    }
}
