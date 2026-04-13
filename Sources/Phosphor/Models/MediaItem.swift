import Foundation

/// Represents a photo or video from Camera Roll backup.
struct MediaItem: Identifiable, Hashable {
    let id: String // file hash
    let filename: String
    let relativePath: String
    let size: Int
    let domain: String
    let mediaType: MediaType

    enum MediaType: String, Hashable {
        case photo
        case video
        case livePhoto
        case screenshot
        case unknown

        var sfSymbol: String {
            switch self {
            case .photo: return "photo"
            case .video: return "video"
            case .livePhoto: return "livephoto.play"
            case .screenshot: return "rectangle.dashed"
            case .unknown: return "doc"
            }
        }
    }

    var sizeString: String {
        size.formattedFileSize
    }

    var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }

    static func mediaType(for filename: String) -> MediaType {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "tiff", "gif", "webp", "bmp":
            if filename.lowercased().contains("screenshot") {
                return .screenshot
            }
            return .photo
        case "mov", "mp4", "m4v", "avi":
            return .video
        default:
            return .unknown
        }
    }
}

/// Represents a call log entry.
struct CallLogEntry: Identifiable, Hashable {
    let id: Int
    let address: String // phone number
    let date: Date
    let duration: TimeInterval
    let callType: CallType
    let countryCode: String?

    enum CallType: Int, Hashable {
        case incoming = 1
        case outgoing = 2
        case missed = 3
        case blocked = 5

        var label: String {
            switch self {
            case .incoming: return "Incoming"
            case .outgoing: return "Outgoing"
            case .missed: return "Missed"
            case .blocked: return "Blocked"
            }
        }

        var sfSymbol: String {
            switch self {
            case .incoming: return "phone.arrow.down.left"
            case .outgoing: return "phone.arrow.up.right"
            case .missed: return "phone.down"
            case .blocked: return "phone.badge.xmark"
            }
        }
    }

    var durationString: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// Represents a voice memo.
struct VoiceMemo: Identifiable, Hashable {
    let id: String
    let filename: String
    let date: Date?
    let duration: TimeInterval?
    let size: Int
    let relativePath: String
}

/// Represents a note from Apple Notes.
struct NoteEntry: Identifiable, Hashable {
    let id: Int
    let title: String
    let snippet: String
    let createdDate: Date?
    let modifiedDate: Date?
    let folderName: String?
}
