import Foundation
import SwiftUI
import AppKit

enum MessageDateFilter: String, CaseIterable, Identifiable {
    case all = "All Dates"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"
    case custom = "Custom Range"

    var id: String { rawValue }

    func range(customStart: Date, customEnd: Date) -> (start: Date?, end: Date?) {
        let calendar = Calendar.current
        switch self {
        case .all:
            return (nil, nil)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: Date()), nil)
        case .thisYear:
            return (calendar.date(from: calendar.dateComponents([.year], from: Date())), nil)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endBase = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endBase) ?? endBase
            return (start, end)
        }
    }

    var startDate: Date? { range(customStart: Date(), customEnd: Date()).start }
}


enum MessageBackupReadiness: Equatable {
    case unknown
    case ready
    case noMessagesDatabase
    case encryptedBackup
    case permissionDenied(String)
    case emptyDatabase
    case unsupportedSchema(String)
    case loadError(String)

    var title: String {
        switch self {
        case .unknown, .ready: return "No Messages Found"
        case .noMessagesDatabase: return "Messages Database Missing"
        case .encryptedBackup: return "Encrypted Backup"
        case .permissionDenied: return "Permission Needed"
        case .emptyDatabase: return "No Messages in Backup"
        case .unsupportedSchema: return "Unsupported Messages Database"
        case .loadError: return "Could Not Load Messages"
        }
    }

    var subtitle: String {
        switch self {
        case .unknown:
            return "Choose a backup to check for messages."
        case .ready:
            return "The messages database was found, but no visible conversations were available. The backup may only contain deleted, archived, or filtered conversations."
        case .noMessagesDatabase:
            return "This backup does not contain HomeDomain/Library/SMS/sms.db. Choose another backup or create a fresh local backup that includes Messages."
        case .encryptedBackup:
            return "This backup is encrypted, so Messages may be unavailable until the backup is unlocked or exported in a readable form. Choose an unencrypted/readable backup or unlock it first."
        case .permissionDenied(let detail):
            return "Phosphor cannot read the Messages database or backup folder. Grant Files and Folders access, move the backup to a readable location, or choose another backup.\(detail.isEmpty ? "" : " Detail: \(detail)")"
        case .emptyDatabase:
            return "The Messages database is readable, but it contains no message rows. This can happen with a partial backup or a device with no local Messages history."
        case .unsupportedSchema(let detail):
            return "The backup contains a Messages database, but its schema is not one Phosphor understands yet.\(detail.isEmpty ? "" : " Detail: \(detail)")"
        case .loadError(let detail):
            return "Phosphor found the backup but hit an error while reading Messages.\(detail.isEmpty ? "" : " Detail: \(detail)")"
        }
    }

    var icon: String {
        switch self {
        case .permissionDenied: return "lock.shield"
        case .encryptedBackup: return "lock.fill"
        case .unsupportedSchema: return "exclamationmark.triangle"
        case .loadError: return "xmark.octagon"
        default: return "message"
        }
    }
}

struct MessageExportResult: Identifiable {
    let id = UUID()
    let url: URL
    let summary: String
}

/// Drives message browsing and export UI.
@MainActor
final class MessageViewModel: ObservableObject {

    @Published var chats: [MessageChat] = []
    @Published var selectedChat: MessageChat?
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var searchQuery = ""
    @Published var searchResults: [Message] = []
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var backupReadiness: MessageBackupReadiness = .unknown
    @Published var backupReadinessMessage = ""
    @Published var isExporting = false
    @Published var exportProgressText = ""
    @Published var exportProgress: Double = 0
    @Published var exportResult: MessageExportResult?

    private var exporter: MessageExporter?
    private var backupPath: String?
    private var contactDirectory: ContactDirectory = .empty
    private var exportCancelled = false
    private var exportTask: Task<Void, Never>?
    private var exportOperationID: UUID?

    var loadedBackupPath: String? { backupPath }

    func clear() {
        exportTask?.cancel()
        exportTask = nil
        exportOperationID = nil
        exporter = nil
        backupPath = nil
        contactDirectory = .empty
        chats = []
        selectedChat = nil
        messages = []
        searchQuery = ""
        searchResults = []
        isLoading = false
        backupReadiness = .unknown
        backupReadinessMessage = ""
        isExporting = false
        exportProgressText = ""
        exportProgress = 0
        exportResult = nil
        exportCancelled = false
    }

