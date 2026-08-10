import Foundation

enum UnifiedSearchSource: String, CaseIterable, Codable, Hashable, Sendable {
    case messages
    case whatsApp
    case notes
    case contacts
    case callLog
    case safari
    case files

    var label: String {
        switch self {
        case .messages: return "Messages"
        case .whatsApp: return "WhatsApp"
        case .notes: return "Notes"
        case .contacts: return "Contacts"
        case .callLog: return "Call Log"
        case .safari: return "Safari"
        case .files: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "message.fill"
        case .whatsApp: return "bubble.left.and.text.bubble.right.fill"
        case .notes: return "note.text"
        case .contacts: return "person.crop.circle"
        case .callLog: return "phone"
        case .safari: return "safari"
        case .files: return "doc.text.magnifyingglass"
        }
    }
}

struct UnifiedSearchResult: Identifiable, Hashable, Sendable {
    let source: UnifiedSearchSource
    let sourceID: String
    let title: String
    let subtitle: String
    let snippet: String
    let date: Date?

    var id: String { "\(source.rawValue):\(sourceID)" }
}

struct UnifiedSearchResponse: Sendable {
    let results: [UnifiedSearchResult]
    let sourceErrors: [UnifiedSearchSource: String]
}
