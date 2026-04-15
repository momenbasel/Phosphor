import SwiftUI

/// Root view. NavigationSplitView with sidebar for navigation and detail pane.
struct ContentView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel

    @State private var selectedSection: SidebarSection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var tunnelRunning = true
    @State private var tunnelStarting = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // Tunnel banner - shows when tunnel not running and device connected
                if !tunnelRunning && deviceVM.hasDevices {
                    tunnelBanner
                }
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Phosphor")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        .task {
            // Check tunnel status on launch and periodically
            await checkTunnel()
        }
    }

    private var tunnelBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .foregroundStyle(.orange)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text("Tunnel service not running")
                    .font(.system(size: 12, weight: .medium))
                Text("Required for screen capture, location spoofing, and process list on iOS 17+")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tunnelStarting {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Starting...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Start Tunnel") {
                    tunnelStarting = true
                    TunnelService.start()
                    // Check after a few seconds
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        await checkTunnel()
                        tunnelStarting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.small)

                Button {
                    tunnelRunning = true // dismiss banner
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func checkTunnel() async {
        tunnelRunning = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                c.resume(returning: TunnelService.isRunning)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .devices:
            DeviceOverviewView()
        case .backups:
            BackupListView()
        case .backupBrowser:
            BackupBrowserView()
        case .timeMachine:
            BackupTimeMachineView()
        case .messages:
            MessageListView()
        case .whatsapp:
            WhatsAppView()
        case .photos:
            PhotoBrowserView()
        case .apps:
            AppManagerView()
        case .notes:
            NotesView()
        case .callLog:
            CallLogView()
        case .safari:
            SafariView()
        case .health:
            HealthView()
        case .music:
            MusicView()
        case .watch:
            AppleWatchView()
        case .contacts:
            ContactsView()
        case .calendar:
            CalendarView()
        case .clone:
            DeviceCloneView()
        case .files:
            FileBrowserView()
        case .diagnostics:
            DiagnosticsView()
        case .battery:
            BatteryView()
        case .screenCapture:
            ScreenCaptureView()
        case .location:
            LocationView()
        case .none:
            WelcomeView()
        }
    }

    @ViewBuilder
    private var toolbarItems: some View {
        if deviceVM.isRefreshing {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        }

        Button {
            Task { await deviceVM.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh devices")

        if let device = deviceVM.selectedDevice {
            HStack(spacing: 6) {
                Image(systemName: device.sfSymbolName)
                    .font(.system(size: 14))
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))

                if let level = device.batteryLevel {
                    BatteryIndicator(level: level, charging: device.batteryCharging ?? false)
                }

                // Connection badge
                Text(device.connectionType.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(device.connectionType == .wifi ? Color.blue : Color.green)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(Capsule())
        }
    }
}

/// Small inline battery indicator for the toolbar.
struct BatteryIndicator: View {
    let level: Int
    let charging: Bool

    var body: some View {
        HStack(spacing: 3) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
            }
            Text("\(level)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.batteryColor(level: level, charging: charging))
        }
    }
}

/// Shown when no section is selected - improved with quick-start guidance.
struct WelcomeView: View {

    @State private var isPulsing = false
    @State private var depStatus: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "light.beacon.max")
                .font(.system(size: 56))
                .foregroundStyle(.indigo)
                .symbolRenderingMode(.hierarchical)
                .scaleEffect(isPulsing ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }

            Text("Phosphor")
                .font(.largeTitle.weight(.bold))

            Text("Version \(AppVersion.current)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Connect an iOS device or select a section from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                depRow("pymobiledevice3", installed: depStatus["pymobiledevice3"] ?? false)
                depRow("libimobiledevice", installed: depStatus["ideviceinfo"] ?? false)
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            depStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Shell.checkDependencies())
                }
            }
        }
    }

    private func depRow(_ name: String, installed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(installed ? .green : .orange)
                .font(.system(size: 14))
            Text(name)
                .font(.system(size: 13, design: .monospaced))
            Spacer()
            Text(installed ? "Ready" : "Not found")
                .font(.system(size: 11))
                .foregroundColor(installed ? .secondary : .orange)
        }
        .frame(width: 280)
    }
}

#Preview {
    ContentView()
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
}
