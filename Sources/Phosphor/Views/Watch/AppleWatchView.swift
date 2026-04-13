import SwiftUI

/// Browse Apple Watch data extracted from paired iPhone backup.
struct AppleWatchView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var watches: [AppleWatchExtractor.WatchInfo] = []
    @State private var watchApps: [AppleWatchExtractor.WatchApp] = []
    @State private var activitySummaries: [AppleWatchExtractor.WatchActivitySummary] = []
    @State private var activeTab: WatchTab = .overview
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum WatchTab: String, CaseIterable {
        case overview = "Overview"
        case apps = "Watch Apps"
        case activity = "Activity"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading Watch data...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "applewatch", title: "Watch Data Unavailable", subtitle: error)
            } else if watches.isEmpty {
                EmptyStateView(
                    icon: "applewatch",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Apple Watch Found",
                    subtitle: "Select a backup from a paired iPhone to view Apple Watch data."
                )
            } else {
                switch activeTab {
                case .overview: overviewView
                case .apps: appsView
                case .activity: activityView
                }
            }
        }
        .onAppear(perform: load)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Watch")
                    .font(.title2.weight(.semibold))
                Text(watches.isEmpty ? "No watch found" : "\(watches.count) paired watch(es)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Tab", selection: $activeTab) {
                ForEach(WatchTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button("Extract All...") { extractAll() }
                .buttonStyle(.bordered)
                .disabled(watches.isEmpty)
        }
        .padding(20)
    }

    // MARK: - Overview

    private var overviewView: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(watches) { watch in
                    watchCard(watch)
                }

                if !watchApps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Watch Apps")
                        Text("\(watchApps.count) apps with Watch extensions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if !activitySummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Recent Activity")
                        HStack(spacing: 24) {
                            if let latest = activitySummaries.first {
                                activityRing(
                                    value: latest.moveCalories,
                                    goal: latest.moveGoal,
                                    color: .red,
                                    label: "Move",
                                    unit: "kcal"
                                )
                                activityRing(
                                    value: latest.exerciseMinutes,
                                    goal: latest.exerciseGoal,
                                    color: .green,
                                    label: "Exercise",
                                    unit: "min"
                                )
                                activityRing(
                                    value: latest.standHours,
                                    goal: latest.standGoal,
                                    color: .cyan,
                                    label: "Stand",
                                    unit: "hrs"
                                )
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(24)
        }
    }

    private func watchCard(_ watch: AppleWatchExtractor.WatchInfo) -> some View {
        HStack(spacing: 20) {
            VStack {
                Image(systemName: "applewatch")
                    .font(.system(size: 56))
                    .foregroundStyle(.indigo)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 80)

            VStack(alignment: .leading, spacing: 6) {
                Text(watch.name)
                    .font(.title3.weight(.semibold))

                Text(watch.model)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if watch.osVersion != "Unknown" {
                        Label("watchOS \(watch.osVersion)", systemImage: "gear")
                    }
                    if !watch.serialNumber.isEmpty {
                        Label(watch.serialNumber, systemImage: "barcode")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if let paired = watch.pairedDate {
                    Text("Paired: \(paired.shortString)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(20)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func activityRing(value: Double, goal: Double, color: Color, label: String, unit: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(CGFloat(value / max(goal, 1)), 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text(String(format: "%.0f", value))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Apps

    private var appsView: some View {
        Group {
            if watchApps.isEmpty {
                EmptyStateView(
                    icon: "apps.iphone",
                    title: "No Watch Apps",
                    subtitle: "No WatchKit app extensions found in this backup."
                )
            } else {
                List(watchApps) { app in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.indigo.opacity(0.1))
                                .frame(width: 36, height: 36)
                            Image(systemName: "applewatch.radiowaves.left.and.right")
                                .font(.system(size: 16))
                                .foregroundStyle(.indigo)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(app.bundleId)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(app.fileCount) files")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(app.totalSize.formattedFileSize)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Activity

    private var activityView: some View {
        Group {
            if activitySummaries.isEmpty {
                EmptyStateView(
                    icon: "figure.run",
                    title: "No Activity Data",
                    subtitle: "Activity ring data from Apple Watch was not found in this backup."
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Activity History")
                            .font(.headline)
                        Spacer()
                        Text("\(activitySummaries.count) days")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()

                    List(activitySummaries) { summary in
                        HStack(spacing: 16) {
                            Text(summary.date.shortString)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)

                            // Move
                            HStack(spacing: 4) {
                                Circle().fill(.red).frame(width: 8, height: 8)
                                Text(String(format: "%.0f", summary.moveCalories))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                Text("/\(Int(summary.moveGoal))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 100, alignment: .leading)

                            // Exercise
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text(String(format: "%.0f min", summary.exerciseMinutes))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .frame(width: 80, alignment: .leading)

                            // Stand
                            HStack(spacing: 4) {
                                Circle().fill(.cyan).frame(width: 8, height: 8)
                                Text(String(format: "%.0f hrs", summary.standHours))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .frame(width: 80, alignment: .leading)

                            Spacer()

                            // Completion indicator
                            let completed = summary.moveCalories >= summary.moveGoal &&
                                           summary.exerciseMinutes >= summary.exerciseGoal &&
                                           summary.standHours >= summary.standGoal
                            if completed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        isLoading = true
        errorMessage = nil

        do {
            let extractor = try AppleWatchExtractor(backupPath: backup.path)
            watches = extractor.getPairedWatches()
            watchApps = extractor.getWatchApps()
            activitySummaries = extractor.getActivitySummaries()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func extractAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }

        do {
            let extractor = try AppleWatchExtractor(backupPath: backup.path)
            let dest = (url.path as NSString).appendingPathComponent("Watch-Data")
            let count = try extractor.extractWatchData(to: dest)
            if count > 0 { NSWorkspace.shared.open(URL(fileURLWithPath: dest)) }
        } catch {}
    }
}
