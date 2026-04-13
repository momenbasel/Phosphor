import Foundation

/// Extracts and exports WhatsApp conversations from iOS backup ChatStorage.sqlite.
///
/// WhatsApp stores messages in:
///   AppDomainGroup-group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite
///   or AppDomain-net.whatsapp.WhatsApp/Documents/ChatStorage.sqlite
///
/// Schema overview:
///   ZWAMESSAGE - individual messages
///   ZWACHATSESSION - conversations (1:1 and group)
///   ZWAMEDIAITEM - attachments (photos, videos, audio, documents)
///   ZWAGROUPMEMBER - group participants
final class WhatsAppExporter {

    private let db: SQLiteReader

    struct WAChat: Identifiable, Hashable {
        let id: Int
        let contactJid: String
        let partnerName: String
        let lastMessageDate: Date?
        let messageCount: Int
        let isGroup: Bool
        let unreadCount: Int

        var displayName: String {
            if !partnerName.isEmpty { return partnerName }
            // Clean up JID: "+1234567890@s.whatsapp.net" -> "+1234567890"
            return contactJid
                .replacingOccurrences(of: "@s.whatsapp.net", with: "")
                .replacingOccurrences(of: "@g.us", with: " (Group)")
        }
    }

    struct WAMessage: Identifiable, Hashable {
        let id: Int
        let text: String?
        let date: Date
        let isFromMe: Bool
        let senderJid: String?
        let mediaType: Int // 0=text, 1=image, 2=video, 3=audio, 4=contact, 5=location, 8=document
        let mediaLocalPath: String?
        let starred: Bool

        var displayText: String {
            if let text, !text.isEmpty { return text }
            return mediaTypeLabel
        }

        var mediaTypeLabel: String {
            switch mediaType {
            case 1: return "[Photo]"
            case 2: return "[Video]"
            case 3: return "[Audio]"
            case 4: return "[Contact]"
            case 5: return "[Location]"
            case 8: return "[Document]"
            case 9: return "[Sticker]"
            case 15: return "[GIF]"
            default: return text ?? "[Message]"
            }
        }

        var formattedDate: String {
            date.shortString
        }
    }

    init(databasePath: String) throws {
        self.db = try SQLiteReader(path: databasePath)
    }

