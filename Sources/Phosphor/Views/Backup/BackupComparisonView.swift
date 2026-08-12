import SwiftUI

struct BackupComparisonView: View {
    @EnvironmentObject private var backupVM: BackupViewModel
    @Environment(\.dismiss) private var dismiss

    let initiallySelected: BackupInfo?

    @State private var olderID = ""
    @State private var newerID = ""
    @State private var result: BackupComparisonResult?
    @State private var selectedKind: BackupChangeKind?
    @State private var query = ""
    @State private var isComparing = false
    @State private var errorMessage: String?
    @State private var comparisonOperationID: UUID?
    @State private var comparisonTask: Task<Void, Never>?
    @State private var unlockPreparationTask: Task<Void, Never>?
    @State private var unlockTask: Task<Void, Never>?
    @State private var pendingUnlock: BackupInfo?
    @State private var unlockPassword = ""
    @State private var rememberPassword = false
    @State private var isUnlocking = false
    @State private var unlockError: String?
    @State private var backupOperationActive = BackupOperationCoordinator.shared.hasActiveBackup

    private struct ComparisonFailure: Error, Sendable {
        let message: String
    }

    private var sortedBackups: [BackupInfo] {
        backupVM.backups.sorted {
            ($0.lastBackupDate ?? .distantPast) < ($1.lastBackupDate ?? .distantPast)
        }
    }

    private var datedBackups: [BackupInfo] {
        sortedBackups.filter { $0.lastBackupDate != nil }
    }

    private var newerBackup: BackupInfo? {
        sortedBackups.first { $0.path == newerID }
    }

    private var matchingBackups: [BackupInfo] {
        guard let newerBackup, let newerDate = newerBackup.lastBackupDate else { return [] }
        return datedBackups.filter {
            $0.udid == newerBackup.udid
                && $0.path != newerBackup.path
                && ($0.lastBackupDate ?? .distantFuture) < newerDate
        }
    }

    private var olderBackup: BackupInfo? {
        matchingBackups.first { $0.path == olderID }
    }

