import SwiftUI
import UniformTypeIdentifiers

/// iMessage/SMS conversation browser with export capabilities.
/// Reads from sms.db extracted from iOS backups.
struct MessageListView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var messageVM = MessageViewModel()
    @State private var showExportSheet = false
    @State private var exportFormat: MessageExportFormat = .html
    @State private var searchText = ""

    var body: some View {
        HSplitView {
            // Chat list (left pane)
            chatListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            // Message detail (right pane)
            messageDetailPane
        }
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Chat List

    private var chatListPane: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Messages")
                    .font(.headline)
                Spacer()
                if !messageVM.chats.isEmpty {
                    Text("\(messageVM.totalMessages) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            if messageVM.isLoading {
                LoadingOverlay(message: "Loading messages...")
            } else if backupVM.selectedBackup == nil && backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "message",
                    title: "No Backup Available",
                    subtitle: "Create a backup first from the Backups section. Messages are read from local device backups."
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "message",
                    title: "No Backup Selected",
                    subtitle: "Go to Backups, select a backup, then return here to browse messages.",
                    action: {
                        if let first = backupVM.backups.first {
                            backupVM.openBackupBrowser(first)
                            messageVM.loadChats(from: first.path)
                        }
                    },
                    actionLabel: backupVM.backups.isEmpty ? nil : "Use Latest Backup"
                )
            } else if messageVM.chats.isEmpty {
                EmptyStateView(
                    icon: "message",
                    title: "No Messages Found",
                    subtitle: "This backup doesn't contain messages, or it may be encrypted."
                )
            } else {
                List(filteredChats, selection: Binding<MessageChat?>(
                    get: { messageVM.selectedChat },
                    set: { if let c = $0 { messageVM.selectChat(c) } }
                )) { chat in
                    chatRow(chat)
                        .tag(chat)
                }
                .listStyle(.inset)
            }
        }
    }

    private var filteredChats: [MessageChat] {
        guard !searchText.isEmpty else { return messageVM.chats }
        return messageVM.chats.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.chatIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func chatRow(_ chat: MessageChat) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(chat.isGroupChat ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: chat.isGroupChat ? "person.3.fill" : "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(chat.isGroupChat ? .purple : .blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack {
                    Text("\(chat.messageCount) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let date = chat.lastMessageDate {
                        Text(date.relativeString)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Message Detail

    private var messageDetailPane: some View {
        VStack(spacing: 0) {
            if let chat = messageVM.selectedChat {
                // Chat header
                HStack {
                    Text(chat.title)
                        .font(.headline)
                    Spacer()

                    Menu("Export") {
                        ForEach(MessageExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) {
                                exportFormat = format
                                showExportSheet = true
                            }
                        }
                        Divider()
                        Button("Export All Conversations...") {
                            exportAllConversations()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(messageVM.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messageVM.messages.count) { _, _ in
                        if let last = messageVM.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "Select a Conversation",
                    subtitle: "Choose a conversation from the list to view messages."
                )
            }
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: TextFileDocument(text: ""),
            contentType: .plainText,
            defaultFilename: "\(messageVM.selectedChat?.title ?? "messages").\(exportFormat.fileExtension)"
        ) { result in
            if case .success(let url) = result {
                let _ = messageVM.exportChat(format: exportFormat, to: url.path)
            }
        }
    }

    // MARK: - Helpers

    private func loadIfNeeded() {
        if let backup = backupVM.selectedBackup {
            messageVM.loadChats(from: backup.path)
        }
    }

    private func exportAllConversations() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export all conversations"

        if panel.runModal() == .OK, let url = panel.url {
            let count = messageVM.exportAllChats(format: exportFormat, to: url.path)
            messageVM.alertMessage = "Exported \(count) conversations"
            messageVM.showAlert = true
        }
    }
}

/// Single message bubble, styled like iMessage.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if !message.isFromMe && !message.handleId.isEmpty {
                    Text(message.handleId)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Text(message.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isFromMe ? Color.blue : Color(.controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.formattedDate)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }
}

/// Minimal document wrapper for file export dialog.
struct TextFileDocument: FileDocument {
    static var readableContentTypes = [UTType.plainText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
