import Foundation

/// Represents an iMessage/SMS conversation.
struct MessageChat: Identifiable, Hashable {
    let id: Int
    let chatIdentifier: String
    let displayName: String
    /// Raw handle identifiers (phone numbers / emails) for every participant.
    let participants: [String]
    /// Title resolved against the Contacts directory when available.
    /// Falls back to display name, then to a "Name, Name, ..." join of participants,
    /// and finally to the raw chat identifier.
    let resolvedTitle: String
    let lastMessageDate: Date?
    let messageCount: Int
    let isGroupChat: Bool

    var title: String {
        resolvedTitle.isEmpty ? chatIdentifier : resolvedTitle
    }

    /// Keeps the resolved contact/group name in exported filenames while bulk
    /// exports retain the chat ID suffix that prevents same-name collisions.
    func exportFilename(format: MessageExportFormat, includeChatID: Bool) -> String {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let contactName = String(sanitized.prefix(80))
        let baseName = contactName.isEmpty ? "Conversation" : contactName
        let chatIDSuffix = includeChatID ? "-chat-\(id)" : ""
        return "\(baseName)\(chatIDSuffix).\(format.fileExtension)"
    }
}

/// Represents a single message within a conversation.
struct Message: Identifiable, Hashable {
    let id: Int // ROWID from message table
    let guid: String
    let text: String?
    let date: Date
    let isFromMe: Bool
    let handleId: String // phone number or email
    let senderName: String // resolved display name (Me, contact name, or handleId)
    let service: String // iMessage, SMS
    let hasAttachment: Bool
    let attachments: [MessageAttachment]
    let isRead: Bool
    let reactions: [Reaction]
    /// iMessage inline-reply target GUIDs. Modern iOS backups may populate
    /// `reply_to_guid`; older thread metadata often uses `thread_originator_guid`.
    let replyToGuid: String?
    let threadOriginatorGuid: String?
    let threadOriginatorPart: String?
    /// URL extracted from a rich-link preview balloon (`com.apple.messages.URLBalloonProvider`).
    let linkURL: String?
    let balloonBundleID: String?

    var attachmentFilename: String? { attachments.first?.filename }
    var attachmentMimeType: String? { attachments.first?.mimeType }

    var displayText: String {
        if let text, !text.isEmpty { return text }
        if !attachments.isEmpty { return "[Attachment]" }
        if linkURL != nil { return linkURL ?? "[Link]" }
        return "[Empty message]"
    }

    var senderLabel: String {
        isFromMe ? "Me" : (senderName.isEmpty ? handleId : senderName)
    }

    var formattedDate: String {
        date.shortString
    }

    /// Convert CoreData/Apple NSDate timestamp to Date.
    /// Apple stores dates as seconds since 2001-01-01 (NSDate reference), sometimes in nanoseconds.
    static func dateFromAppleTimestamp(_ timestamp: Int) -> Date {
        // If timestamp is in nanoseconds (> 1 billion), convert
        let seconds: TimeInterval
        if timestamp > 1_000_000_000_000 {
            seconds = TimeInterval(timestamp) / 1_000_000_000.0
        } else {
            seconds = TimeInterval(timestamp)
        }
        // Apple epoch is 2001-01-01 00:00:00 UTC
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

/// Represents a message attachment.
struct MessageAttachment: Identifiable, Hashable {
    let id: Int
    let guid: String
    let filename: String?
    let mimeType: String?
    let transferName: String?
    let totalBytes: Int

    var displayName: String {
        transferName ?? filename.map { ($0 as NSString).lastPathComponent } ?? "Attachment"
    }

    /// Plugin payloads (`*.pluginPayloadAttachment`) are binary plists that back
    /// rich-link / Apple Pay / Memoji balloons. They have no end-user meaning on
    /// macOS so we hide them from the bubble UI and skip them on export.
    var isPluginPayload: Bool {
        let ext = (filename ?? transferName ?? "").lowercased()
        return ext.hasSuffix(".pluginpayloadattachment")
    }

    var isImage: Bool {
        if let mime = mimeType?.lowercased(), mime.hasPrefix("image/") { return true }
        let ext = ((filename ?? transferName) as NSString?)?.pathExtension.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"].contains(ext)
    }

    var isVideo: Bool {
        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") { return true }
        let ext = ((filename ?? transferName) as NSString?)?.pathExtension.lowercased() ?? ""
        return ["mp4", "mov", "m4v", "avi", "3gp"].contains(ext)
    }
}

/// One iMessage tapback applied to a target message.
struct Reaction: Identifiable, Hashable {
    let id: Int
    let type: ReactionType
    let isFromMe: Bool
    let sender: String
    let isAdd: Bool
}

/// iMessage tapback type. Raw value matches the base 2000+offset stored in
/// `message.associated_message_type`. Remove events use 3000+offset and are
/// folded into the add/remove resolution before bubbles see them.
enum ReactionType: Int, CaseIterable {
    case love = 0
    case like = 1
    case dislike = 2
    case laugh = 3
    case emphasize = 4
    case question = 5

    init?(associatedMessageType raw: Int) {
        // Add events live in 2000..2005, remove events in 3000..3005.
        let base: Int
        if raw >= 2000 && raw <= 2999 {
            base = raw - 2000
        } else if raw >= 3000 && raw <= 3999 {
            base = raw - 3000
        } else {
            return nil
        }
        self.init(rawValue: base)
    }

    var emoji: String {
        switch self {
        case .love: return "\u{2764}\u{FE0F}"
        case .like: return "\u{1F44D}"
        case .dislike: return "\u{1F44E}"
        case .laugh: return "\u{1F602}"
        case .emphasize: return "\u{203C}\u{FE0F}"
        case .question: return "\u{2753}"
        }
    }

    var label: String {
        switch self {
        case .love: return "Loved"
        case .like: return "Liked"
        case .dislike: return "Disliked"
        case .laugh: return "Laughed at"
        case .emphasize: return "Emphasized"
        case .question: return "Questioned"
        }
    }
}

/// Export format for messages.
enum MessageExportFormat: String, CaseIterable {
    case csv = "CSV"
    case txt = "Plain Text"
    case pdf = "PDF"
    case html = "HTML"
    case json = "JSON"
    case mbox = "MBOX (Mail)"

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .txt: return "txt"
        case .pdf: return "pdf"
        case .html: return "html"
        case .json: return "json"
        case .mbox: return "mbox"
        }
    }
}
