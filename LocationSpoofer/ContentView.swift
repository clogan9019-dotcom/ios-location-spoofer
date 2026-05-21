import SwiftUI
import MapKit
import CoreLocation

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Exploit", systemImage: "cpu") }
                .environmentObject(kernelManager)

            ToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
                .environmentObject(kernelManager)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .environmentObject(kernelManager)
        }
    }
}

// MARK: - Home (Exploit Runner)

struct HomeView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @State private var showLogs = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    statusCard
                    progressCard
                    actionButtons
                    if let err = kernelManager.exploitError {
                        errorCard(err)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Kernel Exploit")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLogs = true
                    } label: {
                        Label("Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showLogs) {
                LogsView().environmentObject(kernelManager)
            }
        }
    }

    // MARK: Status card
    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(kernelManager.status)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    // MARK: Progress card
    private var progressCard: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 12)
                    .frame(width: 140, height: 140)
                Circle()
                    .trim(from: 0, to: kernelManager.progress)
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: kernelManager.progress)

                VStack(spacing: 2) {
                    Text("\(Int(kernelManager.progress * 100))%")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    if kernelManager.isRunning {
                        Text("Running")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    } else if kernelManager.exploitReady {
                        Text("Complete")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.green)
                    } else {
                        Text("Idle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    // MARK: Action buttons
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if kernelManager.isRunning {
                Button(role: .destructive) {
                    kernelManager.cancelExploit()
                } label: {
                    Label("Force Stop", systemImage: "stop.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundColor(.red)
                }
            } else {
                Button {
                    kernelManager.clearLogs()
                    kernelManager.runExploit()
                } label: {
                    Label(
                        kernelManager.exploitReady ? "Re-run Exploit" : "Run Exploit",
                        systemImage: kernelManager.exploitReady ? "arrow.clockwise" : "play.fill"
                    )
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .leading,
                                       endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundColor(.white)
                }
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)

                if !kernelManager.logs.isEmpty {
                    Button {
                        showLogs = true
                    } label: {
                        Label("View Logs (\(kernelManager.logs.count) lines)", systemImage: "doc.text")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundColor(.primary)
                    }
                }
            }
        }
    }

    // MARK: Error card
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Exploit Error")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                Spacer()
                Button {
                    kernelManager.exploitError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            Text(message)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(6)
            Text("The app caught this error safely. You can retry or check your t1sz_boot setting in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.2)))
    }

    // MARK: Helpers
    private var statusColor: Color {
        if kernelManager.exploitError != nil { return .red }
        if kernelManager.exploitReady       { return .green }
        if kernelManager.isRunning          { return .blue }
        return .secondary
    }

    private var statusIcon: String {
        if kernelManager.exploitError != nil { return "exclamationmark.triangle.fill" }
        if kernelManager.exploitReady       { return "checkmark.seal.fill" }
        if kernelManager.isRunning          { return "waveform" }
        return "cpu"
    }
}

// MARK: - Logs Sheet

