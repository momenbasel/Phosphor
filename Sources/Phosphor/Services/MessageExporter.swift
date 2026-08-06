import Foundation
import CommonCrypto

/// Extracts and exports iMessage/SMS conversations from iOS backup sms.db.
///
/// The sms.db is stored at HomeDomain/Library/SMS/sms.db in the backup.
/// Its SHA-1 hash in Manifest.db is the famous "3d0d7e5fb2ce288813306e4d4636395e047a3d28".
struct MessageExportOptions {
    var startDate: Date? = nil
    var endDate: Date? = nil
    var includeAttachments: Bool = true

    func apply(to messages: [Message]) -> [Message] {
        messages.filter { message in
            if let startDate, message.date < startDate { return false }
            if let endDate, message.date > endDate { return false }
            return true
        }
    }
}

final class MessageExporter {

    /// The well-known SHA-1 hash for sms.db in iOS backups.
    static let smsDbHash = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"

    private let db: SQLiteReader
    /// Backup root for attachment lookups - nil when initialised from a raw sms.db path.
    private let backupPath: String?
    private let contacts: ContactDirectory
    /// Columns present on `chat` for the connected database. Used to gate the
    /// is_archived / is_filtered / is_blackholed filters that only exist on
    /// recent iOS versions.
    private let chatColumns: Set<String>
    /// Columns present on `message`. Several hot paths need this to shape
    /// SELECT lists for older iOS schemas; cache it once instead of running
    /// PRAGMA table_info(message) for every chat load/search/export.
    private let messageColumns: Set<String>
    /// Cached `chat_handle_join` -> handle id lookup, keyed by chat ROWID.
    private lazy var participantsByChat: [Int: [String]] = {
        (try? loadParticipantsByChat()) ?? [:]
    }()
    /// Cache attachment filename -> backup disk path during an export session.
    /// HTML and mbox exports may resolve the same attachment filename multiple
    /// times while staging/copying/embedding; avoid repeated SHA-1 work and
    /// filesystem existence checks for large attachment-heavy conversations.
    private var attachmentDiskPathCache: [String: String] = [:]
    private var missingAttachmentDiskPaths: Set<String> = []
    /// Held for the exporter's lifetime when the backup is encrypted and unlocked.
    /// sms.db and every attachment resolve through it, and its scratch directory
    /// has to outlive the paths it hands out.
    private let unlockedManifest: BackupManifest?

    init(
        databasePath: String,
        backupPath: String? = nil,
        contacts: ContactDirectory = .empty,
        unlockedManifest: BackupManifest? = nil
    ) throws {
        // Take ownership of the caller's manifest when there is one. Its scratch
        // directory is removed on deinit, so the instance that produced
        // databasePath has to be the instance this exporter keeps alive.
        self.unlockedManifest = unlockedManifest ?? backupPath.flatMap(Self.unlockedManifest(for:))
        self.db = try SQLiteReader(path: databasePath)
        self.backupPath = backupPath
        self.contacts = contacts
        let cols = (try? db.columns(for: "chat")) ?? []
        self.chatColumns = Set(cols.map { $0.name })
        let messageCols = (try? db.columns(for: "message")) ?? []
        self.messageColumns = Set(messageCols.map { $0.name })
    }

    /// Open the manifest only when this backup is encrypted and already unlocked.
    /// An unencrypted backup keeps reading blobs straight off disk, which avoids
    /// paying for a manifest open on the common path.
    private static func unlockedManifest(for backupPath: String) -> BackupManifest? {
        guard BackupUnlockStore.shared.isUnlocked(backupPath) else { return nil }
        return try? BackupManifest(backupPath: backupPath)
    }

    /// Resolve a well-known backup hash to a readable path, decrypting if needed.
    private static func readablePath(
        forHash hash: String,
        backupPath: String,
        manifest: BackupManifest?
    ) -> String? {
        if let manifest,
           let entry = manifest.entry(withFileID: hash),
           let path = try? manifest.readablePath(for: entry) {
            return path
        }
        let direct = "\(backupPath)/\(String(hash.prefix(2)))/\(hash)"
        return FileManager.default.fileExists(atPath: direct) ? direct : nil
    }

