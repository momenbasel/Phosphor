import SwiftUI

/// Device diagnostics: battery health, storage, live syslog, device actions.
struct DiagnosticsView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var diagVM = DiagnosticsViewModel()
    @State private var activeTab: DiagTab = .overview

    enum DiagTab: String, CaseIterable {
        case overview = "Overview"
        case syslog = "Console Log"
        case processes = "Processes"
        case crashes = "Crash Reports"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if deviceVM.selectedDevice == nil {
                EmptyStateView(
                    icon: "waveform.path.ecg",
                    title: "No Device Connected",
                    subtitle: "Connect a device to view diagnostics, battery health, and system logs."
                )
            } else {
                switch activeTab {
                case .overview:
                    overviewTab
                case .syslog:
                    syslogTab
                case .processes:
                    processListTab
                case .crashes:
                    crashReportsTab
                }
            }
        }
        .task {
            if let udid = deviceVM.selectedDevice?.id {
                await diagVM.loadAll(udid: udid)
            }
        }
        .alert("Diagnostics", isPresented: $diagVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(diagVM.alertMessage)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))

            Spacer()

            Picker("Tab", selection: $activeTab) {
                ForEach(DiagTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Button {
                if let udid = deviceVM.selectedDevice?.id {
                    Task { await diagVM.loadAll(udid: udid) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(20)
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let battery = diagVM.battery {
                    batteryCard(battery)
                }
                if let storage = diagVM.storage {
                    storageCard(storage)
                }
                deviceActionsCard
            }
            .padding(24)
        }
    }

    private func batteryCard(_ battery: DiagnosticsManager.BatteryDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Battery")

            HStack(spacing: 32) {
                // Large battery gauge
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.1), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(battery.currentCapacity) / 100)
                        .stroke(
                            batteryColor(battery),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 2) {
                        if battery.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                        }
                        Text("\(battery.currentCapacity)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Current")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Status", value: battery.isCharging ? "Charging" : "On Battery",
                            icon: "bolt.fill", valueColor: battery.isCharging ? .green : .primary)
                    InfoRow(label: "External Power", value: battery.externalConnected ? "Connected" : "Disconnected",
                            icon: "powerplug.fill")

                    if let health = battery.healthPercent {
                        InfoRow(
                            label: "Battery Health",
                            value: String(format: "%.0f%%", health),
                            icon: "heart.fill",
                            valueColor: health > 80 ? .green : health > 60 ? .orange : .red
                        )
                    }
                    if let design = battery.designCapacity {
                        InfoRow(label: "Design Capacity", value: "\(design) mAh", icon: "battery.100")
                    }
                    if let current = battery.currentMaxCapacity {
                        InfoRow(label: "Max Capacity Now", value: "\(current) mAh", icon: "battery.75")
                    }
                }
            }
        }
        .cardStyle()
    }

    private func storageCard(_ storage: DiagnosticsManager.StorageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Storage")

            StorageBar(
                segments: [
                    ("System", storage.systemUsage, .red.opacity(0.8)),
                    ("Apps", storage.appUsage, .blue),
                    ("Photos", storage.photoUsage, .orange),
                    ("Media", storage.mediaUsage, .purple),
                    ("Other", storage.otherUsage, .gray),
                ],
                total: storage.totalCapacity
            )

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storage.totalCapacity.formattedFileSize)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Total Capacity")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(storage.availableSpace.formattedFileSize)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("Available")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private var deviceActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Device Actions")

            HStack(spacing: 12) {
                ActionButton(icon: "arrow.clockwise", label: "Restart") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await diagVM.restart(udid: udid) }
                }

                ActionButton(icon: "power", label: "Shutdown") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await diagVM.shutdown(udid: udid) }
                }

                ActionButton(icon: "moon.fill", label: "Sleep") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await diagVM.sleep(udid: udid) }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Syslog

    private var syslogTab: some View {
        VStack(spacing: 0) {
            // Syslog controls
            HStack {
                Button {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    diagVM.toggleSyslog(udid: udid)
                } label: {
                    Label(
                        diagVM.isStreamingSyslog ? "Stop" : "Start",
                        systemImage: diagVM.isStreamingSyslog ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(diagVM.isStreamingSyslog ? .red : .indigo)

                HStack {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.tertiary)
                    TextField("Filter logs...", text: $diagVM.syslogFilter)
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                Text("\(diagVM.filteredSyslog.count) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button("Clear") { diagVM.clearSyslog() }

                Button("Export...") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "syslog-\(Int(Date().timeIntervalSince1970)).log"
                    if panel.runModal() == .OK, let url = panel.url {
                        diagVM.exportSyslog(to: url.path)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Log output
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(diagVM.filteredSyslog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(logColor(for: line))
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 1)
                    }
                }
            }
            .background(Color(.textBackgroundColor))
        }
    }

    // MARK: - Helpers

    private func batteryColor(_ battery: DiagnosticsManager.BatteryDiagnostics) -> Color {
        if battery.isCharging { return .green }
        if battery.currentCapacity <= 20 { return .red }
        if battery.currentCapacity <= 40 { return .orange }
        return .green
    }

    private func logColor(for line: String) -> Color {
        if line.contains("Error") || line.contains("error") || line.contains("FAULT") { return .red }
        if line.contains("Warning") || line.contains("warning") { return .orange }
        if line.contains("Debug") || line.contains("debug") { return .gray }
        return .primary
    }

    // MARK: - Process List Tab

    private var processListTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(diagVM.processes.count) running processes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await diagVM.loadProcesses(udid: udid) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if diagVM.isLoadingProcesses {
                LoadingOverlay(message: "Loading processes...")
            } else if diagVM.processes.isEmpty {
                EmptyStateView(
                    icon: "cpu",
                    title: "No Processes",
                    subtitle: "Requires pymobiledevice3 and DeveloperDiskImage on device."
                )
            } else {
                List(diagVM.processes) { proc in
                    HStack(spacing: 10) {
                        Text("\(proc.pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Text(proc.name)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let appName = proc.realAppName {
                            Text(appName)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Crash Reports Tab

    private var crashReportsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(diagVM.crashReports.count) crash reports")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Pull Crash Reports") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await diagVM.pullCrashReports(udid: udid) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if diagVM.isLoadingCrashes {
                LoadingOverlay(message: "Pulling crash reports...")
            } else if diagVM.crashReports.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "No Crash Reports",
                    subtitle: "Click Pull Crash Reports to download from device."
                )
            } else {
                List(diagVM.crashReports) { crash in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 14))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(crash.processName)
                                .font(.system(size: 13, weight: .medium))
                            Text(crash.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if let date = crash.date {
                            Text(date.shortString)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(crash.path, inFileViewerRootedAtPath: "")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