struct LogsView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @Environment(\.dismiss) private var dismiss
    @State private var autoScroll = true

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if kernelManager.logs.isEmpty {
                            Text("No logs yet. Run the exploit to see output here.")
                                .foregroundColor(.secondary)
                                .padding(20)
                        } else {
                            ForEach(Array(kernelManager.logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(logColor(line))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(.systemBackground))
                .onChange(of: kernelManager.logs.count) { _ in
                    if autoScroll, let last = kernelManager.logs.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        kernelManager.clearLogs()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("fail") || l.contains("crash") { return .red }
        if l.contains("warn")                                                { return .orange }
        if l.contains("ready") || l.contains("success") || l.contains("ok") { return .green }
        return .primary
    }
}

// MARK: - Tools (Location Spoofer)

struct ToolsView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @StateObject private var locationSearch = LocationSearchViewModel()

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var selectedPin: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    @State private var searchText = ""
    @State private var showSuggestions = false

    var body: some View {
        NavigationView {
            ZStack {
                if kernelManager.exploitReady {
                    spooferView
                } else {
                    lockedView
                }
            }
            .navigationTitle("Location Spoofer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Locked overlay
    private var lockedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Kernel Not Ready")
                .font(.title2.bold())
            Text("Go to the Exploit tab and run the exploit first. Once the kernel is ready, the location spoofer will unlock.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)
            if kernelManager.isRunning {
                ProgressView()
                Text("Running… \(Int(kernelManager.progress * 100))%")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Map spoofer
    private var spooferView: some View {
        ZStack(alignment: .top) {
            MapView(region: $region, selectedPin: $selectedPin)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .padding(.top, 8)
                    .padding(.horizontal, 16)

                if showSuggestions && !locationSearch.results.isEmpty {
                    suggestionsDropdown
                        .padding(.horizontal, 16)
                }

                Spacer()

                bottomCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .onChange(of: searchText) { newValue in
            locationSearch.search(query: newValue)
            showSuggestions = !newValue.isEmpty
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search location...", text: $searchText)
                .autocorrectionDisabled()
                .onSubmit { showSuggestions = false }
            if !searchText.isEmpty {
                Button { searchText = ""; showSuggestions = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(locationSearch.results.prefix(5)) { result in
                Button { selectSearchResult(result) } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).font(.system(size: 14, weight: .medium)).foregroundColor(.primary)
                            Text(result.subtitle).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                if result.id != locationSearch.results.prefix(5).last?.id {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var bottomCard: some View {
        VStack(spacing: 14) {
            if let pin = selectedPin {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected Location")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                    Spacer()
                    Image(systemName: "location.fill").font(.system(size: 22)).foregroundColor(.accentColor)
                }
                .padding(.horizontal, 4)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spoof")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(kernelManager.isConnected ? kernelManager.status : "Off")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(kernelManager.isConnected ? .green : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { kernelManager.isConnected },
                    set: { newVal in
                        if newVal {
                            if let pin = selectedPin {
                                kernelManager.applySpoof(lat: pin.latitude, lon: pin.longitude)
                            }
                        } else {
                            kernelManager.disconnect()
                        }
                    }
                ))
                .labelsHidden()
                .tint(.green)
            }
            .padding(.horizontal, 4)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private func selectSearchResult(_ result: SearchResult) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString("\(result.title) \(result.subtitle)") { placemarks, _ in
            guard let loc = placemarks?.first?.location else { return }
            DispatchQueue.main.async {
                selectedPin = loc.coordinate
                region = MKCoordinateRegion(
                    center: loc.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
                searchText = result.title
                showSuggestions = false
                if kernelManager.isConnected {
                    kernelManager.updateLocation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @State private var customHex: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    private let presets: [(label: String, chip: String, hex: String)] = [
        ("A12 / A13",        "iPhone XS – 11",        "0x19"),
        ("A14 / A15",        "iPhone 12 – 13",        "0x19"),
        ("A16+ / M-series",  "iPhone 14 Pro+ / iPad", "0x11"),
        ("A17 Pro",          "iPhone 15 Pro",         "0x11"),
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Current value")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(kernelManager.t1szBootDisplay)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("t1sz_boot")
                } footer: {
                    Text("Must match your device's chip. A wrong value mis-signs kernel pointers and causes the exploit to fail.")
                        .font(.caption)
                }

                Section("Quick Presets") {
                    ForEach(presets, id: \.hex) { preset in
                        Button {
                            applyPreset(preset.hex)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.label)
                                        .foregroundColor(.primary)
                                        .font(.system(size: 15, weight: .medium))
                                    Text(preset.chip)
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12))
                                }
                                Spacer()
                                Text(preset.hex)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section("Custom Value") {
                    HStack {
                        Text("0x")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                        TextField("e.g. 11 or 19", text: $customHex)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                    }
                    if showError {
                        Text(errorMessage).font(.caption).foregroundColor(.red)
                    }
                    Button("Apply Custom Value") { applyCustom() }
                        .disabled(customHex.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Button(role: .destructive) {
                        kernelManager.clearT1szBootOverride()
                        customHex = ""
                        showError = false
                    } label: {
                        Label("Reset to Auto-Detect", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Auto-detect resolves the value from the kernelcache at exploit time.")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func applyPreset(_ hex: String) {
        if !kernelManager.setT1szBootOverride(hex) {
            errorMessage = "Failed to apply preset."
            showError = true
        } else {
            showError = false
        }
    }

    private func applyCustom() {
        let trimmed = customHex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if kernelManager.setT1szBootOverride("0x\(trimmed)") {
            showError = false
        } else {
            errorMessage = "Invalid hex. Enter digits like 11 or 19."
            showError = true
        }
    }
}

// MARK: - MapView

struct MapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var selectedPin: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(region, animated: false)
        map.showsUserLocation = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        if let pin = selectedPin {
            let a = MKPointAnnotation(); a.coordinate = pin; map.addAnnotation(a)
        }
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if let pin = selectedPin {
            mapView.removeAnnotations(mapView.annotations)
            let a = MKPointAnnotation(); a.coordinate = pin; mapView.addAnnotation(a)
        }
        if abs(mapView.region.center.latitude - region.center.latitude) > 0.0001 ||
           abs(mapView.region.center.longitude - region.center.longitude) > 0.0001 {
            mapView.setRegion(region, animated: true)
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        init(_ parent: MapView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let map = gesture.view as! MKMapView
            parent.selectedPin = map.convert(gesture.location(in: map), toCoordinateFrom: map)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            v.markerTintColor = UIColor.systemBlue
            v.glyphImage = UIImage(systemName: "location.fill")
            return v
        }
    }
}

// MARK: - Search

struct SearchResult: Identifiable {
    let id = UUID().uuidString
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion
}

class LocationSearchViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [SearchResult] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(query: String) {
        guard !query.isEmpty else { results = []; return }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = completer.results.map {
                SearchResult(title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
        }
    }
}
