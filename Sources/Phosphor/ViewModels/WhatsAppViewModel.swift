import AppKit
import Foundation

@MainActor
final class WhatsAppViewModel: ObservableObject {
    @Published var chats: [WhatsAppExporter.WAChat] = []
    @Published var selectedChat: WhatsAppExporter.WAChat?
    @Published var messages: [WhatsAppExporter.WAMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var exportProgressText = ""
    @Published var exportProgress: Double = 0
    @Published var exportResult: MessageExportResult?
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var exporter: WhatsAppExporter?
    private var backupPath: String?
    private var exportTask: Task<Void, Never>?
    private var exportOperationID: UUID?

    var loadedBackupPath: String? { backupPath }
    var totalMessages: Int { chats.reduce(0) { $0 + $1.messageCount } }

    func clear() {
        exportTask?.cancel()
        exportTask = nil
        exportOperationID = nil
        exporter = nil
        backupPath = nil
        chats = []
        selectedChat = nil
        messages = []
        isLoading = false
        errorMessage = nil
        isExporting = false
        exportProgressText = ""
        exportProgress = 0
        exportResult = nil
    }

    func loadChats(from backupPath: String) {
        if self.backupPath != backupPath {
            exportTask?.cancel()
            exportOperationID = nil
            isExporting = false
        }
        self.backupPath = backupPath
        selectedChat = nil
        messages = []
        chats = []
        errorMessage = nil
        isLoading = true
        do {
            let exporter = try WhatsAppExporter(backupPath: backupPath)
            self.exporter = exporter
            chats = try exporter.getChats()
        } catch {
            exporter = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectChat(_ chat: WhatsAppExporter.WAChat) {
        selectedChat = chat
        do {
            messages = try exporter?.getMessages(chatId: chat.id) ?? []
        } catch {
            messages = []
            alertMessage = "Could not load conversation: \(error.localizedDescription)"
            showAlert = true
        }
    }

    func filteredMessages(
        searchText: String,
        dateFilter: MessageDateFilter,
        customStart: Date = Date(),
        customEnd: Date = Date()
    ) -> [WhatsAppExporter.WAMessage] {
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        return messages.filter { message in
            if let start = range.start, message.date < start { return false }
            if let end = range.end, message.date > end { return false }
            guard !searchText.isEmpty else { return true }
            return message.displayText.localizedCaseInsensitiveContains(searchText)
                || (message.senderJid?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (message.mediaLocalPath?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgressText = "Cancelling…"
    }

    func startExportChatPDFBundle(
        to parentDirectory: String,
        dateFilter: MessageDateFilter = .all,
        customStart: Date = Date(),
        customEnd: Date = Date(),
        visibleMessages: [WhatsAppExporter.WAMessage]? = nil
    ) {
        guard let chat = selectedChat, let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: true)
        let sourceMessages = visibleMessages ?? messages
        startExport(text: "Creating PDF bundle for \(chat.displayName)…", backupPath: backupPath) { exporter, _ in
            let result = try exporter.exportChatPDFBundle(
                chat: chat,
                messages: sourceMessages,
                to: parentDirectory,
                options: options,
                cancellationCheck: { try Task.checkCancellation() }
            )
            return MessageExportResult(
                url: result.directory,
                summary: "Exported \(sourceMessages.count) WhatsApp messages as a PDF bundle with attachments"
            )
        }
    }

    func startExportChat(
        format: MessageExportFormat,
        to path: String,
        dateFilter: MessageDateFilter = .all,
        customStart: Date = Date(),
        customEnd: Date = Date(),
        includeAttachments: Bool = true,
        visibleMessages: [WhatsAppExporter.WAMessage]? = nil
    ) {
        guard let chat = selectedChat, let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: includeAttachments)
        let sourceMessages = visibleMessages ?? messages
        let outputPath = ensureExtension(path, for: format)
        startExport(text: "Exporting \(chat.displayName)…", backupPath: backupPath) { exporter, _ in
            try exporter.exportMessages(
                sourceMessages,
                title: chat.displayName,
                format: format,
                to: outputPath,
                options: options,
                cancellationCheck: { try Task.checkCancellation() }
            )
            return MessageExportResult(
                url: URL(fileURLWithPath: outputPath),
                summary: "Exported \(sourceMessages.count) WhatsApp messages"
            )
        }
    }

    func startExportAllChats(
        format: MessageExportFormat,
        to directory: String,
        dateFilter: MessageDateFilter = .all,
        customStart: Date = Date(),
        customEnd: Date = Date(),
        includeAttachments: Bool = true
    ) {
        guard let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: includeAttachments)
        startExport(text: "Preparing WhatsApp export…", backupPath: backupPath) { exporter, progress in
            let result = try exporter.exportAllChats(
                format: format,
                to: directory,
                options: options,
                onProgress: progress,
                cancellationCheck: { try Task.checkCancellation() }
            )
            return MessageExportResult(
                url: result.directory,
                summary: "Exported \(result.count) WhatsApp conversations"
            )
        }
    }

    func startExportAllChatsAllFormats(
        to parentDirectory: String,
        dateFilter: MessageDateFilter = .all,
        customStart: Date = Date(),
        customEnd: Date = Date()
    ) {
        guard let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: true)
        startExport(text: "Preparing complete WhatsApp export…", backupPath: backupPath) { exporter, progress in
            let result = try exporter.exportAllChatsAllFormats(
                to: parentDirectory,
                options: options,
                onProgress: progress,
                cancellationCheck: { try Task.checkCancellation() }
            )
            return MessageExportResult(
                url: result.directory,
                summary: "Exported \(result.count) WhatsApp conversations in all formats with attachments"
            )
        }
    }

    func revealLastExport() {
        guard let url = exportResult?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLastExport() {
        guard let url = exportResult?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func startExport(
        text: String,
        backupPath: String,
        operation: @escaping (WhatsAppExporter, @escaping (Int, Int, String) throws -> Void) throws -> MessageExportResult
    ) {
        exportTask?.cancel()
        isExporting = true
        exportProgress = 0
        exportProgressText = text
        let operationID = UUID()
        exportOperationID = operationID

        exportTask = Task.detached(priority: .userInitiated) { [weak self, backupPath, operationID] in
            do {
                let exporter = try WhatsAppExporter(backupPath: backupPath)
                let result = try operation(exporter) { completed, total, title in
                    try Task.checkCancellation()
                    let progress = total == 0 ? 0 : Double(completed) / Double(total)
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.exportOperationID == operationID,
                              self.backupPath == backupPath else { return }
                        self.exportProgress = progress
                        self.exportProgressText = completed >= total
                            ? "Export complete"
                            : "Exporting \(completed + 1) of \(total): \(title)"
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.exportOperationID == operationID,
                          self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.exportProgress = 1
                    self.exportResult = result
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.exportOperationID == operationID,
                          self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export cancelled"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.exportOperationID == operationID,
                          self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export failed: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    private func ensureExtension(_ path: String, for format: MessageExportFormat) -> String {
        let nsPath = path as NSString
        if nsPath.pathExtension.lowercased() == format.fileExtension.lowercased() { return path }
        return "\(nsPath.deletingPathExtension).\(format.fileExtension)"
    }
}
