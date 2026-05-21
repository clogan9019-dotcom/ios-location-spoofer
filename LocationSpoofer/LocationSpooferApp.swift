import SwiftUI

@main
struct LocationSpooferApp: App {
    @StateObject private var kernelManager = KernelLocationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(kernelManager)
        }
    }
}