    private func invalidateExportForBackupSwitch() {
        exportTask?.cancel()
        exportTask = nil
        exportOperationID = nil
        isExporting = false
        exportProgressText = ""
        exportProgress = 0
        exportCancelled = false
    }

    func loadChats(from backupPath: String) {
        if self.backupPath != backupPath {
            invalidateExportForBackupSwitch()
        }
        self.backupPath = backupPath
        contactDirectory = .empty
        backupReadiness = Self.readiness(for: backupPath)
        backupReadinessMessage = backupReadiness.subtitle
        selectedChat = nil
        messages = []
        searchResults = []
        isLoading = true

        guard backupReadiness == .ready else {
            exporter = nil
            chats = []
            isLoading = false
            return
        }

        // Best-effort contact directory: if the AddressBook database isn't in
        // the backup (encrypted backup, partial restore, etc.) we still want
        // to surface the conversations - just without name resolution.
        let directory: ContactDirectory
        if let extractor = try? ContactsExtractor(backupPath: backupPath),
           let contacts = try? extractor.getContacts() {
            directory = ContactDirectory(contacts: contacts)
        } else {
            directory = .empty
        }
        self.contactDirectory = directory

        do {
            let exporter = try MessageExporter(backupPath: backupPath, contacts: directory)
            self.exporter = exporter
            chats = try exporter.getChats()
        } catch {
            backupReadiness = Self.classifyLoadError(error)
            backupReadinessMessage = backupReadiness.subtitle
            alertMessage = "Could not load messages: \(error.localizedDescription)"
            showAlert = true
            chats = []
        }

        isLoading = false
    }

    func selectChat(_ chat: MessageChat) {
        selectedChat = chat
        guard let exporter else { return }

        do {
            messages = try exporter.getMessages(chatId: chat.id)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
            messages = []
        }
    }

    func search(_ query: String) {
        guard !query.isEmpty, let exporter else {
            searchResults = []
            return
        }
        do {
            searchResults = try exporter.searchMessages(query)
        } catch {
            searchResults = []
        }
    }