    /// Initialize from a backup by finding WhatsApp's ChatStorage.sqlite.
    convenience init(backupPath: String) throws {
        let manifest = try BackupManifest(backupPath: backupPath)

        // Try AppDomainGroup first (newer WhatsApp versions)
        if let entry = try manifest.whatsAppDatabase() {
            let filePath = entry.diskPath(backupRoot: backupPath)
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw NSError(domain: "Phosphor", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "WhatsApp database file not found on disk"])
            }
            try self.init(databasePath: filePath)
            return
        }

        // Try direct search
        let candidates = try manifest.search("ChatStorage.sqlite")
        for candidate in candidates where candidate.isFile {
            let filePath = candidate.diskPath(backupRoot: backupPath)
            if FileManager.default.fileExists(atPath: filePath) {
                try self.init(databasePath: filePath)
                return
            }
        }

        throw NSError(domain: "Phosphor", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "WhatsApp ChatStorage.sqlite not found in backup. Is WhatsApp installed?"])
    }

    // MARK: - Chats

    func getChats() throws -> [WAChat] {
        // ZWACHATSESSION table holds conversations
        let sql = """
            SELECT
                cs.Z_PK,
                cs.ZCONTACTJID,
                cs.ZPARTNERNAME,
                cs.ZLASTMESSAGEDATE,
                cs.ZMESSAGECOUNTER,
                cs.ZSESSIONTYPE,
                COALESCE(cs.ZUNREADCOUNT, 0) as unread
            FROM ZWACHATSESSION cs
            WHERE cs.ZMESSAGECOUNTER > 0
            ORDER BY cs.ZLASTMESSAGEDATE DESC
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> WAChat? in
            guard let pk = row["Z_PK"] as? Int,
                  let jid = row["ZCONTACTJID"] as? String else { return nil }

            let lastDate: Date?
            if let timestamp = row["ZLASTMESSAGEDATE"] as? Double {
                // WhatsApp uses NSDate reference (seconds since 2001-01-01)
                lastDate = Date(timeIntervalSinceReferenceDate: timestamp)
            } else if let timestamp = row["ZLASTMESSAGEDATE"] as? Int {
                lastDate = Date(timeIntervalSinceReferenceDate: TimeInterval(timestamp))
            } else {
                lastDate = nil
            }

            return WAChat(
                id: pk,
                contactJid: jid,
                partnerName: (row["ZPARTNERNAME"] as? String) ?? "",
                lastMessageDate: lastDate,
                messageCount: (row["ZMESSAGECOUNTER"] as? Int) ?? 0,
                isGroup: jid.contains("@g.us"),
                unreadCount: (row["unread"] as? Int) ?? 0
            )
        }
    }

    // MARK: - Messages

    func getMessages(chatId: Int) throws -> [WAMessage] {
        let sql = """
            SELECT
                m.Z_PK,
                m.ZTEXT,
                m.ZMESSAGEDATE,
                m.ZISFROMME,
                m.ZFROMJID,
                m.ZMESSAGETYPE,
                m.ZSTARRED,
                mi.ZMEDIALOCALPATH
            FROM ZWAMESSAGE m
            LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            WHERE m.ZCHATSESSION = ?
            ORDER BY m.ZMESSAGEDATE ASC
        """

        let rows = try db.query(sql, params: [String(chatId)])
        return rows.compactMap(parseMessage)
    }

    func searchMessages(_ query: String, limit: Int = 500) throws -> [WAMessage] {
        let sql = """
            SELECT
                m.Z_PK,
                m.ZTEXT,
                m.ZMESSAGEDATE,
                m.ZISFROMME,
                m.ZFROMJID,
                m.ZMESSAGETYPE,
                m.ZSTARRED,
                mi.ZMEDIALOCALPATH
            FROM ZWAMESSAGE m
            LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
            WHERE m.ZTEXT LIKE ?
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: ["%\(query)%"])
        return rows.compactMap(parseMessage)
    }

    // MARK: - Export

    func exportChat(chatId: Int, format: MessageExportFormat, to path: String) throws {
        let messages = try getMessages(chatId: chatId)
        let chats = try getChats()
        let chat = chats.first { $0.id == chatId }
        let chatTitle = chat?.displayName ?? "WhatsApp Chat"

        switch format {
        case .csv:
            try exportCSV(messages: messages, title: chatTitle, to: path)
        case .txt:
            try exportTXT(messages: messages, title: chatTitle, to: path)
        case .html:
            try exportHTML(messages: messages, title: chatTitle, to: path)
        case .json:
            try exportJSON(messages: messages, title: chatTitle, to: path)
        }
    }

    func exportAllChats(format: MessageExportFormat, to directory: String) throws -> Int {
        let chats = try getChats()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var count = 0
        for chat in chats {
            let safeName = chat.displayName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let path = (directory as NSString).appendingPathComponent("\(safeName).\(format.fileExtension)")
            try exportChat(chatId: chat.id, format: format, to: path)
            count += 1
        }
        return count
    }

    // MARK: - Private

    private func parseMessage(_ row: [String: Any?]) -> WAMessage? {
        guard let pk = row["Z_PK"] as? Int else { return nil }

        let date: Date
        if let timestamp = row["ZMESSAGEDATE"] as? Double {
            date = Date(timeIntervalSinceReferenceDate: timestamp)
        } else if let timestamp = row["ZMESSAGEDATE"] as? Int {
            date = Date(timeIntervalSinceReferenceDate: TimeInterval(timestamp))
        } else {
            date = .distantPast
        }

        return WAMessage(
            id: pk,
            text: row["ZTEXT"] as? String,
            date: date,
            isFromMe: (row["ZISFROMME"] as? Int) == 1,
            senderJid: row["ZFROMJID"] as? String,
            mediaType: (row["ZMESSAGETYPE"] as? Int) ?? 0,
            mediaLocalPath: row["ZMEDIALOCALPATH"] as? String,
            starred: (row["ZSTARRED"] as? Int) == 1
        )
    }

    private func exportCSV(messages: [WAMessage], title: String, to path: String) throws {
        var csv = "Date,Sender,Text,Media Type\n"
        for msg in messages {
            let text = (msg.displayText)
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            let sender = msg.isFromMe ? "Me" : (msg.senderJid ?? "Unknown")
            csv += "\"\(msg.formattedDate)\",\"\(sender)\",\"\(text)\",\"\(msg.mediaTypeLabel)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportTXT(messages: [WAMessage], title: String, to path: String) throws {
        var lines = "WhatsApp Chat: \(title)\n"
        lines += "Exported by Phosphor\n"
        lines += String(repeating: "-", count: 60) + "\n\n"
        for msg in messages {
            let sender = msg.isFromMe ? "Me" : (msg.senderJid ?? "Unknown")
            lines += "[\(msg.formattedDate)] \(sender):\n\(msg.displayText)\n\n"
        }
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportHTML(messages: [WAMessage], title: String, to path: String) throws {
        var html = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="UTF-8">
        <title>\(title) - WhatsApp Export</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, system-ui, sans-serif; background: #ECE5DD; padding: 20px; max-width: 680px; margin: 0 auto; }
        h1 { font-size: 20px; text-align: center; padding: 16px; background: #075E54; color: white; border-radius: 12px 12px 0 0; }
        .chat { background: #E4DDD6; padding: 16px; border-radius: 0 0 12px 12px; }
        .msg { padding: 8px 12px; border-radius: 8px; margin: 4px 0; max-width: 75%; font-size: 14px; line-height: 1.4; position: relative; }
        .from-me { background: #DCF8C6; margin-left: auto; border-bottom-right-radius: 2px; }
        .from-them { background: white; border-bottom-left-radius: 2px; }
        .row { display: flex; margin: 2px 0; }
        .row.me { justify-content: flex-end; }
        .time { font-size: 10px; color: #999; text-align: right; margin-top: 2px; }
        .sender { font-size: 11px; color: #075E54; font-weight: 600; margin-bottom: 2px; }
        .media { color: #999; font-style: italic; }
        </style></head><body>
        <h1>\(title)</h1><div class="chat">
        """

        for msg in messages {
            let cls = msg.isFromMe ? "me" : ""
            let bubble = msg.isFromMe ? "from-me" : "from-them"
            let text = (msg.displayText)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            html += "<div class=\"row \(cls)\"><div class=\"msg \(bubble)\">"
            if !msg.isFromMe, let sender = msg.senderJid {
                html += "<div class=\"sender\">\(sender)</div>"
            }
            if msg.mediaType != 0 {
                html += "<span class=\"media\">\(text)</span>"
            } else {
                html += text
            }
            html += "<div class=\"time\">\(msg.formattedDate)</div></div></div>\n"
        }

        html += "</div></body></html>"
        try html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportJSON(messages: [WAMessage], title: String, to path: String) throws {
        let entries: [[String: Any]] = messages.map { msg in
            [
                "id": msg.id,
                "date": msg.date.iso8601String,
                "sender": msg.isFromMe ? "Me" : (msg.senderJid ?? ""),
                "text": msg.text ?? "",
                "is_from_me": msg.isFromMe,
                "media_type": msg.mediaType,
                "starred": msg.starred
            ]
        }
        let root: [String: Any] = [
            "chat": title, "source": "WhatsApp",
            "exported_at": Date().iso8601String, "exported_by": "Phosphor",
            "message_count": messages.count, "messages": entries
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
