import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Browse and export WhatsApp conversations from backup ChatStorage.sqlite.
struct WhatsAppView: View {
    @EnvironmentObject var backupVM: BackupViewModel
    @EnvironmentObject var whatsAppVM: WhatsAppViewModel

    @State private var chatSearchText = ""
    @State private var messageSearchText = ""
    @State private var dateFilter: MessageDateFilter = .all
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var includeAttachments = true

    var body: some View {
        HSplitView {
            chatListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            messagePane
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: backupVM.selectedBackup?.id) { _, _ in handleSelectedBackupChange() }
        .onChange(of: backupVM.backups.map(\.path)) { _, _ in reconcileLoadedBackup() }
        .onChange(of: whatsAppVM.selectedSource) { _, _ in
            chatSearchText = ""
            messageSearchText = ""
        }
        .alert("WhatsApp", isPresented: $whatsAppVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(whatsAppVM.alertMessage)
        }
        .alert(item: $whatsAppVM.exportResult) { result in
            Alert(
                title: Text("Export Complete"),
                message: Text(result.summary),
                primaryButton: .default(Text("Reveal in Finder")) { whatsAppVM.revealLastExport() },
                secondaryButton: .default(Text("Open")) { whatsAppVM.openLastExport() }
            )
        }
    }

    private var chatListPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GradientIconTile(
                    systemName: "bubble.left.and.text.bubble.right.fill",
                    color: Color(red: 0.12, green: 0.75, blue: 0.36),
                    size: 28,
                    iconSize: 14,
                    cornerRadius: 8
                )
                Text("WhatsApp").font(.headline)
                Spacer()
                if loadedBackupIsCurrent && !whatsAppVM.chats.isEmpty { exportAllMenu }
                if loadedBackupIsCurrent && !whatsAppVM.chats.isEmpty {
                    Text("\(whatsAppVM.totalMessages) messages")
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

            if whatsAppVM.availableSources.count > 1 {
                sourcePicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search conversations...", text: $chatSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            if whatsAppVM.isLoading {
                LoadingOverlay(message: "Loading WhatsApp data...")
            } else if let error = whatsAppVM.errorMessage, loadedBackupIsCurrent {
                EmptyStateView(
                    icon: "exclamationmark.bubble",
                    title: "WhatsApp Not Found",
                    subtitle: error,
                    action: chooseBackupFolder,
                    actionLabel: "Choose Different Backup"
                )
            } else if backupVM.selectedBackup == nil && backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "No Backup Available",
                    subtitle: "Create a backup first, or choose an existing backup folder. WhatsApp is read from local device backups.",
                    action: chooseBackupFolder,
                    actionLabel: "Choose Backup Folder"
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "No Backup Selected",
                    subtitle: "Choose a backup below, or use the latest one to browse and export WhatsApp conversations.",
                    action: useLatestBackup,
                    actionLabel: "Use Latest Backup"
                )
            } else if loadedBackupIsCurrent && whatsAppVM.chats.isEmpty {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "No WhatsApp Data",
                    subtitle: "WhatsApp data was not found in this backup.",
                    action: chooseBackupFolder,
                    actionLabel: "Choose Different Backup"
                )
            } else {
                List(filteredChats, selection: Binding<WhatsAppExporter.WAChat?>(
                    get: { whatsAppVM.selectedChat },
                    set: { if let chat = $0 { whatsAppVM.selectChat(chat) } }
                )) { chat in
                    waChatRow(chat).tag(chat)
                }
                .listStyle(.inset)
            }
        }
    }

    private var backupPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
            Menu {
                ForEach(backupVM.backups) { backup in
                    Button("\(backup.displayName) • iOS \(backup.iosVersion) • \(backup.relativeDate)\(backup.isEncrypted ? " • Encrypted" : "")") {
                        selectBackup(backup)
                    }
                }
                Divider()
                Button("Choose Backup Folder…", action: chooseBackupFolder)
            } label: {
                HStack {
                    Text(backupVM.selectedBackup.map {
                        "\($0.displayName) • iOS \($0.iosVersion) • \($0.relativeDate)\($0.isEncrypted ? " • Encrypted" : "")"
                    } ?? "Choose Backup")
                    .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
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

    private var sourcePicker: some View {
        Picker("WhatsApp", selection: Binding(
            get: { whatsAppVM.selectedSource ?? .personal },
            set: { whatsAppVM.selectSource($0) }
        )) {
            ForEach(whatsAppVM.availableSources) { source in
                Text(source.displayName).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("WhatsApp source")
    }

    private var exportAllMenu: some View {
        Menu("Export All") {
            ForEach(MessageExportFormat.allCases, id: \.self) { format in
                Button(format.rawValue) { exportAllConversations(format: format) }
            }
            Divider()
            Button("All Formats + Attachments") { exportAllConversationsAllFormats() }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11, weight: .medium))
    }

    private var filteredChats: [WhatsAppExporter.WAChat] {
        guard !chatSearchText.isEmpty else { return whatsAppVM.chats }
        return whatsAppVM.chats.filter {
            $0.displayName.localizedCaseInsensitiveContains(chatSearchText)
                || $0.contactJid.localizedCaseInsensitiveContains(chatSearchText)
        }
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
                Text(chat.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack {
                    Text("\(chat.messageCount) messages")
                    if let date = chat.lastMessageDate { Text(date.relativeString) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var displayedMessages: [WhatsAppExporter.WAMessage] {
        whatsAppVM.filteredMessages(
            searchText: messageSearchText,
            dateFilter: dateFilter,
            customStart: customStartDate,
            customEnd: customEndDate
        )
    }

    private var exportOptionsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search this conversation…", text: $messageSearchText)
                    .textFieldStyle(.plain)
                Picker("Date", selection: $dateFilter) {
                    ForEach(MessageDateFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Toggle("Export Attachments", isOn: $includeAttachments)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 16)

            if dateFilter == .custom {
                HStack(spacing: 8) {
                    Text("From").font(.system(size: 11)).foregroundStyle(.secondary)
                    DatePicker("Start", selection: $customStartDate, displayedComponents: [.date]).labelsHidden()
                    Text("to").font(.system(size: 11)).foregroundStyle(.secondary)
                    DatePicker("End", selection: $customEndDate, displayedComponents: [.date]).labelsHidden()
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            if !messageSearchText.isEmpty || dateFilter != .all {
                HStack {
                    Text("Showing \(displayedMessages.count) of \(whatsAppVM.messages.count) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Filters") {
                        messageSearchText = ""
                        dateFilter = .all
                    }
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.35))
    }

    private var messagePane: some View {
        VStack(spacing: 0) {
            if let chat = whatsAppVM.selectedChat, loadedBackupIsCurrent {
                HStack {
                    Text(chat.displayName).font(.headline)
                    Spacer()
                    Menu("Export") {
                        ForEach(MessageExportFormat.allCases, id: \.self) { format in
                            Button(format.rawValue) { exportSingleChat(format: format) }
                        }
                        Divider()
                        Menu("Export All Conversations As...") {
                            ForEach(MessageExportFormat.allCases, id: \.self) { format in
                                Button(format.rawValue) { exportAllConversations(format: format) }
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
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(displayedMessages) { msg in waMessageBubble(msg) }
                    }
                    .padding(16)
                }
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "Select a Conversation",
                    subtitle: loadedBackupIsCurrent && !whatsAppVM.chats.isEmpty
                        ? "Choose a WhatsApp conversation from the list, or export every conversation at once."
                        : "Choose a backup to load WhatsApp conversations.",
                    action: loadedBackupIsCurrent && !whatsAppVM.chats.isEmpty
                        ? { exportAllConversations(format: .html) }
                        : nil,
                    actionLabel: loadedBackupIsCurrent && !whatsAppVM.chats.isEmpty ? "Export All as HTML…" : nil
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
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(msg.isFromMe ? Color.green : Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(msg.formattedDate).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if !msg.isFromMe { Spacer(minLength: 60) }
        }
    }

    private var loadedBackupIsCurrent: Bool {
        guard let path = whatsAppVM.loadedBackupPath,
              backupVM.backups.contains(where: { $0.path == path }) else { return false }
        return backupVM.selectedBackup?.path == path
    }

    private func loadIfNeeded() {
        if backupVM.backups.isEmpty { backupVM.loadBackups() }
        if let selected = backupVM.selectedBackup {
            loadWhatsApp(from: selected)
        } else {
            useLatestBackup()
        }
    }

    private func useLatestBackup() {
        if let latest = backupVM.backups.first { selectBackup(latest) }
    }

    private func selectBackup(_ backup: BackupInfo) {
        guard backupVM.openBackupBrowser(backup) else { return }
        loadWhatsApp(from: backup)
    }

    private func loadWhatsApp(from backup: BackupInfo) {
        chatSearchText = ""
        messageSearchText = ""
        whatsAppVM.loadChats(from: backup.path)
        if let first = whatsAppVM.chats.first { whatsAppVM.selectChat(first) }
    }

    private func chooseBackupFolder() {
        let previousPaths = backupVM.backups.map(\.path)
        backupVM.openExistingBackupFolder()
        guard backupVM.backups.map(\.path) != previousPaths else { return }
        if let latest = backupVM.backups.first { selectBackup(latest) } else { whatsAppVM.clear() }
    }

    private func handleSelectedBackupChange() {
        if let backup = backupVM.selectedBackup, whatsAppVM.loadedBackupPath != backup.path {
            loadWhatsApp(from: backup)
        } else if backupVM.selectedBackup == nil {
            reconcileLoadedBackup()
        }
    }

    private func reconcileLoadedBackup() {
        guard let path = whatsAppVM.loadedBackupPath else { return }
        guard backupVM.backups.contains(where: { $0.path == path }) else {
            whatsAppVM.clear()
            return
        }
        if let selected = backupVM.selectedBackup, selected.path != path { loadWhatsApp(from: selected) }
    }

    private func exportSingleChat(format: MessageExportFormat) {
        guard loadedBackupIsCurrent, let chat = whatsAppVM.selectedChat else { return }
        if format == .pdf {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Create PDF Bundle"
            panel.message = "Choose where Phosphor should create a folder containing this WhatsApp PDF and its original attachments."
            if panel.runModal() == .OK, let url = panel.url {
                whatsAppVM.startExportChatPDFBundle(
                    to: url.path,
                    dateFilter: dateFilter,
                    customStart: customStartDate,
                    customEnd: customEndDate,
                    visibleMessages: displayedMessages
                )
            }
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export WhatsApp Conversation"
        panel.nameFieldStringValue = chat.exportFilename(format: format, includeChatID: false)
        if let type = format.whatsAppContentType { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            whatsAppVM.startExportChat(
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
        panel.message = "Choose a folder to export all WhatsApp conversations"
        if panel.runModal() == .OK, let url = panel.url {
            whatsAppVM.startExportAllChats(
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
        panel.message = "Choose where Phosphor should create a WhatsApp Export folder containing every conversation, all supported formats, and original attachments."
        if panel.runModal() == .OK, let url = panel.url {
            whatsAppVM.startExportAllChatsAllFormats(
                to: url.path,
                dateFilter: dateFilter,
                customStart: customStartDate,
                customEnd: customEndDate
            )
        }
    }
}

private extension MessageExportFormat {
    var whatsAppContentType: UTType? {
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