    private var visibleChanges: [BackupComparisonChange] {
        guard let result else { return [] }
        return result.changes.filter { change in
            if let selectedKind, change.kind != selectedKind { return false }
            guard !query.isEmpty else { return true }
            return change.relativePath.localizedCaseInsensitiveContains(query)
                || change.domain.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            selectors
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            backupOperationActive = BackupOperationCoordinator.shared.hasActiveBackup
            chooseDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .backupOperationStateDidChange)) { _ in
            backupOperationActive = BackupOperationCoordinator.shared.hasActiveBackup
        }
        .onChange(of: olderID) { _, _ in resetComparison() }
        .onChange(of: newerID) { _, _ in
            reconcileOlderSelection()
            resetComparison()
        }
        .sheet(item: $pendingUnlock) { backup in
            unlockSheet(for: backup)
        }
        .onDisappear {
            comparisonTask?.cancel()
            unlockPreparationTask?.cancel()
            unlockTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Compare Backups")
                    .font(.title2.weight(.semibold))
                Text("See files added, removed, or changed in manifest metadata between two snapshots of the same device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                backupPicker("Older snapshot", selection: $olderID, backups: matchingBackups)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                backupPicker("Newer snapshot", selection: $newerID, backups: datedBackups)
                Spacer()
                Button {
                    prepareComparison()
                } label: {
                    if isComparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(backupOperationActive || backupVM.isCreating || isComparing || olderBackup == nil || newerBackup == nil || olderID == newerID)
            }

            if matchingBackups.isEmpty {
                Label("Choose a newer snapshot with an earlier dated backup from the same device.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if backupOperationActive {
                Label("Wait for the active backup to finish before comparing snapshots.", systemImage: "externaldrive.badge.timemachine")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private func backupPicker(
        _ title: String,
        selection: Binding<String>,
        backups: [BackupInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text("Choose Backup").tag("")
                ForEach(backups) { backup in
                    Text("\(backup.deviceName) — \(backup.dateString)").tag(backup.path)
                }
            }
            .labelsHidden()
            .frame(minWidth: 230)
        }
    }

    private func unlockSheet(for backup: BackupInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock Encrypted Backup")
                        .font(.headline)
                    Text("\(backup.displayName) • \(backup.relativeDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Enter the local backup password to compare these snapshots. Phosphor derives the keys on this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Backup password", text: $unlockPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitUnlock)
                .disabled(isUnlocking)

            Toggle("Remember this password in my Keychain", isOn: $rememberPassword)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(isUnlocking)

            if let unlockError {
                Label(unlockError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isUnlocking {
                    ProgressView().controlSize(.small)
                    Text("Deriving keys…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancelUnlock() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: submitUnlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(unlockPassword.isEmpty || isUnlocking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            unlockPassword = ""
            rememberPassword = false
            unlockError = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            VStack(spacing: 0) {
                summary(result)
                Divider()
                HStack {
                    Picker("Change type", selection: $selectedKind) {
                        Text("All Changes").tag(BackupChangeKind?.none)
                        ForEach(BackupChangeKind.allCases, id: \.self) { kind in
                            Text(label(for: kind)).tag(Optional(kind))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                    Spacer()
                    TextField("Filter paths", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                .padding()

                if visibleChanges.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Changes" : "No Matching Changes",
                        systemImage: "checkmark.circle",
                        description: Text(query.isEmpty ? "These snapshots contain the same manifest metadata." : "Try a different path filter.")
                    )
                } else {
                    VStack(spacing: 0) {
                        List(visibleChanges) { change in
                            changeRow(change)
                        }
                        .listStyle(.inset)
                        if result.hasHiddenChanges {
                            Divider()
                            Text("Showing a bounded sample of \(result.changes.count.formatted()) changes. Summary counts include the complete comparison.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        } else if isComparing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Comparing manifest metadata…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Choose Two Backups",
                systemImage: "clock.arrow.2.circlepath",
                description: Text("Select an older and newer snapshot from the same device, then choose Compare.")
            )
        }
    }

    private func summary(_ result: BackupComparisonResult) -> some View {
        HStack(spacing: 12) {
            summaryCard("Added", count: result.addedCount, color: .green)
            summaryCard("Metadata Changed", count: result.modifiedCount, color: .orange)
            summaryCard("Removed", count: result.removedCount, color: .red)
            summaryCard("Unchanged", count: result.unchangedCount, color: .secondary)
        }
        .padding()
    }

    private func summaryCard(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted()).font(.title2.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func changeRow(_ change: BackupComparisonChange) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: change.kind))
                .foregroundStyle(color(for: change.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.fileName.isEmpty ? change.relativePath : change.fileName)
                    .font(.body.weight(.medium))
                Text("\(change.domain)/\(change.relativePath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if change.kind == .modified, change.sizeDelta != 0 {
                Text(change.sizeDelta > 0 ? "+\(change.sizeDelta.formattedFileSize)" : change.sizeDelta.formattedFileSize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(label(for: change.kind))
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: change.kind))
        }
        .padding(.vertical, 3)
    }

    private func icon(for kind: BackupChangeKind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .removed: return "minus.circle.fill"
        }
    }

    private func label(for kind: BackupChangeKind) -> String {
        switch kind {
        case .added: return "Added"
        case .modified: return "Metadata Changed"
        case .removed: return "Removed"
        }
    }

    private func color(for kind: BackupChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .orange
        case .removed: return .red
        }
    }

    private func chooseDefaults() {
        guard !datedBackups.isEmpty else { return }
        let selected = initiallySelected.flatMap { initial in
            datedBackups.first { $0.path == initial.path }
        } ?? datedBackups.last
        newerID = selected?.path ?? ""
        reconcileOlderSelection()
    }

    private func reconcileOlderSelection() {
        guard newerBackup != nil else {
            olderID = ""
            return
        }
        if matchingBackups.contains(where: { $0.path == olderID }) { return }
        olderID = matchingBackups.last?.path ?? ""
    }

    private func resetComparison() {
        comparisonTask?.cancel()
        unlockPreparationTask?.cancel()
        unlockTask?.cancel()
        comparisonTask = nil
        unlockPreparationTask = nil
        unlockTask = nil
        comparisonOperationID = nil
        pendingUnlock = nil
        isComparing = false
        isUnlocking = false
        result = nil
        errorMessage = nil
        unlockError = nil
    }

    private func lockedBackups(older: BackupInfo, newer: BackupInfo) -> [BackupInfo] {
        [older, newer].filter {
            $0.isEncrypted && !BackupUnlockStore.shared.isUnlocked($0.path)
        }
    }

    private func prepareComparison() {
        guard let olderBackup, let newerBackup else { return }
        guard !BackupOperationCoordinator.shared.hasActiveBackup else {
            backupOperationActive = true
            errorMessage = "Wait for the active backup to finish before comparing snapshots."
            return
        }
        comparisonTask?.cancel()
        unlockPreparationTask?.cancel()
        result = nil
        errorMessage = nil
        unlockError = nil

        let locked = lockedBackups(older: olderBackup, newer: newerBackup)
        guard !locked.isEmpty else {
            startComparison(older: olderBackup, newer: newerBackup)
            return
        }

        isComparing = true
        unlockPreparationTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> BackupInfo? in
                for backup in locked {
                    guard !Task.isCancelled else { return nil }
                    guard let password = BackupPasswordKeychain.password(for: backup.path) else {
                        return backup
                    }
                    do {
                        try BackupUnlockStore.shared.unlock(backupPath: backup.path, password: password)
                    } catch {
                        BackupPasswordKeychain.delete(backupPath: backup.path)
                        return backup
                    }
                }
                return nil
            }
            let stillLocked = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            unlockPreparationTask = nil
            isComparing = false
            if let stillLocked {
                pendingUnlock = stillLocked
            } else {
                startComparison(older: olderBackup, newer: newerBackup)
            }
        }
    }

    private func submitUnlock() {
        guard !unlockPassword.isEmpty,
              !isUnlocking,
              let olderBackup,
              let newerBackup else { return }
        let password = unlockPassword
        let remember = rememberPassword
        let locked = lockedBackups(older: olderBackup, newer: newerBackup)
        guard !locked.isEmpty else {
            pendingUnlock = nil
            startComparison(older: olderBackup, newer: newerBackup)
            return
        }

        isUnlocking = true
        unlockError = nil
        unlockTask?.cancel()
        unlockTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    for backup in locked {
                        try Task.checkCancellation()
                        try BackupUnlockStore.shared.unlock(backupPath: backup.path, password: password)
                    }
                    return Result<Void, ComparisonFailure>.success(())
                } catch {
                    return .failure(ComparisonFailure(message: error.localizedDescription))
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            unlockTask = nil
            isUnlocking = false
            switch outcome {
            case .success:
                if remember {
                    for backup in locked {
                        BackupPasswordKeychain.save(password: password, backupPath: backup.path)
                    }
                }
                pendingUnlock = nil
                startComparison(older: olderBackup, newer: newerBackup)
            case .failure(let failure):
                unlockError = failure.message
            }
        }
    }

    private func cancelUnlock() {
        unlockTask?.cancel()
        unlockTask = nil
        pendingUnlock = nil
        isUnlocking = false
        isComparing = false
        unlockError = nil
    }

    private func startComparison(older olderBackup: BackupInfo, newer newerBackup: BackupInfo) {
        comparisonTask?.cancel()
        let operationID = UUID()
        comparisonOperationID = operationID
        isComparing = true
        result = nil
        errorMessage = nil

        comparisonTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    return Result<BackupComparisonResult, ComparisonFailure>.success(
                        try BackupComparisonService.compare(older: olderBackup, newer: newerBackup)
                    )
                } catch {
                    return .failure(ComparisonFailure(message: error.localizedDescription))
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            guard comparisonOperationID == operationID else { return }
            comparisonTask = nil
            isComparing = false
            switch outcome {
            case .success(let comparison): result = comparison
            case .failure(let failure): errorMessage = failure.message
            }
        }
    }
}
