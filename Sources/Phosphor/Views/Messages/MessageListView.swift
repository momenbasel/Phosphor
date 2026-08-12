import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// iMessage/SMS conversation browser with export capabilities.
/// Reads from sms.db extracted from iOS backups.
struct MessageListView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @EnvironmentObject var messageVM: MessageViewModel
    @State private var showExportSheet = false
    @State private var exportFormat: MessageExportFormat = .html
    @State private var searchText = ""
    @State private var messageSearchText = ""
    @State private var dateFilter: MessageDateFilter = .all
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var includeAttachments = true

    var body: some View {
        HSplitView {
            // Chat list (left pane)
            chatListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            // Message detail (right pane)
            messageDetailPane
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: backupVM.selectedBackup?.id) { _, _ in
            handleSelectedBackupChange()
        }
        .onChange(of: backupVM.backups.map(\.path)) { _, _ in
            reconcileLoadedBackupWithAvailableBackups()
        }
        .alert("Messages", isPresented: $messageVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(messageVM.alertMessage)
        }
        .alert(item: $messageVM.exportResult) { result in
            Alert(
                title: Text("Export Complete"),
                message: Text(result.summary),
                primaryButton: .default(Text("Reveal in Finder")) { messageVM.revealLastExport() },
                secondaryButton: .default(Text("Open")) { messageVM.openLastExport() }
            )
        }
    }

    // MARK: - Chat List

    private var chatListPane: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                GradientIconTile(systemName: "message.fill", color: .green, size: 28, iconSize: 14, cornerRadius: 8)
                Text("Messages")
                    .font(.headline)
                Spacer()
                if loadedBackupIsCurrent && !messageVM.chats.isEmpty {
                    exportAllMenu
                }
                if loadedBackupIsCurrent && !messageVM.chats.isEmpty {
                    Text("\(messageVM.totalMessages) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !backupVM.backups.isEmpty {
                backupPicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

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
            } else if messageVM.loadedBackupPath != nil && loadedBackupIsCurrent && messageVM.chats.isEmpty && messageVM.backupReadiness != .unknown {
                EmptyStateView(
                    icon: messageVM.backupReadiness.icon,
                    title: messageVM.backupReadiness.title,
                    subtitle: messageVM.backupReadiness.subtitle,
                    action: chooseBackupFolder,
                    actionLabel: "Choose Different Backup"
                )
            } else if backupVM.selectedBackup == nil && backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "message",
                    title: "No Backup Available",
                    subtitle: "Create a backup first, or choose an existing backup folder. Messages are read from local device backups.",
                    action: chooseBackupFolder,
                    actionLabel: "Choose Backup Folder"
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "message",
                    title: "No Backup Selected",
                    subtitle: backupVM.backups.isEmpty
                        ? "Create a backup first, or choose an existing backup folder."
                        : "Choose a backup below, or use the latest one to browse and export messages.",
                    action: {
                        if let first = backupVM.backups.first {
                            selectBackup(first)
                        } else {
                            chooseBackupFolder()
                        }
                    },
                    actionLabel: backupVM.backups.isEmpty ? "Choose Backup Folder" : "Use Latest Backup"
                )
            } else if loadedBackupIsCurrent && messageVM.chats.isEmpty {
                EmptyStateView(
                    icon: messageVM.backupReadiness.icon,
                    title: messageVM.backupReadiness.title,
                    subtitle: messageVM.backupReadiness.subtitle,
                    action: chooseBackupFolder,
                    actionLabel: "Choose Different Backup"
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
            $0.chatIdentifier.localizedCaseInsensitiveContains(searchText) ||
            $0.participants.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }


    private var backupPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
            Menu {
                ForEach(backupVM.backups) { backup in
                    Button("\(backup.deviceIdentityLabel) • iOS \(backup.iosVersion) • \(backup.relativeDate)\(backup.isEncrypted ? " • Encrypted" : "")") {
                        selectBackup(backup)
                    }
                }
                Divider()
                Button("Choose Backup Folder…") {
                    chooseBackupFolder()
                }
            } label: {
                HStack {
                    Text(backupVM.selectedBackup.map { "\($0.deviceIdentityLabel) • iOS \($0.iosVersion) • \($0.relativeDate)\($0.isEncrypted ? " • Encrypted" : "")" } ?? "Choose Backup")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var exportAllMenu: some View {
        Menu("Export All") {
            ForEach(MessageExportFormat.allCases, id: \.self) { format in
                Button(format.rawValue) {
                    exportAllConversations(format: format)
                }
            }
            Divider()
            Button("All Formats + Attachments") {
                exportAllConversationsAllFormats()
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11, weight: .medium))
    }

    private func chatRow(_ chat: MessageChat) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(chat.isGroupChat ? Color.purple.opacity(0.15) : Color.brandAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: chat.isGroupChat ? "person.3.fill" : "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(chat.isGroupChat ? .purple : Color.brandAccent)
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


    private var displayedMessages: [Message] {
        messageVM.filteredMessages(
            searchText: messageSearchText,
            dateFilter: dateFilter,
            customStart: customStartDate,
            customEnd: customEndDate
        )
    }

    private var exportOptionsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search this conversation…", text: $messageSearchText)
                    .textFieldStyle(.plain)

                Picker("Date", selection: $dateFilter) {
                    ForEach(MessageDateFilter.allCases) { filter in
                        Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                Toggle("Export Attachments", isOn: $includeAttachments)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Copies original photos, videos, audio, and files into an attachments folder beside the transcript.")
            }
            .padding(.horizontal, 16)

            if dateFilter == .custom {
                HStack(spacing: 8) {
                    Text("From")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    DatePicker("Start", selection: $customStartDate, displayedComponents: [.date])
                        .labelsHidden()
                    Text("to")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    DatePicker("End", selection: $customEndDate, displayedComponents: [.date])
                        .labelsHidden()
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            if !messageSearchText.isEmpty || dateFilter != .all {
                HStack {
                    Text("Showing \(displayedMessages.count) of \(messageVM.messages.count) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Filters") {
                        messageSearchText = ""
                        dateFilter = .all
                        customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                        customEndDate = Date()
                    }
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.35))
    }


    // MARK: - Message Detail

    private var messageDetailPane: some View {
        VStack(spacing: 0) {
            if let chat = messageVM.selectedChat, loadedBackupIsCurrent {
                // Chat header
                HStack {
                    Text(chat.title)
                        .font(.headline)
                    Spacer()

                    Menu("Export") {
                        ForEach(MessageExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) {
                                exportSingleChat(format: format)
                            }
                        }
                        Divider()
                        Menu("Export All Conversations As...") {
                            ForEach(MessageExportFormat.allCases, id: \.self) { format in
                                Button(format.rawValue) {
                                    exportAllConversations(format: format)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                exportOptionsBar

                Divider()

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(displayedMessages) { message in
                                MessageBubble(
                                    message: message,
                                    attachmentResolver: { messageVM.resolveAttachmentDiskPath(for: $0) }
                                )
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
                    subtitle: loadedBackupIsCurrent && !messageVM.chats.isEmpty
                        ? "Choose a conversation from the list, or export every conversation at once."
                        : "Choose a backup to load messages.",
                    action: loadedBackupIsCurrent && !messageVM.chats.isEmpty ? {
                        exportAllConversations(format: .html)
                    } : nil,
                    actionLabel: loadedBackupIsCurrent && !messageVM.chats.isEmpty ? "Export All as HTML…" : nil
                )
            }
        }
    }

    // MARK: - Helpers

    private var loadedBackupIsCurrent: Bool {
        guard let loadedPath = messageVM.loadedBackupPath else { return false }
        guard backupVM.backups.contains(where: { $0.path == loadedPath }) else { return false }
        if let selected = backupVM.selectedBackup {
            return selected.path == loadedPath
        }
        // Some message-readable states (for example encrypted or unreadable backups)
        // intentionally do not leave BackupViewModel.selectedBackup set because the
        // manifest browser cannot open them. Keep their Messages readiness copy visible
        // as long as the loaded backup still exists in the picker list.
        return true
    }

    private func loadIfNeeded() {
        if backupVM.backups.isEmpty {
            backupVM.loadBackups()
        }

        if let backup = backupVM.selectedBackup {
            loadMessages(from: backup)
        } else if let latest = backupVM.backups.first {
            selectBackup(latest)
        }
    }

    private func selectBackup(_ backup: BackupInfo) {
        backupVM.openBackupBrowser(backup)
        loadMessages(from: backup)
    }

    private func chooseBackupFolder() {
        let previousPaths = backupVM.backups.map(\.path)
        backupVM.openExistingBackupFolder()

        // If the folder changed, prefer the newest backup in that folder so the
        // user can immediately export without visiting Backups first. If the
        // picker was cancelled, leave the current selection alone.
        guard backupVM.backups.map(\.path) != previousPaths else { return }
        if let latest = backupVM.backups.first {
            selectBackup(latest)
        } else {
            messageVM.clear()
        }
    }

    private func handleSelectedBackupChange() {
        if let backup = backupVM.selectedBackup {
            if messageVM.loadedBackupPath != backup.path {
                loadMessages(from: backup)
            }
        } else {
            reconcileLoadedBackupWithAvailableBackups()
        }
    }

    private func reconcileLoadedBackupWithAvailableBackups() {
        guard let loadedPath = messageVM.loadedBackupPath else { return }
        guard backupVM.backups.contains(where: { $0.path == loadedPath }) else {
            messageVM.clear()
            return
        }
        if let selected = backupVM.selectedBackup, selected.path != loadedPath {
            loadMessages(from: selected)
        }
    }

    private func loadMessages(from backup: BackupInfo) {
        searchText = ""
        messageSearchText = ""
        messageVM.loadChats(from: backup.path)
        if messageVM.selectedChat == nil, let firstChat = messageVM.chats.first {
            messageVM.selectChat(firstChat)
        }
    }

    /// Drive a native `NSSavePanel` so the file panel respects the format's
    /// extension (HTML/JSON/MBOX). SwiftUI's `.fileExporter` hard-codes a
    /// single `UTType` per modifier and was rewriting `.html` to `.txt`
    /// (issue #17).
    private func exportSingleChatPDFBundle() {
        guard loadedBackupIsCurrent else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Create PDF Bundle"
        panel.message = "Choose where Phosphor should create a folder containing this conversation PDF and its original attachments."

        if panel.runModal() == .OK, let url = panel.url {
            messageVM.startExportChatPDFBundle(
                to: url.path,
                dateFilter: dateFilter,
                customStart: customStartDate,
                customEnd: customEndDate,
                visibleMessages: displayedMessages
            )
        }
    }

    private func exportSingleChat(format: MessageExportFormat) {
        guard loadedBackupIsCurrent, let chat = messageVM.selectedChat else { return }
        if format == .pdf {
            exportSingleChatPDFBundle()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = chat.exportFilename(format: format, includeChatID: false)
        if let type = format.contentType { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            messageVM.startExportChat(
                format: format,
                to: url.path,
                dateFilter: dateFilter,
                customStart: customStartDate,
                customEnd: customEndDate,
                includeAttachments: includeAttachments,
                visibleMessages: displayedMessages
            )
        }
    }

    private func exportAllConversations(format: MessageExportFormat) {
        guard loadedBackupIsCurrent else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export all conversations"

        if panel.runModal() == .OK, let url = panel.url {
            messageVM.startExportAllChats(
                format: format,
                to: url.path,
                dateFilter: dateFilter,
                customStart: customStartDate,
                customEnd: customEndDate,
                includeAttachments: includeAttachments
            )
        }
    }

    private func exportAllConversationsAllFormats() {
        guard loadedBackupIsCurrent else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Create Export"
        panel.message = "Choose where Phosphor should create a Messages Export folder containing every conversation, all supported formats, and original attachments."

        if panel.runModal() == .OK, let url = panel.url {
            messageVM.startExportAllChatsAllFormats(
                to: url.path,
                dateFilter: dateFilter,
                customStart: customStartDate,
                customEnd: customEndDate
            )
        }
    }

}

private extension MessageExportFormat {
    var contentType: UTType? {
        switch self {
        case .csv: return .commaSeparatedText
        case .txt: return .plainText
        case .pdf: return .pdf
        case .html: return .html
        case .json: return .json
        case .mbox: return UTType(filenameExtension: "mbox") ?? .data
        }
    }
}

/// Single message bubble, styled like iMessage. Renders inline attachments
/// (images, video thumbnails, file links), rich-link previews, and tapback
/// reactions floating over the bubble corner.
struct MessageBubble: View {
    let message: Message
    let attachmentResolver: (MessageAttachment) -> String?

    var body: some View {
        HStack(alignment: .top) {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if !message.isFromMe && !message.senderLabel.isEmpty {
                    Text(message.senderLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                ZStack(alignment: message.isFromMe ? .topLeading : .topTrailing) {
                    bubbleContent
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isFromMe ? Color.brandAccent : Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if !message.reactions.isEmpty {
                        Text(reactionGlyph)
                            .font(.system(size: 14))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.windowBackgroundColor))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                            .help(reactionTooltip)
                            .offset(x: message.isFromMe ? -8 : 8, y: -10)
                    }
                }

                Text(message.formattedDate)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = message.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .textSelection(.enabled)
            }

            ForEach(message.attachments) { attachment in
                AttachmentView(
                    attachment: attachment,
                    diskPath: attachmentResolver(attachment),
                    isFromMe: message.isFromMe
                )
            }

            if let link = message.linkURL, !link.isEmpty {
                Link(destination: URL(string: link) ?? URL(string: "https://example.com")!) {
                    Text(link)
                        .font(.system(size: 12))
                        .underline()
                        .foregroundStyle(message.isFromMe ? .white : Color.brandAccent)
                }
            }

            if message.text?.isEmpty != false,
               message.attachments.isEmpty,
               message.linkURL == nil {
                Text(message.displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(message.isFromMe ? .white : .secondary)
                    .italic()
            }
        }
    }

    private var reactionGlyph: String {
        message.reactions.map { $0.type.emoji }.joined(separator: " ")
    }

    private var reactionTooltip: String {
        message.reactions
            .map { "\($0.sender) \($0.type.label.lowercased())" }
            .joined(separator: ", ")
    }
}

/// Renders a single attachment inline. Images load from the on-disk backup
/// blob via `NSImage`. Videos and other files fall back to an icon + filename
/// row that opens the file in the user's default app on click.
private struct AttachmentView: View {
    let attachment: MessageAttachment
    let diskPath: String?
    let isFromMe: Bool

    var body: some View {
        if attachment.isImage, let path = diskPath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture(count: 2) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
        } else {
            let icon: String = {
                if attachment.isVideo { return "play.rectangle.fill" }
                if attachment.isImage { return "photo" }
                return "doc"
            }()
            Button {
                if let path = diskPath {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(attachment.displayName)
                        .lineLimit(1)
                    if diskPath == nil {
                        Text("(missing)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isFromMe ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(isFromMe ? .white : .primary)
            }
            .buttonStyle(.plain)
            .disabled(diskPath == nil)
        }
    }
}
