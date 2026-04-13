import SwiftUI

/// Browse and export call history from backup.
struct CallLogView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var calls: [CallLogEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filterType: CallLogEntry.CallType?
    @State private var searchText = ""
    @State private var stats: (total: Int, incoming: Int, outgoing: Int, missed: Int, totalDuration: TimeInterval)?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading call history...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "phone", title: "Call Log Unavailable", subtitle: error)
            } else if calls.isEmpty {
                EmptyStateView(
                    icon: "phone.arrow.up.right",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Calls Found",
                    subtitle: "Select a backup to browse call history."
                )
            } else {
                callList
            }
        }
        .onAppear(perform: load)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Call Log")
                    .font(.title2.weight(.semibold))
                if let stats {
                    Text("\(stats.total) calls - \(stats.incoming) in, \(stats.outgoing) out, \(stats.missed) missed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("Filter", selection: $filterType) {
                Text("All").tag(nil as CallLogEntry.CallType?)
                Text("Incoming").tag(CallLogEntry.CallType.incoming as CallLogEntry.CallType?)
                Text("Outgoing").tag(CallLogEntry.CallType.outgoing as CallLogEntry.CallType?)
                Text("Missed").tag(CallLogEntry.CallType.missed as CallLogEntry.CallType?)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)

            Button("Export CSV...") { exportCSV() }
                .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var callList: some View {
        List(filteredCalls) { call in
            HStack(spacing: 12) {
                Image(systemName: call.callType.sfSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(callColor(call.callType))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(call.address)
                        .font(.system(size: 13, weight: .medium))
                    Text(call.date.shortString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(call.callType.label)
                        .font(.system(size: 11))
                        .foregroundStyle(callColor(call.callType))
                    if call.duration > 0 {
                        Text(call.durationString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if let cc = call.countryCode {
                    Text(cc.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var filteredCalls: [CallLogEntry] {
        var result = calls
        if let filter = filterType {
            result = result.filter { $0.callType == filter }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.address.contains(searchText) }
        }
        return result
    }

    private func callColor(_ type: CallLogEntry.CallType) -> Color {
        switch type {
        case .incoming: return .green
        case .outgoing: return .blue
        case .missed: return .red
        case .blocked: return .gray
        }
    }

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        guard backup.hasManifest else {
            errorMessage = BackupInfo.incompleteBackupMessage
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let ext = try CallLogExtractor(backupPath: backup.path)
            calls = try ext.getCallLog()
            stats = try ext.getStats()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "call-history.csv"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        try? CallLogExtractor(backupPath: backup.path).exportCSV(to: url.path)
    }
}
