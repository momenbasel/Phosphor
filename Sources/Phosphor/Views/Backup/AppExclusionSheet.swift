import SwiftUI

/// View for selective app data exclusion before running iOS backups.
/// Can be presented as a standalone sheet or embedded inside BackupPreflightSheet.
struct AppExclusionView: View {
    let udid: String
    @Binding var configuration: DeviceBackupConfiguration
    var onDismiss: () -> Void

    @StateObject private var appManager = AppManager()

    // App List State
    @State private var apps: [AppBackupTarget] = []
    @State private var isLoading = true
    @State private var isCalculatingSizes = false
    @State private var sizeCalculationFailed = false
    @State private var sizeCalculationTimeout: TimeInterval = 180
    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var sizeTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var sortOption: SortOption = .sizeDescending
    @State private var statusFilter: StatusFilter = .all
    @State private var showAppleApps: Bool = false
    @State private var excludedBundleIds: Set<String> = []

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case included = "Included"
        case excluded = "Excluded"

        var id: String { rawValue }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest Total Size"
        case dynamicDescending = "Largest Data/Cache"
        case nameAscending = "Name (A-Z)"

        var id: String { rawValue }
    }

    var filteredApps: [AppBackupTarget] {
        var result = apps
        if !showAppleApps {
            result = result.filter { !$0.isSystemApp }
        }
        switch statusFilter {
        case .all:
            break
        case .included:
            result = result.filter { !excludedBundleIds.contains($0.id) }
        case .excluded:
            result = result.filter { excludedBundleIds.contains($0.id) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending:
            return result.sorted {
                let s0 = $0.effectiveTotalBytes
                let s1 = $1.effectiveTotalBytes
                if s0 != s1 { return s0 > s1 }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .dynamicDescending:
            return result.sorted {
                // Pin apps with unreported shared App Group data (e.g. WhatsApp) to top so they aren't buried
                let u0 = $0.isDynamicSizeUnreported
                let u1 = $1.isDynamicSizeUnreported
                if u0 != u1 { return u0 && !u1 }
                if u0 && u1 {
                    let s0 = $0.staticDiskBytes
                    let s1 = $1.staticDiskBytes
                    if s0 != s1 { return s0 > s1 }
                }
                let d0 = $0.effectiveDynamicBytes
                let d1 = $1.effectiveDynamicBytes
                if d0 != d1 { return d0 > d1 }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .nameAscending:
            return result.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    var visibleApps: [AppBackupTarget] {
        apps.filter { showAppleApps || !$0.isSystemApp }
    }

    var unreportedDataAppsCount: Int {
        visibleApps.filter(\.isDynamicSizeUnreported).count
    }

    var excludedUnreportedDataAppsCount: Int {
        apps.filter { excludedBundleIds.contains($0.id) && $0.isDynamicSizeUnreported }.count
    }

    var totalAppsBytes: Int64 {
        visibleApps.reduce(0) { $0 + $1.effectiveTotalBytes }
    }

    var totalDynamicBytes: Int64 {
        visibleApps.reduce(0) { $0 + $1.effectiveDynamicBytes }
    }

    var hasAnySizesResolved: Bool {
        apps.contains(where: \.isSizeResolved)
    }

    var totalExcludedBytes: Int64 {
        apps.filter { excludedBundleIds.contains($0.id) }
            .reduce(0) { $0 + $1.effectiveDynamicBytes }
    }

    var formattedTotalAppsSize: String {
        guard hasAnySizesResolved else { return "Calculating..." }
        let base = ByteCountFormatter.string(fromByteCount: totalAppsBytes, countStyle: .file)
        if unreportedDataAppsCount > 0 {
            return "\(base)+ (\(unreportedDataAppsCount) unreported data)"
        }
        return base
    }

    var formattedSavings: String {
        guard hasAnySizesResolved else { return "Calculating..." }
        let base = ByteCountFormatter.string(fromByteCount: totalExcludedBytes, countStyle: .file)
        if excludedUnreportedDataAppsCount > 0 {
            if totalExcludedBytes == 0 {
                return "+\(excludedUnreportedDataAppsCount) unreported data"
            }
            return "\(base)+"
        }
        return base
    }

    var excludedPercentageString: String? {
        guard hasAnySizesResolved, totalAppsBytes > 0, totalExcludedBytes > 0 else { return nil }
        let percentage = (Double(totalExcludedBytes) / Double(totalAppsBytes)) * 100.0
        let prefix = (unreportedDataAppsCount > 0 || excludedUnreportedDataAppsCount > 0) ? "≥" : ""
        if percentage < 0.1 {
            return "<0.1%"
        }
        return String(format: "%@%.1f%%", prefix, percentage)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    saveAndDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Options")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandAccent)

                Spacer()

                VStack(spacing: 2) {
                    Text("Profile Details & Custom Inclusions")
                        .font(.headline.weight(.semibold))
                    HStack(spacing: 6) {
                        Text("System passwords and Messages always included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !excludedBundleIds.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let percentSuffix = excludedPercentageString.map { " • \($0)" } ?? ""
                            Text("\(excludedBundleIds.count) excluded (\(formattedSavings)\(percentSuffix))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }

                Spacer()

                Button("Done") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            appsTabContent
        }
        .task {
            loadInitialData()
        }
        .onDisappear {
            timerTask?.cancel()
            sizeTask?.cancel()
        }
    }

    // MARK: - Tab 1: By Application

    private var appsTabContent: some View {
        VStack(spacing: 0) {
            // Controls: Filter, Search, Sort & Presets (2-Row macOS Layout)
            VStack(spacing: 8) {
                // Row 1: Status Filter Segmented Control & Bulk Actions
                HStack(spacing: 12) {
                    Picker("Show", selection: $statusFilter) {
                        Text("All (\(apps.filter { showAppleApps || !$0.isSystemApp }.count))").tag(StatusFilter.all)
                        Text("Included (\(apps.filter { (showAppleApps || !$0.isSystemApp) && !excludedBundleIds.contains($0.id) }.count))").tag(StatusFilter.included)
                        Text("Excluded (\(apps.filter { (showAppleApps || !$0.isSystemApp) && excludedBundleIds.contains($0.id) }.count))").tag(StatusFilter.excluded)
                    }
                    .pickerStyle(.segmented)

                    Spacer(minLength: 8)

                    Menu("Bulk Actions") {
                        Button("Exclude Apps > 5 GB") {
                            excludeAppsAbove(bytes: 5 * 1024 * 1024 * 1024)
                        }
                        Button("Exclude Apps > 2 GB") {
                            excludeAppsAbove(bytes: 2 * 1024 * 1024 * 1024)
                        }
                        Button("Exclude Apps > 1 GB") {
                            excludeAppsAbove(bytes: 1 * 1024 * 1024 * 1024)
                        }
                        Button("Exclude Apps > 500 MB") {
                            excludeAppsAbove(bytes: 500 * 1024 * 1024)
                        }
                        Button("Exclude Apps > 100 MB") {
                            excludeAppsAbove(bytes: 100 * 1024 * 1024)
                        }
                        Divider()
                        Button("Exclude All User Apps") {
                            let userApps = apps.filter { !$0.isSystemApp }
                            excludedBundleIds.formUnion(userApps.map(\.id))
                        }
                        Button("Exclude All Listed Apps") {
                            excludedBundleIds = Set(filteredApps.map(\.id))
                        }
                        Button("Include All Apps (Reset)") {
                            excludedBundleIds.removeAll()
                        }
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                }

                // Row 2: Search Bar, Apple Apps Toggle, Sort Dropdown & Size Status
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search apps or bundle ID...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    if isCalculatingSizes {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Sizes (\(elapsedSeconds)s / \(Int(sizeCalculationTimeout))s)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else if sizeCalculationFailed {
                        Button {
                            retrySizeCalculation()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry Sizes (\(Int(sizeCalculationTimeout))s)")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Toggle(isOn: $showAppleApps) {
                        Text("Apple Apps")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .help("Show pre-installed Apple stock applications")

                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Inspecting app storage footprints...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No applications found")
                        .font(.headline)
                    Text("Try clearing the search query.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps) { app in
                    AppRowView(
                        app: app,
                        isExcluded: excludedBundleIds.contains(app.id),
                        onToggle: { isExcluded in
                            if isExcluded {
                                excludedBundleIds.insert(app.id)
                            } else {
                                excludedBundleIds.remove(app.id)
                            }
                        }
                    )
                }
                .listStyle(.inset)

                // Footer Status Bar: Total Apps Size & Excluded Apps Size Summary
                Divider()
                HStack(spacing: 16) {
                    HStack(spacing: 5) {
                        Text("Total App Footprint:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(formattedTotalAppsSize)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 5) {
                        Text("Excluded:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if excludedBundleIds.isEmpty {
                            Text("None (0 B)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.secondary)
                        } else {
                            let percentSuffix = excludedPercentageString.map { " • \($0)" } ?? ""
                            Text("\(excludedBundleIds.count) apps (\(formattedSavings)\(percentSuffix))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.orange)
                        }
                    }

                    Spacer()

                    Text("\(visibleApps.count) apps listed")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
        }
    }

    private func loadInitialData() {
        excludedBundleIds = configuration.excludedBundleIds

        Task {
            // Phase 1: Fast initial load without waiting for size calculation
            let targets = await appManager.listInstalledAppsFast(udid: udid)
            await MainActor.run {
                self.apps = targets
                self.isLoading = false
            }

            // Phase 2: Compute storage footprints asynchronously in background
            startSizeCalculationTask()
        }
    }

    private func startSizeCalculationTask() {
        timerTask?.cancel()
        sizeTask?.cancel()

        isCalculatingSizes = true
        sizeCalculationFailed = false
        elapsedSeconds = 0

        // Live visible elapsed-time ticker
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await MainActor.run {
                    self.elapsedSeconds += 1
                }
            }
        }

        // Asynchronous size calculation task with adaptive timeout
        let timeout = sizeCalculationTimeout
        sizeTask = Task {
            let targetsWithSizes = await appManager.listInstalledAppsWithSizes(udid: udid, timeout: timeout)
            timerTask?.cancel()

            await MainActor.run {
                self.isCalculatingSizes = false
                let resolvedCount = targetsWithSizes.filter(\.isSizeResolved).count
                if targetsWithSizes.isEmpty || resolvedCount == 0 {
                    // Timed out or failed to resolve sizes
                    self.sizeCalculationFailed = true
                    // Adaptive backoff: increase timeout by 50% for next retry
                    self.sizeCalculationTimeout = min(600, max(self.sizeCalculationTimeout * 1.5, self.sizeCalculationTimeout + 60))
                } else {
                    self.sizeCalculationFailed = false
                    // Merge calculated sizes into existing apps preserving order and state
                    let sizeMap = Dictionary(uniqueKeysWithValues: targetsWithSizes.map { ($0.id, $0) })
                    self.apps = self.apps.map { current in
                        if let sized = sizeMap[current.id], sized.isSizeResolved {
                            var updated = current
                            updated.dynamicDiskBytesOptional = sized.dynamicDiskBytesOptional
                            updated.staticDiskBytesOptional = sized.staticDiskBytesOptional
                            return updated
                        }
                        return current
                    }
                }
            }
        }
    }

    private func retrySizeCalculation() {
        startSizeCalculationTask()
    }

    private func excludeAppsAbove(bytes: Int64) {
        for app in apps {
            if !showAppleApps && app.isSystemApp { continue }
            let totalBytes = app.effectiveTotalBytes
            if totalBytes >= bytes || app.effectiveDynamicBytes >= bytes {
                excludedBundleIds.insert(app.id)
            }
        }
    }

    private func saveAndDismiss() {
        configuration.excludedBundleIds = excludedBundleIds
        configuration.save(for: udid)
        onDismiss()
    }
}

/// Extracted row view for an application target in the backup inclusion/exclusion list.
struct AppRowView: View {
    let app: AppBackupTarget
    let isExcluded: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { !isExcluded },
                set: { isIncluded in onToggle(!isIncluded) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isExcluded ? .secondary : .primary)
                    if app.isSystemApp {
                        Text("Apple")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if isExcluded {
                        Text("Excluded from backup")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(app.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if app.isDynamicSizeUnreported {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text("Data size unknown")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(isExcluded ? Color.secondary : Color.orange)
                    .help("iOS does not report live container sizes for apps that store data in shared App Groups.")

                    Text("App binary: \(app.formattedStaticSize) • App Group")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(app.formattedDynamicSize)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isExcluded ? Color.secondary : (app.effectiveDynamicBytes > 1_000_000_000 ? Color.orange : Color.primary))
                    Text(app.effectiveTotalBytes > 0 ? "Total: \(app.formattedTotalSize)" : "Data & Cache")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

