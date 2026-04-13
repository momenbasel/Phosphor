import Foundation

/// Extracts and exports iMessage/SMS conversations from iOS backup sms.db.
///
/// The sms.db is stored at HomeDomain/Library/SMS/sms.db in the backup.
/// Its SHA-1 hash in Manifest.db is the famous "3d0d7e5fb2ce288813306e4d4636395e047a3d28".
final class MessageExporter {

    /// The well-known SHA-1 hash for sms.db in iOS backups.
    static let smsDbHash = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"

    private let db: SQLiteReader

    init(databasePath: String) throws {
        self.db = try SQLiteReader(path: databasePath)
    }

    /// Initialize from a backup directory by locating the sms.db.
    convenience init(backupPath: String) throws {
        // The sms.db file is stored as its SHA-1 hash in a two-character prefixed subdirectory
        let hashPrefix = String(Self.smsDbHash.prefix(2))
        let smsPath = "\(backupPath)/\(hashPrefix)/\(Self.smsDbHash)"

        guard FileManager.default.fileExists(atPath: smsPath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "sms.db not found in backup. Is this an unencrypted backup?"])
        }

        try self.init(databasePath: smsPath)
    }

    // MARK: - Conversations

    /// Get all chat conversations.
    func getChats() throws -> [MessageChat] {
        let sql = """
            SELECT
                c.ROWID,
                c.chat_identifier,
                c.display_name,
                c.style,
                (SELECT COUNT(*) FROM chat_message_join cmj WHERE cmj.chat_id = c.ROWID) as msg_count,
                (SELECT MAX(m.date) FROM message m
                 JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                 WHERE cmj.chat_id = c.ROWID) as last_date
            FROM chat c
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

            return MessageChat(
                id: rowId,
                chatIdentifier: chatId,
                displayName: (row["display_name"] as? String) ?? "",
                lastMessageDate: lastDate,
                messageCount: (row["msg_count"] as? Int) ?? 0,
                isGroupChat: (row["style"] as? Int) == 43
            )
        }
    }

    /// Get all messages in a specific chat.
    func getMessages(chatId: Int) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            ORDER BY m.date ASC
        """

        let rows = try db.query(sql, params: [String(chatId)])
        return rows.compactMap(parseMessage)
    }

    /// Get all messages (across all chats).
    func getAllMessages(limit: Int = 10000) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap(parseMessage)
    }

    /// Search messages by text content.
    func searchMessages(_ query: String, limit: Int = 500) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.text LIKE ?
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: ["%\(query)%"])
        return rows.compactMap(parseMessage)
    }

    // MARK: - Export

    /// Export messages to a file in the specified format.
    func exportChat(chatId: Int, format: MessageExportFormat, to path: String) throws {
        let messages = try getMessages(chatId: chatId)
        let chats = try getChats()
        let chat = chats.first { $0.id == chatId }
        let chatTitle = chat?.title ?? "Unknown"

        switch format {
        case .csv:
            try exportCSV(messages: messages, chatTitle: chatTitle, to: path)
        case .txt:
            try exportPlainText(messages: messages, chatTitle: chatTitle, to: path)
        case .html:
            try exportHTML(messages: messages, chatTitle: chatTitle, to: path)
        case .json:
            try exportJSON(messages: messages, chatTitle: chatTitle, to: path)
        }
    }

    /// Export all conversations.
    func exportAllChats(format: MessageExportFormat, to directory: String) throws -> Int {
        let chats = try getChats()
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var count = 0
        for chat in chats {
            let safeName = chat.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let filename = "\(safeName).\(format.fileExtension)"
            let path = (directory as NSString).appendingPathComponent(String(filename))
            try exportChat(chatId: chat.id, format: format, to: path)
            count += 1
        }
        return count
    }

    // MARK: - Private Export Implementations

    private func exportCSV(messages: [Message], chatTitle: String, to path: String) throws {
        var csv = "Date,Sender,Text,Service\n"
        for msg in messages {
            let text = (msg.text ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            csv += "\"\(msg.formattedDate)\",\"\(msg.senderLabel)\",\"\(text)\",\"\(msg.service)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportPlainText(messages: [Message], chatTitle: String, to path: String) throws {
        var lines = "Conversation: \(chatTitle)\n"
        lines += "Exported by Phosphor\n"
        lines += String(repeating: "-", count: 60) + "\n\n"

        for msg in messages {
            let prefix = msg.isFromMe ? "Me" : msg.handleId
            lines += "[\(msg.formattedDate)] \(prefix):\n"
            lines += "\(msg.displayText)\n\n"
        }
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportHTML(messages: [Message], chatTitle: String, to path: String) throws {
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <title>\(chatTitle) - Phosphor Export</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
                   background: #f5f5f7; padding: 24px; max-width: 680px; margin: 0 auto; }
            h1 { font-size: 22px; font-weight: 600; color: #1d1d1f; margin-bottom: 4px; }
            .meta { font-size: 13px; color: #86868b; margin-bottom: 24px; }
            .bubble { padding: 10px 14px; border-radius: 18px; margin: 3px 0; max-width: 75%;
                      font-size: 15px; line-height: 1.4; word-wrap: break-word; }
            .from-me { background: #007aff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
            .from-them { background: #e9e9eb; color: #1d1d1f; border-bottom-left-radius: 4px; }
            .msg-row { display: flex; margin: 2px 0; }
            .msg-row.me { justify-content: flex-end; }
            .time { font-size: 11px; color: #86868b; text-align: center; margin: 12px 0 4px; }
            .sender { font-size: 11px; color: #86868b; margin-left: 14px; margin-top: 8px; }
        </style>
        </head>
        <body>
        <h1>\(chatTitle)</h1>
        <p class="meta">Exported by Phosphor &middot; \(Date().shortString)</p>
        """

        var lastDateStr = ""
        var lastSender = ""

        for msg in messages {
            let dateStr = msg.formattedDate
            if dateStr != lastDateStr {
                html += "<div class=\"time\">\(dateStr)</div>\n"
                lastDateStr = dateStr
            }

            let sender = msg.isFromMe ? "Me" : msg.handleId
            if sender != lastSender && !msg.isFromMe {
                html += "<div class=\"sender\">\(sender)</div>\n"
                lastSender = sender
            }

            let cssClass = msg.isFromMe ? "me" : ""
            let bubbleClass = msg.isFromMe ? "from-me" : "from-them"
            let text = (msg.text ?? "[Attachment]")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            html += "<div class=\"msg-row \(cssClass)\"><div class=\"bubble \(bubbleClass)\">\(text)</div></div>\n"
        }

        html += "</body></html>"
        try html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportJSON(messages: [Message], chatTitle: String, to path: String) throws {
        let entries: [[String: Any]] = messages.map { msg in
            [
                "id": msg.id,
                "date": msg.date.iso8601String,
                "sender": msg.senderLabel,
                "text": msg.text ?? "",
                "is_from_me": msg.isFromMe,
                "service": msg.service,
                "has_attachment": msg.hasAttachment
            ]
        }

        let root: [String: Any] = [
            "chat": chatTitle,
            "exported_at": Date().iso8601String,
            "exported_by": "Phosphor",
            "message_count": messages.count,
            "messages": entries
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Private Helpers

    private func parseMessage(_ row: [String: Any?]) -> Message? {
        guard let rowId = row["ROWID"] as? Int,
              let guid = row["guid"] as? String else { return nil }

        let date: Date
        if let timestamp = row["date"] as? Int {
            date = Message.dateFromAppleTimestamp(timestamp)
        } else {
            date = Date.distantPast
        }

        return Message(
            id: rowId,
            guid: guid,
            text: row["text"] as? String,
            date: date,
            isFromMe: (row["is_from_me"] as? Int) == 1,
            handleId: (row["handle_id"] as? String) ?? "",
            service: (row["service"] as? String) ?? "iMessage",
            hasAttachment: (row["cache_has_attachments"] as? Int) == 1,
            attachmentFilename: nil,
            attachmentMimeType: nil,
            isRead: (row["is_read"] as? Int) == 1
        )
    }
}
