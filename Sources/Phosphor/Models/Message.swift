import Foundation

/// Represents an iMessage/SMS conversation.
struct MessageChat: Identifiable, Hashable {
    let id: Int
    let chatIdentifier: String
    let displayName: String
    let lastMessageDate: Date?
    let messageCount: Int
    let isGroupChat: Bool

    var title: String {
        if !displayName.isEmpty { return displayName }
        return chatIdentifier
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
    let service: String // iMessage, SMS
    let hasAttachment: Bool
    let attachmentFilename: String?
    let attachmentMimeType: String?
    let isRead: Bool

    var displayText: String {
        text ?? (hasAttachment ? "[Attachment]" : "[Empty message]")
    }

    var senderLabel: String {
        isFromMe ? "Me" : handleId
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
        transferName ?? filename ?? "Attachment"
    }
}

/// Export format for messages.
enum MessageExportFormat: String, CaseIterable {
    case csv = "CSV"
    case txt = "Plain Text"
    case html = "HTML"
    case json = "JSON"

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .txt: return "txt"
        case .html: return "html"
        case .json: return "json"
        }
    }
}