    /// Initialize from a backup directory by locating the sms.db.
    convenience init(backupPath: String, contacts: ContactDirectory = .empty) throws {
        // The sms.db file is stored as its SHA-1 hash in a two-character prefixed subdirectory
        let manifest = Self.unlockedManifest(for: backupPath)
        guard let smsPath = Self.readablePath(
            forHash: Self.smsDbHash,
            backupPath: backupPath,
            manifest: manifest
        ) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "sms.db not found in backup. If the backup is encrypted, unlock it with its password first."])
        }

        try self.init(
            databasePath: smsPath,
            backupPath: backupPath,
            contacts: contacts,
            unlockedManifest: manifest
        )
    }

    // MARK: - Conversations

    /// Get all chat conversations.
    ///
    /// Empty / tombstoned chats (no messages) are hidden because iOS keeps
    /// deleted-conversation rows in sms.db that would otherwise flood the UI
    /// (issue #8). Archived, junk-filtered and blackholed chats are also hidden
    /// by default (issue #17, "deleted chats appearing") - the user can opt back
    /// in via `includeHidden`.
    func getChats(includeEmpty: Bool = false, includeHidden: Bool = false) throws -> [MessageChat] {
        let havingClause = includeEmpty ? "" : "HAVING msg_count > 0"
        var hiddenFilters: [String] = []
        if !includeHidden {
            if chatColumns.contains("is_archived") {
                hiddenFilters.append("COALESCE(c.is_archived, 0) = 0")
            }
            if chatColumns.contains("is_filtered") {
                hiddenFilters.append("COALESCE(c.is_filtered, 0) = 0")
            }
            if chatColumns.contains("is_blackholed") {
                hiddenFilters.append("COALESCE(c.is_blackholed, 0) = 0")
            }
        }
        let whereClause = hiddenFilters.isEmpty ? "" : "WHERE " + hiddenFilters.joined(separator: " AND ")

        // Count only *user-visible* messages - i.e. excluding reaction-only
        // rows (associated_message_type in 2000..3999). Older sms.db schemas
        // pre-date that column, so we only apply the filter when it exists.
        let reactionFilter = messageColumns.contains("associated_message_type")
            ? "AND COALESCE(m.associated_message_type, 0) NOT BETWEEN 2000 AND 3999"
            : ""

        let sql = """
            SELECT
                c.ROWID,
                c.chat_identifier,
                c.display_name,
                c.style,
                (
                    SELECT COUNT(*) FROM chat_message_join cmj
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE cmj.chat_id = c.ROWID
                    \(reactionFilter)
                ) as msg_count,
                (
                    SELECT MAX(m.date) FROM message m
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE cmj.chat_id = c.ROWID
                ) as last_date
            FROM chat c
            \(whereClause)
            GROUP BY c.ROWID
            \(havingClause)
            ORDER BY last_date DESC
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> MessageChat? in
            guard let rowId = row["ROWID"] as? Int,
                  let chatId = row["chat_identifier"] as? String else { return nil }

            let lastDate: Date?
            if let timestamp = row["last_date"] as? Int {
                lastDate = Message.dateFromAppleTimestamp(timestamp)
            } else {
                lastDate = nil
            }

            let displayName = (row["display_name"] as? String) ?? ""
            let style = (row["style"] as? Int) ?? 0
            let isGroup = style == 43
            let participants = participantsByChat[rowId] ?? []

            return MessageChat(
                id: rowId,
                chatIdentifier: chatId,
                displayName: displayName,
                participants: participants,
                resolvedTitle: resolvedChatTitle(
                    displayName: displayName,
                    chatIdentifier: chatId,
                    participants: participants,
                    isGroup: isGroup
                ),
                lastMessageDate: lastDate,
                messageCount: (row["msg_count"] as? Int) ?? 0,
                isGroupChat: isGroup
            )
        }
    }

    /// Get all messages in a specific chat, with tapback reactions folded onto
    /// the message they target.
    func getMessages(chatId: Int) throws -> [Message] {
        let sql = """
            SELECT \(messageSelectFields())
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            ORDER BY m.date ASC, m.ROWID ASC
        """

        let rows = try db.query(sql, params: [String(chatId)])
        let attachmentsByMessage = (try? attachmentsByMessage(chatId: chatId)) ?? [:]
        return foldRows(rows, attachmentsByMessage: attachmentsByMessage)
    }

    /// Get all messages (across all chats).
    func getAllMessages(limit: Int = 10000) throws -> [Message] {
        let sql = """
            SELECT \(messageSelectFields())
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        let attachmentsByMessage = (try? attachmentsByMessage(messageIds: messageIds(from: rows))) ?? [:]
        return foldRows(rows, attachmentsByMessage: attachmentsByMessage)
    }

    /// Search messages by text content.
    func searchMessages(_ query: String, limit: Int = 500) throws -> [Message] {
        let sql = """
            SELECT \(messageSelectFields())
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.text LIKE ?
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: ["%\(query)%"])
        let attachmentsByMessage = (try? attachmentsByMessage(messageIds: messageIds(from: rows))) ?? [:]
        return foldRows(rows, attachmentsByMessage: attachmentsByMessage)
    }

    private func messageIds(from rows: [[String: Any?]]) -> [Int] {
        rows.compactMap { $0["ROWID"] as? Int }
    }

    /// Optional message columns differ across iOS versions. Build a compatible
    /// SELECT list from the cached schema once per query without repeated PRAGMA
    /// calls on every chat/export operation.
    private func messageSelectFields() -> String {
        var fields: [String] = [
            "m.ROWID", "m.guid", "m.text", "m.date", "m.is_from_me",
            "m.service", "m.cache_has_attachments", "m.is_read",
            "COALESCE(h.id, '') as handle_id"
        ]
        if messageColumns.contains("attributedBody") {
            // Keep backup-controlled BLOBs out of the bulk result set. Rows that
            // need the fallback are loaded and decoded individually below.
            fields.append(MessageAttributedBodyDecoder.attributedBodyCandidateSQLProjection)
        }
        for opt in [
            "associated_message_type", "associated_message_guid", "balloon_bundle_id", "payload_data",
            "reply_to_guid", "thread_originator_guid", "thread_originator_part", "expressive_send_style_id",
            "associated_message_emoji"
        ] {
            if messageColumns.contains(opt) {
                fields.append("m.\(opt)")
            }
        }
        return fields.joined(separator: ", ")
    }

    // MARK: - Reaction / attachment folding

    /// Splits the raw row list into primary messages and reaction rows, then
    /// resolves the net reaction state per (sender, type) before attaching
    /// reactions and attachments back onto the messages a UI cares about.
    private func foldRows(_ rows: [[String: Any?]],
                          attachmentsByMessage: [Int: [MessageAttachment]]) -> [Message] {
        var primaryRows: [[String: Any?]] = []
        // Reaction events grouped by the *target* message guid, kept in chronological
        // order so the resolver below can apply add/remove correctly.
        var reactionEventsByTarget: [String: [(rowId: Int, handle: String, isFromMe: Bool, type: ReactionType, isAdd: Bool)]] = [:]

        for row in rows {
            let assocType = (row["associated_message_type"] as? Int) ?? 0
            if assocType >= 2000 && assocType < 4000 {
                guard let rid = row["ROWID"] as? Int,
                      let rawGuid = row["associated_message_guid"] as? String,
                      let type = ReactionType(associatedMessageType: assocType) else { continue }
                let target = Self.stripReactionGuidPrefix(rawGuid)
                let isAdd = assocType < 3000
                let isFromMe = (row["is_from_me"] as? Int) == 1
                let handle = (row["handle_id"] as? String) ?? ""
                reactionEventsByTarget[target, default: []].append((
                    rowId: rid, handle: handle, isFromMe: isFromMe, type: type, isAdd: isAdd
                ))
            } else {
                primaryRows.append(row)
            }
        }

        // Resolve net reactions per target.
        var reactionsByTarget: [String: [Reaction]] = [:]
        for (target, events) in reactionEventsByTarget {
            // Latest event per (handle, type) wins. The rows come back in
            // chronological order already (parent query ORDER BY m.date ASC)
            // but if not we re-sort defensively by ROWID.
            let sorted = events.sorted { $0.rowId < $1.rowId }
            var state: [String: (rowId: Int, isFromMe: Bool, sender: String, type: ReactionType, isAdd: Bool)] = [:]
            for ev in sorted {
                let key = "\(ev.handle)|\(ev.type.rawValue)"
                state[key] = (ev.rowId, ev.isFromMe, ev.handle, ev.type, ev.isAdd)
            }
            let active = state.values.filter { $0.isAdd }.map { entry in
                Reaction(
                    id: entry.rowId,
                    type: entry.type,
                    isFromMe: entry.isFromMe,
                    sender: entry.isFromMe ? "Me" : contacts.displayName(forHandle: entry.sender),
                    isAdd: true
                )
            }
            if !active.isEmpty {
                reactionsByTarget[target] = active.sorted { $0.id < $1.id }
            }
        }

        // Recovered fallback strings are retained in the returned Message array.
        // Bound their aggregate contribution per query just like each source BLOB.
        var remainingAttributedBodyTextBytes = 64 * 1024 * 1024
        return primaryRows.compactMap { row in
            let rowId = (row["ROWID"] ?? nil) as? Int
            let guid = (row["guid"] ?? nil) as? String
            let attachments = rowId.flatMap { attachmentsByMessage[$0] } ?? []
            let reactionList = guid.flatMap { reactionsByTarget[$0] } ?? []
            return parseMessage(
                row,
                attachments: attachments,
                reactions: reactionList,
                remainingAttributedBodyTextBytes: &remainingAttributedBodyTextBytes
            )
        }
    }

    /// Reaction rows store their target as `p:<part>/<guid>` (or sometimes
    /// `bp:<guid>` for backup payloads). Strip the prefix so we can match the
    /// canonical message GUID directly.
    private static func stripReactionGuidPrefix(_ raw: String) -> String {
        if let slash = raw.firstIndex(of: "/"),
           (raw.hasPrefix("p:") || raw.hasPrefix("bp:")) {
            return String(raw[raw.index(after: slash)...])
        }
        return raw
    }

    /// Load every attachment in a chat (or, if `chatId` is nil, across the
    /// whole database) keyed by message ROWID. Avoids the previous join-in-the-
    /// SELECT approach that multiplied message rows for multi-attachment posts.
    private func attachmentsByMessage(chatId: Int?) throws -> [Int: [MessageAttachment]] {
        let sql: String
        let params: [String]
        if let chatId {
            sql = """
                SELECT
                    maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type,
                    a.transfer_name, a.total_bytes
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
                WHERE cmj.chat_id = ?
            """
            params = [String(chatId)]
        } else {
            sql = """
                SELECT
                    maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type,
                    a.transfer_name, a.total_bytes
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            """
            params = []
        }

        return try parseAttachmentsByMessageRows(db.query(sql, params: params))
    }

    private func parseAttachmentsByMessageRows(_ rows: [[String: Any?]]) -> [Int: [MessageAttachment]] {
        var out: [Int: [MessageAttachment]] = [:]
        for row in rows {
            guard let msgId = row["message_id"] as? Int,
                  let aid = row["ROWID"] as? Int else { continue }
            let att = MessageAttachment(
                id: aid,
                guid: (row["guid"] as? String) ?? "",
                filename: row["filename"] as? String,
                mimeType: row["mime_type"] as? String,
                transferName: row["transfer_name"] as? String,
                totalBytes: (row["total_bytes"] as? Int) ?? 0
            )
            out[msgId, default: []].append(att)
        }
        return out
    }


    /// Load attachments only for the messages already returned by a limited
    /// query/search. The previous all-messages path loaded every attachment in
    /// sms.db even when the UI only asked for the latest 500/10,000 messages.
    private func attachmentsByMessage(messageIds: [Int]) throws -> [Int: [MessageAttachment]] {
        guard !messageIds.isEmpty else { return [:] }
        var out: [Int: [MessageAttachment]] = [:]
        for chunkStart in stride(from: 0, to: messageIds.count, by: 500) {
            let chunk = Array(messageIds[chunkStart..<min(chunkStart + 500, messageIds.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT
                    maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type,
                    a.transfer_name, a.total_bytes
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                WHERE maj.message_id IN (\(placeholders))
            """
            let partial = try parseAttachmentsByMessageRows(
                db.query(sql, params: chunk.map(String.init))
            )
            for (messageId, attachments) in partial {
                out[messageId, default: []].append(contentsOf: attachments)
            }
        }
        return out
    }

    /// Resolve an attachment row's `filename` (e.g. `~/Library/SMS/Attachments/...`)
    /// to the SHA-1 hashed file on disk inside the backup. Returns nil when no backup
    /// path is known or the file does not exist.
    func resolveAttachmentDiskPath(filename: String) -> String? {
        guard let backupPath else { return nil }
        if let cached = attachmentDiskPathCache[filename] { return cached }
        if missingAttachmentDiskPaths.contains(filename) { return nil }

        // sms.db stores attachment filenames as device-absolute paths beginning
        // with `~/Library/SMS/Attachments/...`. The backup keeps them under the
        // MediaDomain with relativePath stripped of the leading tilde.
        var relative = filename
        if relative.hasPrefix("~/") { relative.removeFirst(2) }
        if relative.hasPrefix("/var/mobile/") { relative.removeFirst("/var/mobile/".count) }
        if relative.hasPrefix("/private/var/mobile/") { relative.removeFirst("/private/var/mobile/".count) }

        // SHA-1 of "MediaDomain-<relative>" is the on-disk filename.
        let domainKey = "MediaDomain-\(relative)"
        let hash = MessageExporter.sha1Hex(domainKey)
        if let candidate = MessageExporter.readablePath(
            forHash: hash,
            backupPath: backupPath,
            manifest: unlockedManifest
        ) {
            attachmentDiskPathCache[filename] = candidate
            return candidate
        }
        missingAttachmentDiskPaths.insert(filename)
        return nil
    }

    /// SHA-1 implementation used to derive backup filenames. Uses CommonCrypto.
    private static func sha1Hex(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(20))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Chat participants

    private func loadParticipantsByChat() throws -> [Int: [String]] {
        let sql = """
            SELECT chj.chat_id, h.id as handle_id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
        """
        let rows = try db.query(sql)
        var out: [Int: [String]] = [:]
        for row in rows {
            guard let chatId = row["chat_id"] as? Int,
                  let handle = row["handle_id"] as? String,
                  !handle.isEmpty else { continue }
            out[chatId, default: []].append(handle)
        }
        return out
    }

    private func resolvedChatTitle(displayName: String,
                                   chatIdentifier: String,
                                   participants: [String],
                                   isGroup: Bool) -> String {
        if !displayName.isEmpty { return displayName }

        if !participants.isEmpty {
            let title = contacts.groupTitle(participants: participants)
            if !title.isEmpty { return title }
            // No contact matches - fall back to raw handles but at least list
            // them rather than showing the chat<digits> identifier.
            return participants.joined(separator: ", ")
        }

        // Single-handle chats: try resolving the chat identifier itself, which
        // for 1:1 chats is the phone or email of the remote side.
        if !isGroup, let name = contacts.name(forHandle: chatIdentifier) {
            return name
        }

        return chatIdentifier
    }

    // MARK: - Export

    /// Export messages to a file in the specified format.
    func exportChat(
        chatId: Int,
        format: MessageExportFormat,
        to path: String,
        options: MessageExportOptions = MessageExportOptions(),
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        try cancellationCheck?()
        let messages = options.apply(to: try getMessages(chatId: chatId))
        let chats = try getChats(includeEmpty: true, includeHidden: true)
        let chat = chats.first { $0.id == chatId }
        let chatTitle = chat?.title ?? "Unknown"
        try exportMessages(messages, chatTitle: chatTitle, format: format, to: path, options: options, cancellationCheck: cancellationCheck)
    }

    /// Export all conversations.
    func exportAllChats(
        format: MessageExportFormat,
        to directory: String,
        options: MessageExportOptions = MessageExportOptions(),
        onProgress: ((Int, Int, String) throws -> Void)? = nil,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> Int {
        let chats = try getChats()
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var count = 0
        for chat in chats {
            try cancellationCheck?()
            try onProgress?(count, chats.count, chat.title)
            let filename = exportFilename(for: chat, format: format)
            let path = (directory as NSString).appendingPathComponent(filename)
            try exportChat(chatId: chat.id, format: format, to: path, options: options, cancellationCheck: cancellationCheck)
            count += 1
        }
        try onProgress?(count, chats.count, "Complete")
        return count
    }

    func exportMessages(
        _ messages: [Message],
        chatTitle: String,
        format: MessageExportFormat,
        to path: String,
        options: MessageExportOptions = MessageExportOptions(),
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        switch format {
        case .csv:
            try exportCSV(messages: messages, chatTitle: chatTitle, to: path, cancellationCheck: cancellationCheck)
        case .txt:
            try exportPlainText(messages: messages, chatTitle: chatTitle, to: path, cancellationCheck: cancellationCheck)
        case .pdf:
            try exportPDF(messages: messages, chatTitle: chatTitle, to: path, includeAttachments: options.includeAttachments, cancellationCheck: cancellationCheck)
        case .html:
            try exportHTML(messages: messages, chatTitle: chatTitle, to: path, includeAttachments: options.includeAttachments, cancellationCheck: cancellationCheck)
        case .json:
            try exportJSON(messages: messages, chatTitle: chatTitle, to: path, cancellationCheck: cancellationCheck)
        case .mbox:
            try exportMbox(messages: messages, chatTitle: chatTitle, to: path, includeAttachments: options.includeAttachments, cancellationCheck: cancellationCheck)
        }
    }

    // MARK: - Private Export Implementations

    private func exportFilename(for chat: MessageChat, format: MessageExportFormat) -> String {
        let safeName = chat.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(50)
        return "\(safeName)-chat-\(chat.id).\(format.fileExtension)"
    }

    private func exportCSV(messages: [Message], chatTitle: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        func append(_ chunk: String) throws {
            if let data = chunk.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }

        try append("Date,Sender,Text,Reactions,Service\n")
        for msg in messages {
            try cancellationCheck?()
            let reactions = msg.reactions
                .map { "\($0.sender): \($0.type.label)" }
                .joined(separator: "; ")
            let fields = [
                msg.formattedDate,
                msg.senderLabel,
                msg.text ?? "",
                reactions,
                msg.service
            ]
            try append(fields.map(CSVExport.field).joined(separator: ",") + "\n")
        }
    }

    private func exportPlainText(messages: [Message], chatTitle: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        func append(_ chunk: String) throws {
            if let data = chunk.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }

        try append("Conversation: \(chatTitle)\n")
        try append("Exported by Phosphor\n")
        try append(String(repeating: "-", count: 60) + "\n\n")

        for msg in messages {
            try cancellationCheck?()
            try append("[\(msg.formattedDate)] \(msg.senderLabel):\n")
            try append("\(msg.displayText)\n")
            for reaction in msg.reactions {
                try append("   \(reaction.type.emoji) \(reaction.sender)\n")
            }
            try append("\n")
        }
    }

    private func exportPDF(messages: [Message], chatTitle: String, to path: String, includeAttachments: Bool = true, cancellationCheck: (() throws -> Void)? = nil) throws {
        // GUIDs come from the untrusted sms.db; a corrupted or merged backup can
        // repeat one. Keep the first occurrence instead of trapping on duplicates.
        let messagesByGuid = Dictionary(messages.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })

        func replyTargetGuid(for message: Message) -> String? {
            let candidates = [message.replyToGuid, message.threadOriginatorGuid]
            for raw in candidates.compactMap({ $0 }) {
                let target = Self.stripReactionGuidPrefix(raw)
                if !target.isEmpty && target != message.guid { return target }
            }
            return nil
        }

        func replyPreview(for message: Message) -> String? {
            guard let targetGuid = replyTargetGuid(for: message) else { return nil }
            let part = message.threadOriginatorPart.map { " part \($0)" } ?? ""
            guard let target = messagesByGuid[targetGuid] else {
                return "original message\(part)"
            }
            var preview = target.displayText.replacingOccurrences(of: "\n", with: " ")
            if preview.count > 90 { preview = String(preview.prefix(90)) + "…" }
            return "\(target.senderLabel): \(preview)\(part)"
        }

        let entries = messages.map { msg -> PDFTranscriptWriter.Entry in
            let visibleAttachments = includeAttachments ? msg.attachments.filter { !$0.isPluginPayload } : []
            let body = (msg.text?.isEmpty == false) ? (msg.text ?? "") : msg.displayText
            let reactionBadges = msg.reactions.map { $0.type.emoji }
            let attachmentSummaries = visibleAttachments.map { attachment in
                var parts: [String] = [attachment.displayName]
                if let mime = attachment.mimeType, !mime.isEmpty { parts.append(mime) }
                if attachment.totalBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(attachment.totalBytes), countStyle: .file)) }
                return parts.joined(separator: " • ")
            }
            // Keep PDF exports conversation-like: don't print "iMessage" or
            // read/unread under every bubble. Surface the service only when it
            // differs from iMessage, where it helps explain SMS/MMS fallback.
            let serviceStatus = msg.service.isEmpty || msg.service.lowercased() == "imessage" ? nil : msg.service
            let statusParts = [serviceStatus].compactMap { $0 }

            return PDFTranscriptWriter.Entry(
                title: msg.senderLabel,
                subtitle: msg.formattedDate,
                body: body,
                isFromMe: msg.isFromMe,
                reactions: reactionBadges,
                inlineReply: replyPreview(for: msg),
                attachments: attachmentSummaries,
                linkURL: msg.linkURL,
                status: statusParts.isEmpty ? nil : statusParts.joined(separator: " • ")
            )
        }

        try PDFTranscriptWriter.write(
            title: chatTitle,
            subtitle: "Exported by Phosphor • \(Date().shortString) • \(messages.count) messages",
            entries: entries,
            to: path,
            cancellationCheck: cancellationCheck
        )
    }

    /// Copy referenced attachments into a sibling `<export>_attachments` folder so the
    /// HTML can <img>/<a href> them. Returns map of attachment filename -> relative
    /// path used inside the HTML. Failures are silent: attachments missing from the
    /// backup just stay as text annotations.
    ///
    /// Plugin payload blobs (rich-link metadata) are skipped because they are
    /// binary plists that macOS has no handler for and would clutter the export
    /// folder with `*.pluginPayloadAttachment` files (issue #17).
    private func stageAttachments(messages: [Message], htmlPath: String, cancellationCheck: (() throws -> Void)? = nil) throws -> [String: String] {
        let baseName = (htmlPath as NSString).deletingPathExtension
        let dir = "\(baseName)_attachments"
        let fm = FileManager.default
        var map: [String: String] = [:]
        var folderCreated = false

        for msg in messages {
            try cancellationCheck?()
            for attachment in msg.attachments {
                guard !attachment.isPluginPayload else { continue }
                guard let filename = attachment.filename, !filename.isEmpty else { continue }
                if map[filename] != nil { continue }
                guard let source = resolveAttachmentDiskPath(filename: filename) else { continue }

                if !folderCreated {
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    folderCreated = true
                }

                let displayName = (filename as NSString).lastPathComponent
                var unique = displayName
                var dest = (dir as NSString).appendingPathComponent(unique)
                var i = 2
                while fm.fileExists(atPath: dest) {
                    let ext = (displayName as NSString).pathExtension
                    let stem = (displayName as NSString).deletingPathExtension
                    unique = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
                    dest = (dir as NSString).appendingPathComponent(unique)
                    i += 1
                }
                do {
                    try fm.copyItem(atPath: source, toPath: dest)
                    let folderName = (dir as NSString).lastPathComponent
                    map[filename] = "\(folderName)/\(unique)"
                } catch {
                    continue
                }
            }
        }
        return map
    }

    private func removeAttachmentFolder(forHTMLPath htmlPath: String) {
        let baseName = (htmlPath as NSString).deletingPathExtension
        let dir = "\(baseName)_attachments"
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func exportHTML(messages: [Message], chatTitle: String, to path: String, includeAttachments: Bool = true, cancellationCheck: (() throws -> Void)? = nil) throws {
        removeAttachmentFolder(forHTMLPath: path)
        let attachmentMap = includeAttachments ? try stageAttachments(messages: messages, htmlPath: path, cancellationCheck: cancellationCheck) : [:]
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        var writeError: Error?
        func append(_ chunk: String) {
            guard writeError == nil, let data = chunk.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                writeError = error
            }
        }

        append("""
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <title>\(htmlEscape(chatTitle)) - Phosphor Export</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
                   background: #f5f5f7; padding: 24px; max-width: 680px; margin: 0 auto; }
            h1 { font-size: 22px; font-weight: 600; color: #1d1d1f; margin-bottom: 4px; }
            .meta { font-size: 13px; color: #86868b; margin-bottom: 24px; }
            .bubble { padding: 10px 14px; border-radius: 18px; margin: 3px 0; max-width: 75%;
                      font-size: 15px; line-height: 1.4; word-wrap: break-word; position: relative; }
            .from-me { background: #007aff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
            .from-them { background: #e9e9eb; color: #1d1d1f; border-bottom-left-radius: 4px; }
            .msg-row { display: flex; margin: 8px 0 2px; }
            .msg-row.me { justify-content: flex-end; }
            .time { font-size: 11px; color: #86868b; text-align: center; margin: 12px 0 4px; }
            .sender { font-size: 11px; color: #86868b; margin-left: 14px; margin-top: 8px; }
            .attach-img { display: block; max-width: 320px; border-radius: 14px; margin: 3px 0; }
            video.attach-video { display: block; max-width: 320px; border-radius: 14px; margin: 3px 0; }
            .attach-link { display: inline-block; padding: 8px 12px; border-radius: 12px;
                           background: #e9e9eb; color: #1d1d1f; font-size: 13px; text-decoration: none; }
            .from-me .attach-link { background: rgba(255,255,255,0.25); color: white; }
            .link-preview { display: inline-block; padding: 8px 12px; border-radius: 12px;
                            background: rgba(0,0,0,0.05); color: inherit; font-size: 13px; text-decoration: none; }
            .from-me .link-preview { background: rgba(255,255,255,0.2); color: white; }
            .reactions { position: absolute; top: -10px; font-size: 14px;
                         background: white; border-radius: 10px; padding: 2px 6px;
                         box-shadow: 0 1px 3px rgba(0,0,0,0.15); }
            .from-me .reactions { left: -12px; }
            .from-them .reactions { right: -12px; }
        </style>
        </head>
        <body>
        <h1>\(htmlEscape(chatTitle))</h1>
        <p class="meta">Exported by Phosphor &middot; \(Date().shortString)</p>
        """)

        var lastDateStr = ""
        var lastSender = ""

        for msg in messages {
            try cancellationCheck?()
            let dateStr = msg.formattedDate
            if dateStr != lastDateStr {
                append("<div class=\"time\">\(htmlEscape(dateStr))</div>\n")
                lastDateStr = dateStr
            }

            let sender = msg.senderLabel
            if sender != lastSender && !msg.isFromMe {
                append("<div class=\"sender\">\(htmlEscape(sender))</div>\n")
                lastSender = sender
            }

            let cssClass = msg.isFromMe ? "me" : ""
            let bubbleClass = msg.isFromMe ? "from-me" : "from-them"
            let rawText = msg.text ?? ""
            let text = htmlEscape(rawText).replacingOccurrences(of: "\n", with: "<br>")

            var bubbleHTML = ""
            if !text.isEmpty {
                bubbleHTML += text
            }

            for attachment in msg.attachments where !attachment.isPluginPayload {
                guard let filename = attachment.filename,
                      let relPath = attachmentMap[filename] else {
                    if !bubbleHTML.isEmpty { bubbleHTML += "<br>" }
                    bubbleHTML += "[\(htmlEscape(attachment.displayName))]"
                    continue
                }
                if !bubbleHTML.isEmpty { bubbleHTML += "<br>" }
                if attachment.isImage {
                    bubbleHTML += "<img class=\"attach-img\" src=\"\(htmlEscape(relPath))\" loading=\"lazy\">"
                } else if attachment.isVideo {
                    bubbleHTML += "<video class=\"attach-video\" controls src=\"\(htmlEscape(relPath))\"></video>"
                } else {
                    let name = (relPath as NSString).lastPathComponent
                    bubbleHTML += "<a class=\"attach-link\" href=\"\(htmlEscape(relPath))\">\(htmlEscape(name))</a>"
                }
            }

            if let link = msg.linkURL, !link.isEmpty {
                if !bubbleHTML.isEmpty { bubbleHTML += "<br>" }
                bubbleHTML += "<a class=\"link-preview\" href=\"\(htmlEscape(link))\">\(htmlEscape(link))</a>"
            }

            if bubbleHTML.isEmpty && msg.hasAttachment {
                bubbleHTML = "[Attachment]"
            }
            if bubbleHTML.isEmpty {
                bubbleHTML = "[Empty message]"
            }

            // Render active reactions as a floating badge.
            var reactionHTML = ""
            if !msg.reactions.isEmpty {
                let glyphs = msg.reactions.map { $0.type.emoji }.joined(separator: " ")
                reactionHTML = "<span class=\"reactions\" title=\"\(htmlEscape(msg.reactions.map { "\($0.sender) \($0.type.label.lowercased())" }.joined(separator: ", ")))\">\(glyphs)</span>"
            }

            append("<div class=\"msg-row \(cssClass)\"><div class=\"bubble \(bubbleClass)\">\(bubbleHTML)\(reactionHTML)</div></div>\n")
        }

        append("</body></html>")
        if let writeError { throw writeError }
    }
    /// Export messages as RFC 4155 mbox (mboxo). Each message becomes a separate
    /// RFC 5322 envelope so Mail.app, Thunderbird, mutt, etc. can import the
    /// conversation as a mail folder. Attachments are embedded as base64 MIME parts
    /// when the backup file is available, otherwise referenced by name only.
    private func exportMbox(messages: [Message], chatTitle: String, to path: String, includeAttachments: Bool = true, cancellationCheck: (() throws -> Void)? = nil) throws {
        let crlf = "\r\n"
        let userDomain = "phosphor.local"
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        var writeError: Error?
        func append(_ chunk: String) {
            guard writeError == nil, let data = chunk.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                writeError = error
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let rfc5322Formatter = DateFormatter()
        rfc5322Formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        rfc5322Formatter.locale = Locale(identifier: "en_US_POSIX")

        for msg in messages {
            try cancellationCheck?()
            let envelopeDate = dateFormatter.string(from: msg.date)
            let envelopeFrom = msg.isFromMe ? "me" : (msg.handleId.isEmpty ? "unknown" : msg.handleId)
            let envelopeAddr = mboxAddress(envelopeFrom, domain: userDomain)

            // mboxo: ">From " escape protects the From-line delimiter.
            append("From \(envelopeAddr) \(envelopeDate)\(crlf)")

            let fromDisplay = msg.isFromMe ? "Me" : msg.senderLabel
            let fromHeader = msg.isFromMe
                ? "Me <me@\(userDomain)>"
                : "\(headerEncode(fromDisplay)) <\(mboxAddress(msg.handleId.isEmpty ? fromDisplay : msg.handleId, domain: userDomain))>"
            let toHeader = msg.isFromMe
                ? "\(headerEncode(chatTitle)) <\(mboxAddress(chatTitle, domain: userDomain))>"
                : "Me <me@\(userDomain)>"

            append("From: \(fromHeader)\(crlf)")
            append("To: \(toHeader)\(crlf)")
            append("Date: \(rfc5322Formatter.string(from: msg.date))\(crlf)")
            append("Subject: \(headerEncode(chatTitle))\(crlf)")
            append("Message-ID: <\(mboxToken(msg.guid))@\(userDomain)>\(crlf)")
            append("X-Phosphor-Service: \(headerEncode(msg.service))\(crlf)")
            if !msg.reactions.isEmpty {
                let summary = msg.reactions.map { "\($0.sender):\($0.type.label)" }.joined(separator: ", ")
                append("X-Phosphor-Reactions: \(headerEncode(summary))\(crlf)")
            }
            append("MIME-Version: 1.0\(crlf)")

            let body = msg.text ?? ""
            let inlineAttachments = msg.attachments.filter { !$0.isPluginPayload }
            let embeddedAttachments: [(attachment: MessageAttachment, diskPath: String, data: Data)] = includeAttachments
                ? inlineAttachments.compactMap { attachment in
                    guard let filename = attachment.filename,
                          let diskPath = resolveAttachmentDiskPath(filename: filename),
                          let data = try? Data(contentsOf: URL(fileURLWithPath: diskPath)) else {
                        return nil
                    }
                    return (attachment, diskPath, data)
                }
                : []

            if !embeddedAttachments.isEmpty {
                let boundary = "----=_Phosphor_\(mboxToken(msg.guid))"
                append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)\(crlf)")

                append("--\(boundary)\(crlf)")
                append("Content-Type: text/plain; charset=UTF-8\(crlf)")
                append("Content-Transfer-Encoding: 8bit\(crlf)\(crlf)")
                var bodyOut = body.isEmpty ? "[Attachment]" : body
                let embeddedFilenames = Set(embeddedAttachments.compactMap { $0.attachment.filename })
                let missingNames = inlineAttachments
                    .filter { attachment in
                        guard let filename = attachment.filename else { return true }
                        return !embeddedFilenames.contains(filename)
                    }
                    .map(\.displayName)
                if !missingNames.isEmpty {
                    bodyOut += "\n\n[Attachment: \(missingNames.joined(separator: ", "))]"
                }
                append(mboxEscape(bodyOut) + crlf + crlf)

                for embedded in embeddedAttachments {
                    let attachment = embedded.attachment
                    let name = attachment.filename.map { ($0 as NSString).lastPathComponent } ?? attachment.displayName
                    let mime = headerToken(attachment.mimeType ?? "application/octet-stream", fallback: "application/octet-stream")
                    append("--\(boundary)\(crlf)")
                    append("Content-Type: \(mime); name=\"\(headerEncode(name))\"\(crlf)")
                    append("Content-Disposition: attachment; filename=\"\(headerEncode(name))\"\(crlf)")
                    append("Content-Transfer-Encoding: base64\(crlf)\(crlf)")
                    append(embedded.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
                    append(crlf)
                }
                append("--\(boundary)--\(crlf)\(crlf)")
            } else {
                append("Content-Type: text/plain; charset=UTF-8\(crlf)")
                append("Content-Transfer-Encoding: 8bit\(crlf)\(crlf)")
                var bodyOut = body
                if !inlineAttachments.isEmpty {
                    let names = inlineAttachments.map(\.displayName).joined(separator: ", ")
                    if !bodyOut.isEmpty { bodyOut += "\n\n" }
                    bodyOut += "[Attachment: \(names)]"
                }
                if let link = msg.linkURL, !link.isEmpty {
                    if !bodyOut.isEmpty { bodyOut += "\n\n" }
                    bodyOut += "[Link: \(link)]"
                }
                if bodyOut.isEmpty { bodyOut = msg.displayText }
                append(mboxEscape(bodyOut) + crlf + crlf)
            }
        }

        if let writeError { throw writeError }
    }

    /// Mbox bodies must escape lines that start with `From ` so the delimiter remains unambiguous.
    private func mboxEscape(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line in
            line.hasPrefix("From ") ? ">" + line : line
        }.joined(separator: "\r\n")
    }

    /// Build a safe local-part for synthetic email addresses derived from handle ids.
    private func mboxAddress(_ raw: String, domain: String) -> String {
        let cleaned = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || "._-+".contains($0) }
        let local = cleaned.isEmpty ? "unknown" : cleaned
        return "\(local)@\(domain)"
    }

    private func mboxToken(_ raw: String) -> String {
        let cleaned = raw.filter { $0.isLetter || $0.isNumber || "._-+".contains($0) }
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    private func headerToken(_ raw: String, fallback: String) -> String {
        let cleaned = raw.filter { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// RFC 2047 encoded-word for header values containing non-ASCII.
    private func headerEncode(_ raw: String) -> String {
        let sanitized = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        if sanitized.allSatisfy({ $0.isASCII }) { return sanitized }
        let base64 = Data(sanitized.utf8).base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    private func htmlEscape(_ raw: String) -> String {
        raw.htmlEscaped
    }

    private func exportJSON(messages: [Message], chatTitle: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        func append(_ chunk: String) throws {
            if let data = chunk.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }

        try append("""
        {
          "chat": \(try jsonLiteral(chatTitle)),
          "exported_at": \(try jsonLiteral(Date().iso8601String)),
          "exported_by": "Phosphor",
          "message_count": \(messages.count),
          "messages": [
        """)

        for (index, msg) in messages.enumerated() {
            try cancellationCheck?()
            var entry: [String: Any] = [
                "id": msg.id,
                "guid": msg.guid,
                "date": msg.date.iso8601String,
                "sender": msg.senderLabel,
                "handle": msg.handleId,
                "text": msg.text ?? "",
                "is_from_me": msg.isFromMe,
                "service": msg.service,
                "has_attachment": msg.hasAttachment,
                "attachments": msg.attachments.filter { !$0.isPluginPayload }.map { att -> [String: Any] in
                    [
                        "filename": att.filename ?? "",
                        "mime_type": att.mimeType ?? "",
                        "transfer_name": att.transferName ?? "",
                        "total_bytes": att.totalBytes
                    ]
                },
                "reactions": msg.reactions.map { ["sender": $0.sender, "type": $0.type.label, "emoji": $0.type.emoji] }
            ]
            if let replyToGuid = msg.replyToGuid { entry["reply_to_guid"] = replyToGuid }
            if let threadOriginatorGuid = msg.threadOriginatorGuid { entry["thread_originator_guid"] = threadOriginatorGuid }
            if let threadOriginatorPart = msg.threadOriginatorPart { entry["thread_originator_part"] = threadOriginatorPart }
            if let link = msg.linkURL { entry["link_url"] = link }
            if index > 0 { try append(",\n") }
            try append("    " + jsonObjectString(entry))
        }

        try append("""

          ]
        }
        """)
    }

    private func jsonLiteral(_ string: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [string], options: [])
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private func jsonObjectString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private Helpers

    private func parseMessage(_ row: [String: Any?],
                              attachments: [MessageAttachment],
                              reactions: [Reaction],
                              remainingAttributedBodyTextBytes: inout Int) -> Message? {
        guard let rowId = row["ROWID"] as? Int,
              let guid = row["guid"] as? String else { return nil }

        let date: Date
        if let timestamp = row["date"] as? Int {
            date = Message.dateFromAppleTimestamp(timestamp)
        } else {
            date = Date.distantPast
        }

        let handleId = (row["handle_id"] as? String) ?? ""
        let isFromMe = (row["is_from_me"] as? Int) == 1
        let visibleAttachments = attachments.filter { !$0.isPluginPayload }

        let plainText = row["text"] as? String
        let text: String?
        if let plainText, !plainText.isEmpty {
            text = plainText
        } else if let messageId = row["attributed_body_rowid"] as? Int,
                  let recovered = loadAttributedBodyText(messageId: messageId) {
            let recoveredByteCount = recovered.utf8.count
            if recoveredByteCount <= remainingAttributedBodyTextBytes {
                remainingAttributedBodyTextBytes -= recoveredByteCount
                text = recovered
            } else {
                text = plainText
            }
        } else {
            text = plainText
        }
        let balloonBundle = row["balloon_bundle_id"] as? String
        let payload = row["payload_data"] as? Data

        // Best-effort link extraction. The text URL is usually fine; rich-link
        // balloons store the URL inside payload_data so we fall back to that.
        var linkURL: String? = nil
        if let text, let url = Self.firstURL(in: text) {
            linkURL = url
        } else if let payload, balloonBundle?.hasPrefix("com.apple.messages.URLBalloonProvider") == true {
            linkURL = Self.extractURL(fromPayload: payload)
        }

        let senderName = isFromMe ? "Me" : contacts.displayName(forHandle: handleId)

        return Message(
            id: rowId,
            guid: guid,
            text: text,
            date: date,
            isFromMe: isFromMe,
            handleId: handleId,
            senderName: senderName,
            service: (row["service"] as? String) ?? "iMessage",
            hasAttachment: (row["cache_has_attachments"] as? Int) == 1 || !visibleAttachments.isEmpty,
            attachments: visibleAttachments,
            isRead: (row["is_read"] as? Int) == 1,
            reactions: reactions,
            replyToGuid: row["reply_to_guid"] as? String,
            threadOriginatorGuid: row["thread_originator_guid"] as? String,
            threadOriginatorPart: row["thread_originator_part"] as? String,
            linkURL: linkURL,
            balloonBundleID: balloonBundle
        )
    }

    /// Loads at most one schema- and size-gated attributed body at a time so a
    /// full chat query never retains every backup-controlled BLOB in memory.
    private func loadAttributedBodyText(messageId: Int) -> String? {
        let sql = """
            SELECT \(MessageAttributedBodyDecoder.attributedBodySQLProjection)
            FROM message m
            WHERE m.ROWID = ?
            LIMIT 1
        """
        guard let rows = try? db.query(sql, params: [String(messageId)]),
              let body = rows.first?["attributedBody"] as? Data else {
            return nil
        }
        return MessageAttributedBodyDecoder.text(from: body)
    }

    /// First http(s) URL inside a string, using a cached `NSDataDetector`.
    /// Creating detectors is relatively expensive and this method runs once per
    /// message while building message lists/exports.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstURL(in text: String) -> String? {
        guard let detector = linkDetector else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        return url.absoluteString
    }

    /// Pull a URL out of a rich-link `payload_data` blob. The payload is an
    /// NSKeyedArchiver-encoded `LPLinkMetadata`; walking `$objects` for the
    /// first http(s) string is the cheapest reliable heuristic and avoids
    /// pulling in `LinkPresentation` for what is essentially a plist scan.
    static func extractURL(fromPayload payload: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for obj in objects {
            if let str = obj as? String,
               (str.hasPrefix("http://") || str.hasPrefix("https://")) {
                return str
            }
        }
        return nil
    }
}
