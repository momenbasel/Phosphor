import SwiftUI

/// Lists all discovered iOS backups with metadata. Allows creating new backups and managing existing ones.
struct BackupListView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @State private var showDeleteConfirm = false
    @State private var backupToDelete: BackupInfo?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups")
                        .font(.title2.weight(.semibold))
                    Text("\(backupVM.backups.count) backups - \(backupVM.totalSize) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await backupVM.createBackup(udid: udid) }
                } label: {
                    Label("New Backup", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(deviceVM.selectedDevice == nil || backupVM.isCreating)

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(20)

            Divider()

            if backupVM.isCreating {
                backupProgressView
            }

            if backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "externaldrive",
                    title: "No Backups Found",
                    subtitle: "Back up your device to browse its contents, extract messages, photos, and app data.",
                    action: {
                        guard let udid = deviceVM.selectedDevice?.id else { return }
                        Task { await backupVM.createBackup(udid: udid) }
                    },
                    actionLabel: deviceVM.selectedDevice != nil ? "Create Backup" : nil
                )
            } else {
                List {
                    ForEach(backupVM.backups) { backup in
                        BackupRow(backup: backup) {
                            backupVM.openBackupBrowser(backup)
                        } onDelete: {
                            backupToDelete = backup
                            showDeleteConfirm = true
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete Backup?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let backup = backupToDelete {
                    backupVM.deleteBackup(backup)
                }
            }
        } message: {
            if let backup = backupToDelete {
                Text("This will permanently delete the backup of \(backup.deviceName) (\(backup.sizeString)). This cannot be undone.")
            }
        }
        .alert("Backup", isPresented: $backupVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(backupVM.alertMessage)
        }
        .onAppear { backupVM.loadBackups() }
    }

    private var backupProgressView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(backupVM.progressText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.indigo.opacity(0.06))
    }
}

struct BackupRow: View {
    let backup: BackupInfo
    let onBrowse: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.indigo.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: backup.productType.hasPrefix("iPad") ? "ipad" : "iphone")
                    .font(.system(size: 20))
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(backup.deviceName)
                        .font(.system(size: 14, weight: .medium))

                    if backup.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Encrypted backup")
                    }
                }

                HStack(spacing: 8) {
                    Text(backup.modelName)
                    Text("-")
                    Text("iOS \(backup.iosVersion)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(backup.dateString)
                    Text("(\(backup.relativeDate))")
                    Text("-")
                    Text(backup.sizeString)
                    if backup.appCount > 0 {
                        Text("-")
                        Text("\(backup.appCount) apps")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Browse") { onBrowse() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Menu {
                    Button("Browse Contents") { onBrowse() }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup.path)
                    }
                    Divider()
                    Button("Delete Backup", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 6)
    }
}
