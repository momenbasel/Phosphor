import AppKit
import SwiftUI

struct ReadinessCenterView: View {
    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @State private var exportMessage: String?
    @State private var recoveryMessage: String?
    @State private var pendingRecovery: PendingReadinessRecovery?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if deviceVM.isCheckingReadiness {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.brandAccent)
                        Text("Running readiness checks…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .elevatedCard()
                }

                if let report = deviceVM.readinessReport {
                    summaryCard(report)

                    SectionBlock(title: "Tool Readiness", systemImage: "wrench.and.screwdriver.fill") {
                        readinessRows(report.items.filter { $0.title.contains("Tool") })
                    }

                    SectionBlock(title: "Backup Folder", systemImage: "externaldrive.fill") {
                        readinessRows(report.items.filter { $0.title.contains("Backup Folder") })
                    }

                    SectionBlock(title: "Backup Recovery", systemImage: "externaldrive.badge.exclamationmark") {
                        readinessRows(report.items.filter { $0.title.contains("Incomplete Backup") })
                    }

                    SectionBlock(title: "Device Visibility", systemImage: "iphone.gen3") {
                        readinessRows(report.items.filter { $0.title.contains("Device Visibility") })
                    }

                    SectionBlock(title: "Wi-Fi Backup", systemImage: "wifi") {
                        readinessRows(report.items.filter { $0.title.contains("Wi-Fi Backup") })
                    }

                    SectionBlock(title: "Safe Operations", systemImage: "checkmark.shield.fill") {
                        readinessRows(report.items.filter { $0.title.contains("Safe Operations") })
                    }

                    SectionBlock(title: "Diagnostic Report", systemImage: "doc.text.magnifyingglass") {
                        readinessRows(report.items.filter { $0.title.contains("Diagnostic Report") })
                        Button {
                            exportDiagnosticReport(report)
                        } label: {
                            Label("Export Diagnostic Report", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandAccent)
                    }

                    SectionBlock(title: "Next Steps", systemImage: "arrow.right.circle.fill") {
                        readinessRows(report.items.filter { $0.title.contains("Next Steps") })
                    }
                } else if !deviceVM.isCheckingReadiness {
                    ContentUnavailableView(
                        "Run a readiness check",
                        systemImage: "checklist.checked",
                        description: Text("Phosphor will check device tools, backup-folder access, Wi-Fi visibility, safe-operation guidance, and diagnostic export readiness.")
                    )
                    Button {
                        Task { await deviceVM.refreshReadiness() }
                    } label: {
                        Label("Run Readiness Check", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandAccent)
                }

                if let exportMessage {
                    Text(exportMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let recoveryMessage {
                    Text(recoveryMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color.groupedBackground)
        .navigationTitle("Readiness Center")
        .task {
            if deviceVM.readinessReport == nil {
                await deviceVM.refreshReadiness()
            }
        }
        .alert(item: $pendingRecovery) { recovery in
            Alert(
                title: Text("Move Incomplete Backup to Trash?"),
                message: Text(recovery.confirmationMessage),
                primaryButton: .destructive(Text("Move to Trash")) {
                    Task { await performRecovery(recovery.operation) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            GradientIconTile(systemName: "checklist.checked", color: .brandAccent, size: 56, iconSize: 26, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("Readiness Center")
                    .font(.largeTitle.weight(.bold))
                Text("One place to verify setup, device visibility, backup safety, and bug-report diagnostics before you move data.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await deviceVM.refreshReadiness() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(deviceVM.isCheckingReadiness)
        }
    }

    private func summaryCard(_ report: ReadinessReport) -> some View {
        HStack(spacing: 14) {
            Image(systemName: report.hasBlockers ? "xmark.octagon.fill" : (report.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                .font(.system(size: 28))
                .foregroundStyle(report.hasBlockers ? .red : (report.hasWarnings ? .orange : .green))
            VStack(alignment: .leading, spacing: 4) {
                Text(report.hasBlockers ? "Action needed" : (report.hasWarnings ? "Mostly ready" : "Ready"))
                    .font(.headline)
                Text(report.summary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard()
    }

    private func readinessRows(_ items: [ReadinessItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                ReadinessRow(item: item) { operation in
                    pendingRecovery = PendingReadinessRecovery(operation: operation)
                }
            }
        }
    }

    private func performRecovery(_ operation: ReadinessOperation) async {
        switch operation {
        case .deleteIncompleteBackupAndRunFull(let udid, let path):
            do {
                let recoveryRoot = (path as NSString).deletingLastPathComponent
                try BackupManager.deleteIncompleteBackup(for: udid, expectedPath: path, in: recoveryRoot)
                backupVM.loadBackups()
                await deviceVM.refreshReadiness()

                guard let device = deviceVM.devices.first(where: { $0.id == udid }) else {
                    recoveryMessage = "Moved incomplete backup to Trash. Reconnect and trust the device over USB, then run a full backup."
                    return
                }

                guard device.connectionType == .usb else {
                    recoveryMessage = "Moved incomplete backup to Trash. Open Backups to explicitly confirm the first full Wi-Fi backup, or connect over USB for the recommended first backup."
                    return
                }

                recoveryMessage = "Moved incomplete backup to Trash. Starting a fresh full USB backup…"
                await backupVM.createBackup(udid: udid, incremental: false, preferNetwork: false)
                await deviceVM.refreshReadiness()
            } catch {
                recoveryMessage = "Could not move incomplete backup to Trash: \(error.localizedDescription)"
            }
        }
    }

    private func exportDiagnosticReport(_ report: ReadinessReport) {
        let panel = NSSavePanel()
        panel.title = "Export Phosphor Diagnostic Report"
        panel.nameFieldStringValue = "phosphor-diagnostic-report.md"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.diagnosticMarkdown.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Diagnostic Report exported to \(url.path)."
        } catch {
            exportMessage = "Could not export Diagnostic Report: \(error.localizedDescription)"
        }
    }
}

private struct SectionBlock<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard()
    }
}

private struct ReadinessRow: View {
    let item: ReadinessItem
    let actionHandler: (ReadinessOperation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.headline)
                    StatusChip(text: item.status.rawValue, color: color)
                }
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let recoveryAction = item.recoveryAction {
                    Text(recoveryAction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let operation = item.operation {
                    Button {
                        actionHandler(operation)
                    } label: {
                        Label("Move Incomplete Backup to Trash", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
    }

    private var icon: String {
        switch item.status {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .ready: return .green
        case .warning: return .orange
        case .blocked: return .red
        case .info: return .blue
        }
    }
}

private struct PendingReadinessRecovery: Identifiable {
    let id = UUID()
    let operation: ReadinessOperation

    var confirmationMessage: String {
        switch operation {
        case .deleteIncompleteBackupAndRunFull(_, let path):
            return "This will move the incomplete backup folder to Trash, not permanently delete it:\n\n\(path)\n\nIf the matching device is connected over USB, Phosphor will start a fresh full backup afterward."
        }
    }
}

#if canImport(PreviewsMacros)
#Preview {
    ReadinessCenterView()
        .environmentObject(DeviceViewModel())
        .environmentObject(BackupViewModel())
}
#endif
