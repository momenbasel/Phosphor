import Foundation
import SwiftUI

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

    private var exporter: MessageExporter?
    private var backupPath: String?

    func loadChats(from backupPath: String) {
        self.backupPath = backupPath
        isLoading = true

        do {
            exporter = try MessageExporter(backupPath: backupPath)
            chats = try exporter?.getChats() ?? []
        } catch {
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

    func exportChat(format: MessageExportFormat, to path: String) -> Bool {
        guard let chatId = selectedChat?.id, let exporter else { return false }
        do {
            try exporter.exportChat(chatId: chatId, format: format, to: path)
            return true
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            showAlert = true
            return false
        }
    }

    func exportAllChats(format: MessageExportFormat, to directory: String) -> Int {
        guard let exporter else { return 0 }
        do {
            return try exporter.exportAllChats(format: format, to: directory)
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            showAlert = true
            return 0
        }
    }

    var totalMessages: Int {
        chats.reduce(0) { $0 + $1.messageCount }
    }
}
