import AppKit
import SwiftUI

struct UnifiedSearchView: View {
    @EnvironmentObject private var backupVM: BackupViewModel
    @EnvironmentObject private var viewModel: UnifiedSearchViewModel
    @State private var exportError: String?

    private var selectedBackupID: Binding<String> {
        Binding(
            get: { viewModel.selectedBackup?.id ?? "" },
            set: { id in
                let backup = backupVM.backups.first { $0.id == id }
                viewModel.chooseBackup(backup)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.selectedBackup == nil {
                ContentUnavailableView(
                    "No Backup Selected",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Choose Backup above to search Messages, WhatsApp, Notes, Contacts, calls, Safari, and files.")
                )
            } else {
                resultsContent
            }
        }
        .onAppear {
            if viewModel.selectedBackup == nil {
                viewModel.chooseBackup(backupVM.selectedBackup ?? backupVM.backups.first)
            }
        }
        .onChange(of: backupVM.backups.map(\.path)) { _, paths in
            if let selected = viewModel.selectedBackup, !paths.contains(selected.path) {
                viewModel.chooseBackup(nil)
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown export error")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                GradientIconTile(
                    systemName: "magnifyingglass.circle.fill",
                    color: .indigo,
                    size: 34,
                    iconSize: 17,
                    cornerRadius: 9
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unified Search").font(.title2.weight(.semibold))
                    Text("Search across one backup without changing its contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Choose Backup", selection: selectedBackupID) {
                    Text("Choose Backup").tag("")
                    ForEach(backupVM.backups) { backup in
                        Text("\(backup.deviceName) — \(backup.dateString)").tag(backup.id)
                    }
                }
                .frame(width: 280)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names, messages, URLs, notes, and file paths", text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .onSubmit { viewModel.search() }
                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                Menu {
                    ForEach(UnifiedSearchSource.allCases, id: \.self) { source in
                        Toggle(source.label, isOn: Binding(
                            get: { viewModel.enabledSources.contains(source) },
                            set: { enabled in
                                if enabled { viewModel.enabledSources.insert(source) }
                                else { viewModel.enabledSources.remove(source) }
                            }
                        ))
                    }
                } label: {
                    Label("Sources", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if viewModel.isSearching {
                    Button("Cancel") { viewModel.cancel() }
                } else {
                    Button("Search") { viewModel.search() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.selectedBackup == nil)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var resultsContent: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching selected backup…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            ContentUnavailableView(
                "Search Unavailable",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(error)
            )
        } else if viewModel.results.isEmpty {
            VStack(spacing: 0) {
                if !viewModel.sourceErrors.isEmpty {
                    sourceWarnings
                    Divider()
                }
                ContentUnavailableView(
                    viewModel.hasCompletedSearch ? "No Results" : "Search This Backup",
                    systemImage: "text.magnifyingglass",
                    description: Text(viewModel.hasCompletedSearch
                        ? "No matching results were returned by the sources that could be searched."
                        : "Enter at least two characters, choose the sources, and press Search.")
                )
            }
        } else {
            VStack(spacing: 0) {
                resultToolbar
                Divider()
                if !viewModel.sourceErrors.isEmpty {
                    sourceWarnings
                    Divider()
                }
                List(viewModel.results, selection: $viewModel.selectedResultIDs) { result in
                    resultRow(result).tag(result.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var resultToolbar: some View {
        HStack {
            Text("\(viewModel.results.count) results")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Select All") { viewModel.selectAllVisible() }
                .disabled(viewModel.selectedResultIDs.count == viewModel.results.count)
            Button("Clear Selection") { viewModel.clearSelection() }
                .disabled(viewModel.selectedResultIDs.isEmpty)
            Menu("Export Selected") {
                Button("CSV") { exportSelected(as: .csv) }
                Button("JSON") { exportSelected(as: .json) }
            }
            .disabled(viewModel.selectedResultIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var sourceWarnings: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(viewModel.sourceErrors
                .sorted { $0.key.label < $1.key.label }
                .map { "\($0.key.label): \($0.value)" }
                .joined(separator: "  •  "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
    }

    private func resultRow(_ result: UnifiedSearchResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.source.icon)
                .foregroundStyle(result.source.iconColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title.isEmpty ? "Untitled" : result.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(result.source.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(result.source.iconColor.opacity(0.12), in: Capsule())
                    Spacer()
                    if let date = result.date {
                        Text(date.shortString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !result.subtitle.isEmpty {
                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !result.snippet.isEmpty {
                    Text(result.snippet).font(.callout).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private enum ExportKind {
        case csv, json
        var fileExtension: String { self == .csv ? "csv" : "json" }
    }

    private func exportSelected(as kind: ExportKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Phosphor Search Results.\(kind.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .csv: try UnifiedSearchExporter.writeCSV(results: viewModel.selectedResults, to: url)
            case .json: try UnifiedSearchExporter.writeJSON(results: viewModel.selectedResults, to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private extension UnifiedSearchSource {
    var iconColor: Color {
        switch self {
        case .messages: return .blue
        case .whatsApp: return .green
        case .notes: return .yellow
        case .contacts: return .cyan
        case .callLog: return .orange
        case .safari: return .indigo
        case .files: return .gray
        }
    }
}