    func filteredMessages(searchText: String, dateFilter: MessageDateFilter, customStart: Date = Date(), customEnd: Date = Date()) -> [Message] {
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        return messages.filter { message in
            if let start = range.start, message.date < start { return false }
            if let end = range.end, message.date > end { return false }
            guard !searchText.isEmpty else { return true }
            return message.displayText.localizedCaseInsensitiveContains(searchText)
                || message.senderLabel.localizedCaseInsensitiveContains(searchText)
                || message.attachments.contains { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
    }

    func cancelExport() {
        exportCancelled = true
        exportTask?.cancel()
        exportProgressText = "Cancelling…"
    }

    func startExportChatPDFBundle(
        to parentDirectory: String,
        dateFilter: MessageDateFilter = .all,
        customStart: Date = Date(),
        customEnd: Date = Date(),
        visibleMessages: [Message]? = nil
    ) {
        guard let chat = selectedChat, let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: true)
        let sourceMessages = visibleMessages
        let fallbackMessages = messages
        let contactDirectory = self.contactDirectory
        isExporting = true
        exportCancelled = false
        exportProgress = 0.1
        exportProgressText = "Creating PDF bundle for \(chat.title)…"
        let exportID = UUID()
        exportOperationID = exportID

        exportTask = Task.detached(priority: .userInitiated) { [weak self, chat, sourceMessages, fallbackMessages, backupPath, contactDirectory, exportID] in
            do {
                let exporter = try MessageExporter(backupPath: backupPath, contacts: contactDirectory)
                let baseMessages: [Message]
                if let sourceMessages {
                    baseMessages = sourceMessages
                } else if fallbackMessages.isEmpty {
                    baseMessages = try exporter.getMessages(chatId: chat.id)
                } else {
                    baseMessages = fallbackMessages
                }
                let exportedMessageCount = options.apply(to: baseMessages).count
                try Task.checkCancellation()
                let result = try exporter.exportChatPDFBundle(
                    chat: chat,
                    messages: baseMessages,
                    to: parentDirectory,
                    options: options,
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.exportProgress = 1
                    self.exportResult = MessageExportResult(
                        url: result.directory,
                        summary: "Exported \(exportedMessageCount) messages as a PDF bundle with attachments"
                    )
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export cancelled"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export failed: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    func startExportChat(format: MessageExportFormat, to path: String, dateFilter: MessageDateFilter = .all, customStart: Date = Date(), customEnd: Date = Date(), includeAttachments: Bool = true, visibleMessages: [Message]? = nil) {
        guard let chat = selectedChat, let backupPath else { return }
        let normalisedPath = ensureExtension(path, for: format)
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: includeAttachments)
        let sourceMessages = visibleMessages
        let fallbackMessages = messages
        let contactDirectory = self.contactDirectory
        isExporting = true
        exportCancelled = false
        exportProgress = 0.1
        exportProgressText = "Exporting \(chat.title)…"
        let exportID = UUID()
        exportOperationID = exportID

        exportTask = Task.detached(priority: .userInitiated) { [weak self, chat, sourceMessages, fallbackMessages, backupPath, contactDirectory, exportID] in
            do {
                let exporter = try MessageExporter(backupPath: backupPath, contacts: contactDirectory)
                let baseMessages: [Message]
                if let sourceMessages {
                    baseMessages = sourceMessages
                } else if fallbackMessages.isEmpty {
                    baseMessages = try exporter.getMessages(chatId: chat.id)
                } else {
                    baseMessages = fallbackMessages
                }
                let filtered = options.apply(to: baseMessages)
                try Task.checkCancellation()
                try exporter.exportMessages(filtered, chatTitle: chat.title, format: format, to: normalisedPath, options: options) {
                    try Task.checkCancellation()
                }
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.exportProgress = 1
                    self.exportResult = MessageExportResult(url: URL(fileURLWithPath: normalisedPath), summary: "Exported \(filtered.count) messages")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export cancelled"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export failed: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
    }

    func startExportAllChats(format: MessageExportFormat, to directory: String, dateFilter: MessageDateFilter = .all, customStart: Date = Date(), customEnd: Date = Date(), includeAttachments: Bool = true) {
        guard let backupPath else { return }
        let range = dateFilter.range(customStart: customStart, customEnd: customEnd)
        let options = MessageExportOptions(startDate: range.start, endDate: range.end, includeAttachments: includeAttachments)
        let contactDirectory = self.contactDirectory
        isExporting = true
        exportCancelled = false
        exportProgress = 0
        exportProgressText = "Preparing export…"
        let exportID = UUID()
        exportOperationID = exportID

        exportTask = Task.detached(priority: .userInitiated) { [weak self, backupPath, contactDirectory, exportID] in
            do {
                let exporter = try MessageExporter(backupPath: backupPath, contacts: contactDirectory)
                let count = try exporter.exportAllChats(
                    format: format,
                    to: directory,
                    options: options,
                    onProgress: { completed, total, title in
                        try Task.checkCancellation()
                        let progress = total == 0 ? 0 : Double(completed) / Double(total)
                        Task { @MainActor [weak self] in
                            guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                            self.exportProgress = progress
                            self.exportProgressText = completed >= total ? "Export complete" : "Exporting \(completed + 1) of \(total): \(title)"
                        }
                    },
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.exportProgress = 1
                    self.exportResult = MessageExportResult(url: URL(fileURLWithPath: directory), summary: "Exported \(count) conversations")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export cancelled"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export failed: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
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
        let contactDirectory = self.contactDirectory
        isExporting = true
        exportCancelled = false
        exportProgress = 0
        exportProgressText = "Preparing complete export…"
        let exportID = UUID()
        exportOperationID = exportID

        exportTask = Task.detached(priority: .userInitiated) { [weak self, backupPath, contactDirectory, exportID] in
            do {
                let exporter = try MessageExporter(backupPath: backupPath, contacts: contactDirectory)
                let result = try exporter.exportAllChatsAllFormats(
                    to: parentDirectory,
                    options: options,
                    onProgress: { completed, total, title in
                        try Task.checkCancellation()
                        let progress = total == 0 ? 0 : Double(completed) / Double(total)
                        Task { @MainActor [weak self] in
                            guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                            self.exportProgress = progress
                            self.exportProgressText = completed >= total
                                ? "Export complete"
                                : "Exporting \(completed + 1) of \(total): \(title)"
                        }
                    },
                    cancellationCheck: {
                        try Task.checkCancellation()
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.exportProgress = 1
                    self.exportResult = MessageExportResult(
                        url: result.directory,
                        summary: "Exported \(result.count) conversations in all formats with attachments"
                    )
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export cancelled"
                    self.showAlert = true
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.exportOperationID == exportID, self.backupPath == backupPath else { return }
                    self.isExporting = false
                    self.exportOperationID = nil
                    self.alertMessage = "Export failed: \(error.localizedDescription)"
                    self.showAlert = true
                }
            }
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

    private static func readiness(for backupPath: String) -> MessageBackupReadiness {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: backupPath) else {
            return .permissionDenied("Backup folder is not readable.")
        }

        let isEncrypted = PlistParser.parseManifest(backupPath)?.isEncrypted ?? false
        if isEncrypted && !BackupUnlockStore.shared.isUnlocked(backupPath) {
            return .encryptedBackup
        }

        // An unlocked backup has to be probed through the manifest: the blob on
        // disk is ciphertext, so a direct SQLiteReader would report a corrupt
        // database rather than a readable one.
        // Keep the manifest alive for the whole probe: its scratch directory holds
        // the decrypted sms.db and is removed the moment the instance is released.
        var unlockedManifest: BackupManifest?
        let sms: String
        if isEncrypted {
            guard let manifest = try? BackupManifest(backupPath: backupPath),
                  let entry = manifest.entry(withFileID: MessageExporter.smsDbHash),
                  let path = try? manifest.readablePath(for: entry) else {
                return .noMessagesDatabase
            }
            unlockedManifest = manifest
            sms = path
        } else {
            sms = "\(backupPath)/3d/\(MessageExporter.smsDbHash)"
        }
        defer { withExtendedLifetime(unlockedManifest) {} }
        guard fm.fileExists(atPath: sms) else {
            return .noMessagesDatabase
        }
        guard fm.isReadableFile(atPath: sms) else {
            return .permissionDenied("sms.db exists but is not readable.")
        }

        do {
            let reader = try SQLiteReader(path: sms)
            let tables = Set(try reader.tableNames())
            let required = ["message", "chat", "chat_message_join"]
            let missing = required.filter { !tables.contains($0) }
            if !missing.isEmpty {
                return .unsupportedSchema("Missing table(s): \(missing.joined(separator: ", ")).")
            }
            let messageCount = try reader.rowCount(for: "message")
            if messageCount == 0 { return .emptyDatabase }
            return .ready
        } catch {
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("authorization") ||
                description.localizedCaseInsensitiveContains("permission") ||
                description.localizedCaseInsensitiveContains("unable to open") {
                return .permissionDenied(description)
            }
            if description.localizedCaseInsensitiveContains("no such table") ||
                description.localizedCaseInsensitiveContains("schema") {
                return .unsupportedSchema(description)
            }
            return .loadError(description)
        }
    }

    private static func classifyLoadError(_ error: Error) -> MessageBackupReadiness {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("sms.db not found") ||
            description.localizedCaseInsensitiveContains("file not found") {
            return .noMessagesDatabase
        }
        if description.localizedCaseInsensitiveContains("permission") ||
            description.localizedCaseInsensitiveContains("authorization") ||
            description.localizedCaseInsensitiveContains("unable to open") {
            return .permissionDenied(description)
        }
        if description.localizedCaseInsensitiveContains("no such table") ||
            description.localizedCaseInsensitiveContains("no such column") {
            return .unsupportedSchema(description)
        }
        return .loadError(description)
    }

    /// Ensure a path ends with the export format's expected extension. Replaces
    /// a mismatched extension (e.g. `.txt` from SwiftUI's plain-text fallback)
    /// instead of appending so the file lands with one extension.
    private func ensureExtension(_ path: String, for format: MessageExportFormat) -> String {
        let target = format.fileExtension.lowercased()
        let ns = path as NSString
        let current = ns.pathExtension.lowercased()
        if current == target { return path }
        let stem = ns.deletingPathExtension
        return "\(stem).\(format.fileExtension)"
    }

    var totalMessages: Int {
        chats.reduce(0) { $0 + $1.messageCount }
    }

    /// Resolve an attachment to its on-disk location inside the backup, so
    /// the bubble view can render images inline or open files via Finder.
    func resolveAttachmentDiskPath(for attachment: MessageAttachment) -> String? {
        guard let filename = attachment.filename, let exporter else { return nil }
        return exporter.resolveAttachmentDiskPath(filename: filename)
    }
}
