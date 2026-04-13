import SwiftUI

/// Browse and export Apple Health data from backup.
struct HealthView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var dataTypes: [(type: String, count: Int)] = []
    @State private var workouts: [HealthExtractor.Workout] = []
    @State private var samples: [HealthExtractor.HealthSample] = []
    @State private var selectedType: String?
    @State private var activeTab: HealthTab = .types
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum HealthTab: String, CaseIterable {
        case types = "Data Types"
        case workouts = "Workouts"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading Health data...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "heart.fill", title: "Health Data Unavailable", subtitle: error)
            } else {
                switch activeTab {
                case .types: dataTypesView
                case .workouts: workoutsView
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: activeTab) { _, _ in load() }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health")
                    .font(.title2.weight(.semibold))
                Text("\(dataTypes.count) data types, \(workouts.count) workouts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Tab", selection: $activeTab) {
                ForEach(HealthTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button("Export All...") { exportAll() }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
        .padding(20)
    }

    // MARK: - Data Types

    private var dataTypesView: some View {
        HSplitView {
            List(dataTypes, id: \.type, selection: $selectedType) { dt in
                HStack {
                    Image(systemName: iconForType(dt.type))
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cleanTypeName(dt.type))
                            .font(.system(size: 13, weight: .medium))
                        Text(dt.type)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("\(dt.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(dt.type)
            }
            .listStyle(.inset)
            .frame(minWidth: 280, idealWidth: 340)
            .onChange(of: selectedType) { _, newValue in
                if let type = newValue { loadSamples(type) }
            }

            // Sample detail
            if samples.isEmpty {
                EmptyStateView(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Select a Data Type",
                    subtitle: "Choose a health data type to view samples."
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(cleanTypeName(selectedType ?? ""))
                            .font(.headline)
                        Spacer()
                        Text("\(samples.count) samples")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Export CSV...") {
                            guard let type = selectedType else { return }
                            exportType(type)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()

                    List(samples) { sample in
                        HStack {
                            Text(sample.formattedValue)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.red)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(sample.startDate.shortString)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                if !sample.sourceName.isEmpty {
                                    Text(sample.sourceName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Workouts

    private var workoutsView: some View {
        Group {
            if workouts.isEmpty {
                EmptyStateView(
                    icon: "figure.run",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Workouts",
                    subtitle: "Select a backup to view workout history."
                )
            } else {
                List(workouts) { workout in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "figure.run")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(workout.activityName)
                                .font(.system(size: 13, weight: .medium))
                            Text(workout.startDate.shortString)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(workout.durationString)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            HStack(spacing: 8) {
                                if let cal = workout.totalEnergyBurned, cal > 0 {
                                    Text(String(format: "%.0f kcal", cal))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                                if let dist = workout.totalDistance, dist > 0 {
                                    Text(dist > 1000 ? String(format: "%.1f km", dist/1000) : String(format: "%.0f m", dist))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }

                        if !workout.sourceName.isEmpty {
                            Text(workout.sourceName)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Helpers

    private func cleanTypeName(_ type: String) -> String {
        type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKDataType", with: "")
    }

    private func iconForType(_ type: String) -> String {
        if type.contains("HeartRate") { return "heart.fill" }
        if type.contains("Step") { return "figure.walk" }
        if type.contains("Distance") { return "location" }
        if type.contains("Energy") || type.contains("Calori") { return "flame" }
        if type.contains("Sleep") { return "bed.double.fill" }
        if type.contains("Weight") || type.contains("Mass") { return "scalemass" }
        if type.contains("Height") { return "ruler" }
        if type.contains("Blood") { return "drop.fill" }
        if type.contains("Oxygen") { return "lungs.fill" }
        if type.contains("Respiratory") { return "wind" }
        if type.contains("Audio") || type.contains("Noise") { return "ear" }
        return "heart.text.square"
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        isLoading = true
        errorMessage = nil
        do {
            let ext = try HealthExtractor(backupPath: backup.path)
            dataTypes = try ext.getAvailableDataTypes()
            workouts = try ext.getWorkouts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadSamples(_ type: String) {
        guard let backup = backupVM.selectedBackup else { return }
        do {
            let ext = try HealthExtractor(backupPath: backup.path)
            samples = try ext.getSamples(dataType: type)
        } catch {
            samples = []
        }
    }

    private func exportType(_ type: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(cleanTypeName(type)).csv"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? HealthExtractor(backupPath: backup.path).exportSamples(dataType: type, to: url.path)
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        let dest = (url.path as NSString).appendingPathComponent("Health-Export")
        let _ = try? HealthExtractor(backupPath: backup.path).exportAll(to: dest)
        NSWorkspace.shared.open(URL(fileURLWithPath: dest))
    }
}
