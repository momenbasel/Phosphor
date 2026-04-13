import SwiftUI

/// Browse and export WhatsApp conversations from backup ChatStorage.sqlite.
struct WhatsAppView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var chats: [WhatsAppExporter.WAChat] = []
    @State private var selectedChat: WhatsAppExporter.WAChat?
    @State private var messages: [WhatsAppExporter.WAMessage] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var exporter: WhatsAppExporter? {
        guard let backup = backupVM.selectedBackup else { return nil }
        return try? WhatsAppExporter(backupPath: backup.path)
    }

    var body: some View {
        HSplitView {
            chatListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            messagePane
        }
        .onAppear(perform: loadChats)
    }

    // MARK: - Chat List

    private var chatListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WhatsApp")
                    .font(.headline)
                Spacer()
                if !chats.isEmpty {
                    Text("\(chats.count) chats")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading WhatsApp data...")
            } else if let error = errorMessage {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "WhatsApp Not Found",
                    subtitle: error
                )
            } else if chats.isEmpty {
                noBackupView
            } else {
                List(filteredChats, selection: $selectedChat) { chat in
                    waChatRow(chat).tag(chat)
                }
                .listStyle(.inset)
            }
        }
    }

    private var noBackupView: some View {
        EmptyStateView(
            icon: "bubble.left.and.text.bubble.right",
            title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No WhatsApp Data",
            subtitle: backupVM.selectedBackup == nil
                ? "Select a backup from the Backups section first."
                : "WhatsApp data was not found in this backup."
        )
    }

    private var filteredChats: [WhatsAppExporter.WAChat] {
        guard !searchText.isEmpty else { return chats }
        return chats.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func waChatRow(_ chat: WhatsAppExporter.WAChat) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(chat.isGroup ? Color.green.opacity(0.15) : Color.green.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack {
                    Text("\(chat.messageCount) messages")
                    if let date = chat.lastMessageDate {
                        Text(date.relativeString)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Messages

    private var messagePane: some View {
        VStack(spacing: 0) {
            if let chat = selectedChat {
                HStack {
                    Text(chat.displayName)
                        .font(.headline)
                    Spacer()
                    Menu("Export") {
                        ForEach(MessageExportFormat.allCases, id: \.self) { fmt in
                            Button(fmt.rawValue) { exportChat(chat, format: fmt) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(messages) { msg in
                            waMessageBubble(msg)
                        }
                    }
                    .padding(16)
                }
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "Select a Conversation",
                    subtitle: "Choose a WhatsApp conversation from the list."
                )
            }
        }
    }

    private func waMessageBubble(_ msg: WhatsAppExporter.WAMessage) -> some View {
        HStack {
            if msg.isFromMe { Spacer(minLength: 60) }
            VStack(alignment: msg.isFromMe ? .trailing : .leading, spacing: 2) {
                if !msg.isFromMe, let sender = msg.senderJid {
                    Text(sender.replacingOccurrences(of: "@s.whatsapp.net", with: ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                Text(msg.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(msg.isFromMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(msg.isFromMe ? Color.green : Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(msg.formattedDate)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if !msg.isFromMe { Spacer(minLength: 60) }
        }
    }

    // MARK: - Actions

    private func loadChats() {
        guard let backup = backupVM.selectedBackup else { return }
        isLoading = true
        errorMessage = nil

        do {
            let wa = try WhatsAppExporter(backupPath: backup.path)
            chats = try wa.getChats()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func exportChat(_ chat: WhatsAppExporter.WAChat, format: MessageExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(chat.displayName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exporter?.exportChat(chatId: chat.id, format: format, to: url.path)
    }

    // MARK: - Selection handler
    // onChange doesn't work well with optional bindings in older SwiftUI, handle via task
}

extension WhatsAppView {
    func onChatSelected(_ chat: WhatsAppExporter.WAChat) {
        guard let exp = exporter else { return }
        messages = (try? exp.getMessages(chatId: chat.id)) ?? []
    }
}
