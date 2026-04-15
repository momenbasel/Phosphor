import SwiftUI

/// App settings: backup location, dependencies check, about.
struct SettingsView: View {

    @AppStorage("phosphor.backupDirectory") private var backupDirectory = BackupManager.defaultBackupDir
    @State private var dependencyList: [DependencyItem] = []
    @AppStorage("phosphor.autoRefreshInterval") private var autoRefreshInterval: Double = 4.0

    @StateObject private var scheduler = BackupScheduler()

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            backupScheduleTab
                .tabItem {
                    Label("Backup Schedule", systemImage: "clock")
                }

            dependenciesTab
                .tabItem {
                    Label("Dependencies", systemImage: "shippingbox")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 460)
        .onAppear {
            let deps = Shell.checkDependencies()
            dependencyList = deps.map { DependencyItem(name: $0.key, installed: $0.value) }
                .sorted { $0.name < $1.name }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Backup Location") {
                HStack {
                    TextField("Backup directory", text: $backupDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            backupDirectory = url.path
                        }
                    }

                    Button("Reset") {
                        backupDirectory = BackupManager.defaultBackupDir
                    }
                }

                Text("Default: ~/Library/Application Support/MobileSync/Backup")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Device Polling") {
                HStack {
                    Text("Auto-refresh interval")
                    Slider(value: $autoRefreshInterval, in: 1...15, step: 1)
                    Text("\(Int(autoRefreshInterval))s")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 30)
                }
            }

            Section("iOS 17+ Developer Tools") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tunnel Service")
                            .font(.system(size: 13, weight: .medium))
                        Text("Required for screen capture, location, and process list")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if TunnelService.isRunning {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Running").font(.system(size: 12)).foregroundStyle(.green)
                        }
                    } else {
                        Button("Start") { TunnelService.start() }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                            .controlSize(.small)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start on boot")
                            .font(.system(size: 13))
                        Text("Install LaunchDaemon so tunnel starts automatically")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if TunnelService.isAutoStartInstalled {
                        Button("Remove") { TunnelService.removeAutoStart() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Install") { TunnelService.installAutoStart() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Backup Schedule

    private var backupScheduleTab: some View {
        Form {
            Section("Automatic Backups") {
                Toggle("Enable scheduled backups", isOn: $scheduler.schedule.enabled)

                if scheduler.schedule.enabled {
                    Picker("Frequency", selection: $scheduler.schedule.frequency) {
                        ForEach(BackupScheduler.Frequency.allCases, id: \.self) { freq in
                            Text(freq.rawValue).tag(freq)
                        }
                    }

                    HStack {
                        Text("Preferred time")
                        Spacer()
                        Picker("Hour", selection: $scheduler.schedule.preferredHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .frame(width: 100)
                    }

                    Toggle("Wi-Fi backup only", isOn: $scheduler.schedule.wifiOnly)
                    Toggle("Incremental backup (faster)", isOn: $scheduler.schedule.incrementalOnly)
                }
            }

            if scheduler.schedule.enabled {
                Section("Status") {
                    if let lastRun = scheduler.schedule.lastRunDate {
                        HStack {
                            Text("Last run")
                            Spacer()
                            Text(lastRun.shortString).foregroundStyle(.secondary)
                        }
                    }
                    if let nextRun = scheduler.schedule.nextRunDate {
                        HStack {
                            Text("Next run")
                            Spacer()
                            Text(nextRun.shortString).foregroundStyle(.secondary)
                        }
                    }
                    if let result = scheduler.schedule.lastResult {
                        HStack {
                            Text("Last result")
                            Spacer()
                            Text(result).foregroundStyle(result == "Completed" ? .green : .orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Dependencies

    private var dependenciesTab: some View {
        VStack(spacing: 0) {
            List {
                Section("Required Tools") {
                    ForEach(dependencyList) { dep in
                        DependencyRow(item: dep)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            VStack(alignment: .leading, spacing: 8) {
                Text("Install all required tools with Homebrew:")
                    .font(.system(size: 13))

                Text("brew install libimobiledevice ideviceinstaller ifuse")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)

                Button("Check Again") {
                    let deps = Shell.checkDependencies()
                    dependencyList = deps.map { DependencyItem(name: $0.key, installed: $0.value) }
                        .sorted { $0.name < $1.name }
                }
            }
            .padding()
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "light.beacon.max")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)

            Text("Phosphor")
                .font(.title.weight(.bold))

            Text("Version \(AppVersion.current) (\(AppVersion.build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Free and open-source iOS device manager for macOS.\nBattery diagnostics, screen capture, location tools, and more.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Divider()
                .frame(width: 200)

            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/momenbasel/Phosphor")!)
                Link("Report Issue", destination: URL(string: "https://github.com/momenbasel/Phosphor/issues")!)
                Link("License (MIT)", destination: URL(string: "https://github.com/momenbasel/Phosphor/blob/main/LICENSE")!)
            }
            .font(.system(size: 12))

            Text("Built with pymobiledevice3 and SwiftUI")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DependencyItem: Identifiable {
    let id: String
    let name: String
    let installed: Bool

    init(name: String, installed: Bool) {
        self.id = name
        self.name = name
        self.installed = installed
    }
}

struct DependencyRow: View {
    let item: DependencyItem

    var body: some View {
        HStack {
            Image(systemName: item.installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.installed ? .green : .red)

            Text(item.name)
                .font(.system(size: 13, design: .monospaced))

            Spacer()

            Text(item.installed ? "Installed" : "Missing")
                .font(.system(size: 12))
                .foregroundColor(item.installed ? .secondary : .red)
        }
    }
}
