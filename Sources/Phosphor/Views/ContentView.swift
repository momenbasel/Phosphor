import SwiftUI

/// Root view. NavigationSplitView with sidebar for navigation and detail pane.
struct ContentView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @EnvironmentObject var messageVM: MessageViewModel

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
                if messageVM.isExporting { messageExportProgressView }
            }
        }
        .navigationTitle("Phosphor")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        // Presented at the root so every entry point into a backup - Backups,
        // Messages, Photos, Apps, the time machine - gets the same prompt.
        .sheet(item: $backupVM.pendingUnlock) { backup in
            BackupUnlockSheet(backup: backup)
                .environmentObject(backupVM)
        }
        .task {
            // Defer process probing until after first paint.
            try? await Task.sleep(for: .milliseconds(750))
            await checkTunnel()
        }
    }

    /// Warning-tinted card banner for the missing tunnel service.
    private var tunnelBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "network.badge.shield.half.filled")
                .foregroundStyle(.orange)
                .font(.system(size: 16, weight: .medium))

            VStack(alignment: .leading, spacing: 1) {
                Text("Tunnel service not running")
                    .font(.system(size: 12, weight: .semibold))
                Text("Required for screen capture, location spoofing, and process list on iOS 17+")
                    .font(.system(size: 11))
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
                .tint(.orange)
                .controlSize(.small)

                Button {
                    tunnelRunning = true // dismiss banner
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var messageExportProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(messageVM.exportProgressText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { messageVM.cancelExport() }
                    .controlSize(.small)
            }
            ProgressView(value: messageVM.exportProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(.brandAccent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.brandAccent.opacity(0.06))
    }

    private func checkTunnel() async {
        tunnelRunning = await Task.detached(priority: .utility) {
            TunnelService.isRunning
        }.value
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .devices:
            DeviceOverviewView()
        case .readiness:
            ReadinessCenterView()
        case .backups:
            BackupListView(onBrowseBackup: { selectedSection = .backupBrowser })
        case .backupBrowser:
            BackupBrowserView()
        case .timeMachine:
            BackupTimeMachineView(onBrowseBackup: { selectedSection = .backupBrowser })
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
            WelcomeView(onOpenReadiness: { selectedSection = .readiness })
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.brandAccent)
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))

                if let level = device.batteryLevel {
                    BatteryIndicator(level: level, charging: device.batteryCharging ?? false)
                }

                // Connection badge
                PillBadge(text: device.connectionType.rawValue, color: device.connectionType.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.brandAccent.opacity(0.1), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.brandAccent.opacity(0.2), lineWidth: 0.5)
            )
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

    let onOpenReadiness: () -> Void
    @State private var isPulsing = false
    @State private var depStatus: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.brandAccent.opacity(0.2), Color.brandAccent.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 104, height: 104)
                Image(systemName: "light.beacon.max")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.brandAccent)
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(isPulsing ? 1.04 : 1.0)
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

            Button {
                onOpenReadiness()
            } label: {
                Label("Run Readiness Check", systemImage: "checklist.checked")
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandAccent)

            VStack(alignment: .leading, spacing: 8) {
                depRow("pymobiledevice3", installed: depStatus["pymobiledevice3"] ?? false)
                depRow("libimobiledevice", installed: depStatus["ideviceinfo"] ?? false)
            }
            .elevatedCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            depStatus = await ReadinessService.dependencyStatus()
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(installed ? .secondary : .orange)
        }
        .frame(width: 280)
    }
}

#if canImport(PreviewsMacros)
#Preview {
    ContentView()
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
        .environmentObject(MessageViewModel())
}
#endif
