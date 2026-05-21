import SwiftUI

struct NetworkScannerView: View {
    @EnvironmentObject var kernelManager: KernelLocationManager
    @StateObject private var scanner = NetworkScanner()

    @State private var host        = "192.168.1.1"
    @State private var preset      : PortPreset = .top20
    @State private var customFrom  = "1"
    @State private var customTo    = "1024"
    @State private var scanType    : ScanType   = .tcpConnect
    @State private var showLog     = false

    private var resolvedPorts: [Int] {
        if preset == .custom {
            let lo = max(1, Int(customFrom) ?? 1)
            let hi = min(65535, Int(customTo) ?? 1024)
            return Array(min(lo, hi)...max(lo, hi))
        }
        return preset.ports
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                configCard
                if scanner.isScanning || scanner.progress > 0 {
                    progressCard
                }
                if !scanner.results.isEmpty {
                    resultsCard
                }
                if !scanner.logLines.isEmpty {
                    logCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: – Config

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {

            label("Target Host")

            HStack {
                Image(systemName: "network")
                    .foregroundColor(.secondary)
                TextField("IP address or hostname", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))

            Divider()
            label("Port Range")

            Picker("Ports", selection: $preset) {
                ForEach(PortPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if preset == .custom {
                HStack(spacing: 8) {
                    portField(title: "From", text: $customFrom)
                    Text("–").foregroundColor(.secondary)
                    portField(title: "To", text: $customTo)
                }
            }

            Divider()
            label("Scan Method")

            VStack(spacing: 8) {
                ForEach(ScanType.allCases) { type in
                    scanTypeRow(type)
                }
            }

            Divider()

            if scanner.isScanning {
                Button(role: .destructive) {
                    scanner.cancel()
                } label: {
                    Label("Stop Scan", systemImage: "stop.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.red)
                }
            } else {
                Button { beginScan() } label: {
                    Label("Start Scan", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [.blue, .cyan],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                }
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || resolvedPorts.isEmpty)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    @ViewBuilder
    private func scanTypeRow(_ type: ScanType) -> some View {
        let locked   = type.requiresExploit && !kernelManager.exploitReady
        let selected = scanType == type
        Button {
            if !locked { scanType = type }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.system(size: 18))
                    .foregroundColor(locked ? .secondary : selected ? .white : .accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(locked ? .secondary : selected ? .white : .primary)
                    Text(locked ? "Requires kernel exploit" : type.detail)
                        .font(.system(size: 11))
                        .foregroundColor(locked ? .secondary
                                        : selected ? .white.opacity(0.8) : .secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.white)
                        .font(.system(size: 13, weight: .bold))
                }
                if locked {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
            }
            .padding(12)
            .background(
                Group {
                    if selected {
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color(.systemGroupedBackground)
                    }
                },
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    // MARK: – Progress

    private var progressCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text(scanner.isScanning ? "Scanning…" : "Scan Complete")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int(scanner.progress * 100))%")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: scanner.progress)
                .tint(.blue)
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("\(scanner.openCount) open port\(scanner.openCount == 1 ? "" : "s") found")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: – Results

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Open Ports")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ForEach(scanner.results.sorted { $0.port < $1.port }) { r in
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("\(r.port)/\(r.proto.lowercased())")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        Text(r.status.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.green)
                        Spacer()
                        if let ms = r.latencyMs {
                            Text(String(format: "%.0f ms", ms))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 34)
                }
            }
            .padding(.bottom, 4)
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: – Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() }
            } label: {
                HStack {
                    label("Log")
                    Spacer()
                    Image(systemName: showLog ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showLog {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(scanner.logLines.indices, id: \.self) { i in
                                Text(scanner.logLines[i])
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: scanner.logLines.count) { _ in
                        if let last = scanner.logLines.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: – Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func portField(title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 8))
    }

    private func beginScan() {
        let ports: [Int]
        if preset == .custom {
            let lo = max(1, Int(customFrom) ?? 1)
            let hi = min(65535, Int(customTo) ?? 1024)
            ports = Array(min(lo, hi)...max(lo, hi))
        } else {
            ports = preset.ports
        }
        scanner.start(host: host.trimmingCharacters(in: .whitespaces),
                      ports: ports, type: scanType)
        showLog = true
    }
}
