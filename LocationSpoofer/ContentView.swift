import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @StateObject private var locationSearch = LocationSearchViewModel()

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var selectedPin: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    @State private var searchText = ""
    @State private var showSuggestions = false
    @State private var showAdvanced = false

    var body: some View {
        ZStack(alignment: .top) {
            MapView(region: $region, selectedPin: $selectedPin)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    searchBar
                    Button {
                        showAdvanced = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                }
                .padding(.top, 56)
                .padding(.horizontal, 16)

                if showSuggestions && !locationSearch.results.isEmpty {
                    suggestionsDropdown
                        .padding(.horizontal, 16)
                }

                Spacer()

                bottomCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 34)
            }
        }
        .onChange(of: searchText) { newValue in
            locationSearch.search(query: newValue)
            showSuggestions = !newValue.isEmpty
        }
        .sheet(isPresented: $showAdvanced) {
            AdvancedSettingsView()
                .environmentObject(kernelManager)
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
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
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
                Button {
                    selectSearchResult(result)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            Text(result.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
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
        VStack(spacing: 16) {
            if let pin = selectedPin {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spoofed Location")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    Image(systemName: "location.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(kernelManager.status)
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
                                kernelManager.connect(lat: pin.latitude, lon: pin.longitude)
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
        .padding(20)
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

// MARK: - Advanced Settings Sheet

struct AdvancedSettingsView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var customHex: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    private let presets: [(label: String, chip: String, hex: String)] = [
        ("A12 / A13",      "iPhone XS–11",        "0x19"),
        ("A14 / A15",      "iPhone 12–13",         "0x19"),
        ("A16+ / M-series","iPhone 14 Pro+ / iPad", "0x11"),
        ("A17 Pro",        "iPhone 15 Pro",         "0x11"),
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
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("t1sz_boot")
                } footer: {
                    Text("This value must match your device's chip. A wrong value causes the exploit to mis-sign kernel pointers and fail. Set it manually here if auto-detection produces incorrect results.")
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
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("Apply Custom Value") {
                        applyCustom()
                    }
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
                    Text("Auto-detect resolves the value from the kernelcache at exploit time. Use this if you're unsure which value to set.")
                        .font(.caption)
                }
            }
            .navigationTitle("Advanced Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func applyPreset(_ hex: String) {
        let success = kernelManager.setT1szBootOverride(hex)
        if !success {
            errorMessage = "Failed to apply preset."
            showError = true
        } else {
            showError = false
        }
    }

    private func applyCustom() {
        let trimmed = customHex.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let success = kernelManager.setT1szBootOverride("0x\(trimmed)")
        if success {
            showError = false
        } else {
            errorMessage = "Invalid hex value. Enter digits like 11 or 19."
            showError = true
        }
    }
}

// MARK: - Map

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
            let annotation = MKPointAnnotation()
            annotation.coordinate = pin
            map.addAnnotation(annotation)
        }
        return map
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if let pin = selectedPin {
            mapView.removeAnnotations(mapView.annotations)
            let annotation = MKPointAnnotation()
            annotation.coordinate = pin
            mapView.addAnnotation(annotation)
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
            let mapView = gesture.view as! MKMapView
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            parent.selectedPin = coord
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            view.markerTintColor = UIColor.systemBlue
            view.glyphImage = UIImage(systemName: "location.fill")
            return view
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
