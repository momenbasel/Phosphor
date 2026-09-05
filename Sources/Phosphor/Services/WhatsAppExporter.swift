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
    private let manifest: BackupManifest?
    private let source: BackupManifest.WhatsAppSource?
    private var mediaPathCache: [String: String] = [:]
    private var missingMediaPaths: Set<String> = []

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
            // Clean up JID: "+123****7890@s.whatsapp.net" -> "+123****7890"
            return contactJid
                .replacingOccurrences(of: "@s.whatsapp.net", with: "")
                .replacingOccurrences(of: "@g.us", with: " (Group)")
        }

        func exportFilename(format: MessageExportFormat, includeChatID: Bool) -> String {
            let sanitized = displayName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let contactName = String(sanitized.prefix(80))
            let baseName = contactName.isEmpty ? "WhatsApp Conversation" : contactName
            return "\(baseName)\(includeChatID ? "-\(id)" : "").\(format.fileExtension)"
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

    init(
        databasePath: String,
        manifest: BackupManifest? = nil,
        source: BackupManifest.WhatsAppSource? = nil
    ) throws {
        self.db = try SQLiteReader(path: databasePath)
        self.manifest = manifest
        self.source = source
    }

    /// Initialize from a backup and a specific WhatsApp source. When callers do
    /// not specify one, Personal is chosen first by BackupManifest's stable order.
    convenience init(backupPath: String, source: BackupManifest.WhatsAppSource? = nil) throws {
        let manifest = try BackupManifest(backupPath: backupPath)
        let databases = try manifest.whatsAppDatabases()
        let database = source.flatMap { requested in
            databases.first { $0.source == requested }
        } ?? (source == nil ? databases.first : nil)
        guard let database else {
            let label = source?.displayName ?? ""
            throw NSError(
                domain: "Phosphor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "\(label.isEmpty ? "WhatsApp" : label + " WhatsApp") ChatStorage.sqlite not found in backup."]
            )
        }

        let filePath = try manifest.readablePath(for: database.entry)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "WhatsApp database file not found on disk"])
        }
        try self.init(databasePath: filePath, manifest: manifest, source: database.source)
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
            WHERE m.ZTEXT LIKE ? ESCAPE '\\'
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: [SQLiteReader.containsPattern(query)])
        return rows.compactMap(parseMessage)
    }

    // MARK: - Export

    func exportChat(
        chatId: Int,
        format: MessageExportFormat,
        to path: String,
        options: MessageExportOptions = MessageExportOptions(),
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        try cancellationCheck?()
        let messages = filtered(try getMessages(chatId: chatId), options: options)
        let chat = try getChats().first { $0.id == chatId }
        try exportMessages(
            messages,
            title: chat?.displayName ?? "WhatsApp Chat",
            format: format,
            to: path,
            options: options,
            cancellationCheck: cancellationCheck
        )
    }

    func exportChatPDFBundle(
        chat: WAChat,
        messages: [WAMessage],
        to parentDirectory: String,
        options: MessageExportOptions = MessageExportOptions(),
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> MessageExportBundleWriter.Result {
        var bundleOptions = options
        bundleOptions.includeAttachments = true
        let filteredMessages = filtered(messages, options: bundleOptions)
        let filename = chat.exportFilename(format: .pdf, includeChatID: false)
        let directoryName = (filename as NSString).deletingPathExtension
        return try MessageExportBundleWriter.write(
            in: URL(fileURLWithPath: parentDirectory, isDirectory: true),
            directoryName: directoryName
        ) { conversationDirectory in
            let attachmentsDirectory = conversationDirectory.appendingPathComponent("Attachments", isDirectory: true)
            let attachmentMap = try stageMedia(
                messages: filteredMessages,
                to: attachmentsDirectory,
                cancellationCheck: cancellationCheck
            )
            if attachmentMap.isEmpty {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            }
            try exportMessages(
                filteredMessages,
                title: chat.displayName,
                format: .pdf,
                to: conversationDirectory.appendingPathComponent(filename).path,
                options: bundleOptions,
                attachmentMap: attachmentMap,
                cancellationCheck: cancellationCheck
            )
            return 1
        }
    }

    func exportAllChats(
        format: MessageExportFormat,
        to parentDirectory: String,
        options: MessageExportOptions = MessageExportOptions(),
        onProgress: ((Int, Int, String) throws -> Void)? = nil,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> MessageExportBundleWriter.Result {
        let chats = try getChats()
        return try MessageExportBundleWriter.write(
            in: URL(fileURLWithPath: parentDirectory, isDirectory: true),
            directoryName: "WhatsApp \(format.fileExtension.uppercased()) Export"
        ) { exportDirectory in
            for (index, chat) in chats.enumerated() {
                try cancellationCheck?()
                try onProgress?(index, chats.count, chat.displayName)
                let path = exportDirectory.appendingPathComponent(
                    chat.exportFilename(format: format, includeChatID: true)
                ).path
                try exportChat(
                    chatId: chat.id,
                    format: format,
                    to: path,
                    options: options,
                    cancellationCheck: cancellationCheck
                )
            }
            try onProgress?(chats.count, chats.count, "Complete")
            return chats.count
        }
    }

    func exportAllChatsAllFormats(
        to parentDirectory: String,
        options: MessageExportOptions = MessageExportOptions(),
        onProgress: ((Int, Int, String) throws -> Void)? = nil,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> MessageExportBundleWriter.Result {
        let chats = try getChats()
        var bundleOptions = options
        bundleOptions.includeAttachments = true
        return try MessageExportBundleWriter.write(
            in: URL(fileURLWithPath: parentDirectory, isDirectory: true),
            directoryName: "WhatsApp Export"
        ) { rootDirectory in
            for (index, chat) in chats.enumerated() {
                try cancellationCheck?()
                try onProgress?(index, chats.count, chat.displayName)
                let folderName = (chat.exportFilename(format: .html, includeChatID: true) as NSString)
                    .deletingPathExtension
                let conversationDirectory = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
                try FileManager.default.createDirectory(at: conversationDirectory, withIntermediateDirectories: true)
                let messages = filtered(try getMessages(chatId: chat.id), options: bundleOptions)
                let attachmentsDirectory = conversationDirectory.appendingPathComponent("Attachments", isDirectory: true)
                let attachmentMap = try stageMedia(
                    messages: messages,
                    to: attachmentsDirectory,
                    cancellationCheck: cancellationCheck
                )
                if attachmentMap.isEmpty {
                    try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                }
                for format in MessageExportFormat.allCases {
                    try cancellationCheck?()
                    try exportMessages(
                        messages,
                        title: chat.displayName,
                        format: format,
                        to: conversationDirectory.appendingPathComponent(
                            chat.exportFilename(format: format, includeChatID: false)
                        ).path,
                        options: bundleOptions,
                        attachmentMap: attachmentMap,
                        cancellationCheck: cancellationCheck
                    )
                }
            }
            try onProgress?(chats.count, chats.count, "Complete")
            return chats.count
        }
    }

    func exportMessages(
        _ messages: [WAMessage],
        title: String,
        format: MessageExportFormat,
        to path: String,
        options: MessageExportOptions = MessageExportOptions(),
        attachmentMap providedAttachmentMap: [String: String]? = nil,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        let finalURL = URL(fileURLWithPath: path)
        let prepareAttachments: (() throws -> MessageAttachmentExporter.Generation)? = providedAttachmentMap == nil
            ? { [self] in
                try prepareMediaGeneration(
                    messages: messages,
                    beside: path,
                    includeAttachments: options.includeAttachments,
                    cancellationCheck: cancellationCheck
                )
            }
            : nil
        try MessageExportTransaction.write(
            to: finalURL,
            attachmentMap: providedAttachmentMap ?? [:],
            prepareAttachments: prepareAttachments
        ) { stagedURL, attachmentMap in
            switch format {
            case .csv:
                try exportCSV(messages: messages, title: title, to: stagedURL.path, cancellationCheck: cancellationCheck)
            case .txt:
                try exportTXT(messages: messages, title: title, to: stagedURL.path, cancellationCheck: cancellationCheck)
            case .pdf:
                try exportPDF(messages: messages, title: title, to: stagedURL.path, attachmentMap: attachmentMap, cancellationCheck: cancellationCheck)
            case .html:
                try exportHTML(messages: messages, title: title, to: stagedURL.path, attachmentMap: attachmentMap, cancellationCheck: cancellationCheck)
            case .json:
                try exportJSON(messages: messages, title: title, to: stagedURL.path, cancellationCheck: cancellationCheck)
            case .mbox:
                try exportMbox(messages: messages, title: title, to: stagedURL.path, attachmentMap: attachmentMap, cancellationCheck: cancellationCheck)
            }
        }
    }

    // MARK: - Private

    private func filtered(_ messages: [WAMessage], options: MessageExportOptions) -> [WAMessage] {
        messages.filter { message in
            if let startDate = options.startDate, message.date < startDate { return false }
            if let endDate = options.endDate, message.date > endDate { return false }
            return true
        }
    }

    private func mediaItems(for messages: [WAMessage]) -> [MessageAttachmentExporter.Item] {
        messages.compactMap { message in
            guard let localPath = message.mediaLocalPath,
                  let sourcePath = resolveMediaDiskPath(localPath) else { return nil }
            let displayName = (localPath as NSString).lastPathComponent.isEmpty
                ? "WhatsApp Media-\(message.id)"
                : (localPath as NSString).lastPathComponent
            return MessageAttachmentExporter.Item(
                key: String(message.id),
                displayName: displayName,
                sourcePath: sourcePath
            )
        }
    }

    private func prepareMediaGeneration(
        messages: [WAMessage],
        beside path: String,
        includeAttachments: Bool,
        cancellationCheck: (() throws -> Void)?
    ) throws -> MessageAttachmentExporter.Generation {
        try MessageAttachmentExporter.prepareGeneration(
            includeAttachments ? mediaItems(for: messages) : [],
            beside: path,
            cancellationCheck: cancellationCheck
        )
    }

    private func stageMedia(
        messages: [WAMessage],
        to directory: URL,
        cancellationCheck: (() throws -> Void)?
    ) throws -> [String: String] {
        try MessageAttachmentExporter.export(
            mediaItems(for: messages),
            to: directory,
            cancellationCheck: cancellationCheck
        )
    }

    private func resolveMediaDiskPath(_ localPath: String) -> String? {
        if let cached = mediaPathCache[localPath] { return cached }
        if missingMediaPaths.contains(localPath) { return nil }
        guard let manifest, let selectedSource = source else { return nil }

        let normalized = localPath
            .replacingOccurrences(of: "file://", with: "")
            .replacingOccurrences(of: "/private/var/mobile/Containers/Shared/AppGroup/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filename = (normalized as NSString).lastPathComponent
        let candidates = ((try? manifest.search(filename)) ?? []).filter {
            $0.isFile
                && selectedSource.domains.contains($0.domain)
                && $0.fileName == filename
        }
        let exactEntry = candidates.first {
            $0.relativePath == normalized || normalized.hasSuffix("/\($0.relativePath)")
        }
        let ranked = candidates.map { candidate in
            (entry: candidate, score: Self.commonPathSuffixLength(candidate.relativePath, normalized))
        }.sorted { $0.score > $1.score }
        let bestSuffixEntry: BackupManifest.FileEntry? = {
            guard let first = ranked.first, first.score >= 2 else { return nil }
            guard ranked.dropFirst().first?.score != first.score else { return nil }
            return first.entry
        }()
        let entry = exactEntry ?? bestSuffixEntry ?? (candidates.count == 1 ? candidates[0] : nil)
        guard let entry, let path = try? manifest.readablePath(for: entry),
              FileManager.default.fileExists(atPath: path) else {
            missingMediaPaths.insert(localPath)
            return nil
        }
        mediaPathCache[localPath] = path
        return path
    }

    private static func commonPathSuffixLength(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        var count = 0
        while count < min(left.count, right.count),
              left[left.count - 1 - count] == right[right.count - 1 - count] {
            count += 1
        }
        return count
    }

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

    private func exportCSV(messages: [WAMessage], title: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        var csv = "Date,Sender,Text,Media Type\n"
        for msg in messages {
            try cancellationCheck?()
            let sender = msg.isFromMe ? "Me" : (msg.senderJid ?? "Unknown")
            csv += CSVExport.row([msg.formattedDate, sender, msg.displayText, msg.mediaTypeLabel])
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportTXT(messages: [WAMessage], title: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        var lines = "WhatsApp Chat: \(title)\n"
        lines += "Exported by Phosphor\n"
        lines += String(repeating: "-", count: 60) + "\n\n"
        for msg in messages {
            try cancellationCheck?()
            let sender = msg.isFromMe ? "Me" : (msg.senderJid ?? "Unknown")
            lines += "[\(msg.formattedDate)] \(sender):\n\(msg.displayText)\n\n"
        }
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportPDF(messages: [WAMessage], title: String, to path: String, attachmentMap: [String: String], cancellationCheck: (() throws -> Void)? = nil) throws {
        let entries = try messages.map { msg in
            try cancellationCheck?()
            let relativePath = attachmentMap[String(msg.id)]
            let absolutePath = relativePath.map {
                URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent($0).path
            }
            let attachments: [PDFTranscriptWriter.Attachment] = relativePath.map { _ in
                [.init(summary: (msg.mediaLocalPath as NSString?)?.lastPathComponent ?? msg.mediaTypeLabel,
                       imagePath: (msg.mediaType == 1 || msg.mediaType == 9 || msg.mediaType == 15) ? absolutePath : nil)]
            } ?? []
            return PDFTranscriptWriter.Entry(
                title: msg.isFromMe ? "Me" : (msg.senderJid ?? "Unknown"),
                subtitle: msg.formattedDate,
                timestamp: msg.date,
                body: msg.displayText,
                isFromMe: msg.isFromMe,
                attachments: attachments
            )
        }
        try PDFTranscriptWriter.write(
            title: title,
            subtitle: "WhatsApp export • Exported by Phosphor • \(Date().shortString) • \(messages.count) messages",
            entries: entries,
            to: path
        )
    }

    private func exportHTML(messages: [WAMessage], title: String, to path: String, attachmentMap: [String: String], cancellationCheck: (() throws -> Void)? = nil) throws {
        var html = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="UTF-8">
        <title>\(title.htmlEscaped) - WhatsApp Export</title>
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
        <h1>\(title.htmlEscaped)</h1><div class="chat">
        """

        for msg in messages {
            try cancellationCheck?()
            let cls = msg.isFromMe ? "me" : ""
            let bubble = msg.isFromMe ? "from-me" : "from-them"
            let text = msg.displayText.htmlEscaped
                .replacingOccurrences(of: "\n", with: "<br>")

            html += "<div class=\"row \(cls)\"><div class=\"msg \(bubble)\">"
            if !msg.isFromMe, let sender = msg.senderJid {
                html += "<div class=\"sender\">\(sender.htmlEscaped)</div>"
            }
            if msg.mediaType != 0 {
                html += "<span class=\"media\">\(text)</span>"
                if let relativePath = attachmentMap[String(msg.id)] {
                    let href = MessageAttachmentExporter.relativeURL(for: relativePath).htmlEscaped
                    html += "<br><a href=\"\(href)\">Open original attachment</a>"
                }
            } else {
                html += text
            }
            html += "<div class=\"time\">\(msg.formattedDate)</div></div></div>\n"
        }

        html += "</div></body></html>"
        try html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportMbox(
        messages: [WAMessage],
        title: String,
        to path: String,
        attachmentMap: [String: String],
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        let crlf = "\r\n"
        let envelopeFormatter = DateFormatter()
        envelopeFormatter.locale = Locale(identifier: "en_US_POSIX")
        envelopeFormatter.timeZone = TimeZone(identifier: "UTC")
        envelopeFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let headerFormatter = DateFormatter()
        headerFormatter.locale = Locale(identifier: "en_US_POSIX")
        headerFormatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let transcriptURL = URL(fileURLWithPath: path)
        var output = ""

        for message in messages {
            try cancellationCheck?()
            let sender = message.isFromMe ? "Me" : (message.senderJid ?? "Unknown")
            let relativePath = attachmentMap[String(message.id)]
            let attachmentURL = relativePath.map {
                transcriptURL.deletingLastPathComponent().appendingPathComponent($0)
            }
            let attachmentData = attachmentURL.flatMap { try? Data(contentsOf: $0) }
            let attachmentName = attachmentURL?.lastPathComponent ?? "WhatsApp Media"

            output += "From phosphor@localhost \(envelopeFormatter.string(from: message.date))\(crlf)"
            output += "Date: \(headerFormatter.string(from: message.date))\(crlf)"
            output += "From: \(mboxHeaderValue(sender)) <phosphor@localhost>\(crlf)"
            output += "Subject: \(mboxHeaderValue("WhatsApp - \(title)"))\(crlf)"
            output += "Message-ID: <whatsapp-\(message.id)@phosphor.local>\(crlf)"
            output += "MIME-Version: 1.0\(crlf)"

            if let attachmentData {
                let boundary = "----=_Phosphor_WhatsApp_\(message.id)_\(UUID().uuidString)"
                output += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)\(crlf)"
                output += "--\(boundary)\(crlf)"
                output += "Content-Type: text/plain; charset=UTF-8\(crlf)"
                output += "Content-Transfer-Encoding: 8bit\(crlf)\(crlf)"
                output += mboxEscape(message.displayText) + crlf + crlf
                output += "--\(boundary)\(crlf)"
                output += "Content-Type: \(mediaMIMEType(message.mediaType, filename: attachmentName)); name=\"\(mboxHeaderValue(attachmentName))\"\(crlf)"
                output += "Content-Disposition: attachment; filename=\"\(mboxHeaderValue(attachmentName))\"\(crlf)"
                output += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
                output += attachmentData.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                output += crlf + "--\(boundary)--\(crlf)\(crlf)"
            } else {
                output += "Content-Type: text/plain; charset=UTF-8\(crlf)"
                output += "Content-Transfer-Encoding: 8bit\(crlf)\(crlf)"
                var body = message.displayText
                if relativePath != nil { body += "\n\n[Attachment unavailable: \(attachmentName)]" }
                output += mboxEscape(body) + crlf + crlf
            }
        }
        try output.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func mboxEscape(_ body: String) -> String {
        body.components(separatedBy: "\n").map {
            $0.hasPrefix("From ") ? ">" + $0 : $0
        }.joined(separator: "\r\n")
    }

    private func mboxHeaderValue(_ raw: String) -> String {
        let sanitized = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        guard !sanitized.allSatisfy({ $0.isASCII }) else { return sanitized }
        return "=?UTF-8?B?\(Data(sanitized.utf8).base64EncodedString())?="
    }

    private func mediaMIMEType(_ mediaType: Int, filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "ogg", "opus": return "audio/ogg"
        case "pdf": return "application/pdf"
        default:
            switch mediaType {
            case 1, 9, 15: return "image/jpeg"
            case 2: return "video/mp4"
            case 3: return "audio/mpeg"
            default: return "application/octet-stream"
            }
        }
    }

    private func exportJSON(messages: [WAMessage], title: String, to path: String, cancellationCheck: (() throws -> Void)? = nil) throws {
        let entries: [[String: Any]] = try messages.map { msg in
            try cancellationCheck?()
            return [
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
