import Foundation

enum UnifiedSearchExporter {
    private static func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    static func ordered(_ results: [UnifiedSearchResult]) -> [UnifiedSearchResult] {
        results.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case (let left?, let right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.source.rawValue != rhs.source.rawValue {
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                if lhs.title != rhs.title {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.sourceID < rhs.sourceID
            }
        }
    }

    static func csvData(results: [UnifiedSearchResult]) -> Data {
        var output = "Source,Title,Subtitle,Snippet,Date\n"
        for result in ordered(results) {
            output += CSVExport.row([
                result.source.label,
                result.title,
                result.subtitle,
                result.snippet,
                iso8601(result.date),
            ])
        }
        return Data(output.utf8)
    }

    static func jsonData(results: [UnifiedSearchResult]) throws -> Data {
        let payload = ordered(results).map { result in
            [
                "source": result.source.rawValue,
                "title": result.title,
                "subtitle": result.subtitle,
                "snippet": result.snippet,
                "date": iso8601(result.date),
            ]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    static func writeCSV(results: [UnifiedSearchResult], to url: URL) throws {
        try csvData(results: results).write(to: url, options: .atomic)
    }

    static func writeJSON(results: [UnifiedSearchResult], to url: URL) throws {
        try jsonData(results: results).write(to: url, options: .atomic)
    }
}
