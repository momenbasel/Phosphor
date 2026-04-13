import SwiftUI

/// Root view. NavigationSplitView with sidebar for navigation and detail pane.
struct ContentView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel

    @State private var selectedSection: SidebarSection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Phosphor")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
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
        case .messages:
            MessageListView()
        case .photos:
            PhotoBrowserView()
        case .apps:
            AppManagerView()
        case .files:
            FileBrowserView()
        case .diagnostics:
            DiagnosticsView()
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

    var color: Color {
        if charging { return .green }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 3) {
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
            }
            Text("\(level)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
    }
}

/// Shown when no section is selected.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Welcome to Phosphor")
                .font(.title2.weight(.semibold))
            Text("Connect an iOS device or select a section from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
}
