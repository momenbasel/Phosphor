import Foundation

/// Extracts Safari bookmarks and history from iOS backup.
///
/// Bookmarks: HomeDomain/Library/Safari/Bookmarks.db
/// History: HomeDomain/Library/Safari/History.db
final class SafariExtractor {

    struct Bookmark: Identifiable, Hashable {
        let id: Int
        let title: String
        let url: String
        let parentTitle: String
        let orderIndex: Int

        var displayTitle: String {
            title.isEmpty ? url : title
        }
    }

    struct HistoryItem: Identifiable, Hashable {
        let id: Int
        let url: String
        let title: String
        let visitCount: Int
        let lastVisitDate: Date?

        var displayTitle: String {
            title.isEmpty ? url : title
        }

        var formattedDate: String {
            lastVisitDate?.shortString ?? "Unknown"
        }
    }

    private let backupPath: String

    init(backupPath: String) {
        self.backupPath = backupPath
    }

    // MARK: - Bookmarks

    func getBookmarks() throws -> [Bookmark] {
        let manifest = try BackupManifest(backupPath: backupPath)
        let candidates = try manifest.search("Bookmarks.db")
        guard let entry = candidates.first(where: {
            $0.isFile && $0.relativePath.contains("Safari") && $0.relativePath.hasSuffix("Bookmarks.db")
        }) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Safari Bookmarks.db not found"])
        }

        let filePath = entry.diskPath(backupRoot: backupPath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Bookmarks database file not found on disk"])
        }

        let db = try SQLiteReader(path: filePath)
        let sql = """
            SELECT
                b.id,
                b.title,
                b.url,
                b.order_index,
                COALESCE(p.title, '') as parent_title
            FROM bookmarks b
            LEFT JOIN bookmarks p ON b.parent = p.id
            WHERE b.url IS NOT NULL AND b.url != ''
            ORDER BY b.parent, b.order_index
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> Bookmark? in
            guard let bookmarkId = row["id"] as? Int else { return nil }
            return Bookmark(
                id: bookmarkId,
                title: (row["title"] as? String) ?? "",
                url: (row["url"] as? String) ?? "",
                parentTitle: (row["parent_title"] as? String) ?? "Bookmarks",
                orderIndex: (row["order_index"] as? Int) ?? 0
            )
        }
    }

    // MARK: - History

    func getHistory(limit: Int = 5000) throws -> [HistoryItem] {
        let manifest = try BackupManifest(backupPath: backupPath)
        let candidates = try manifest.search("History.db")
        guard let entry = candidates.first(where: {
            $0.isFile && $0.relativePath.contains("Safari") && $0.relativePath.hasSuffix("History.db")
        }) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Safari History.db not found"])
        }

        let filePath = entry.diskPath(backupRoot: backupPath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "History database file not found on disk"])
        }

        let db = try SQLiteReader(path: filePath)
        let sql = """
            SELECT
                hi.id,
                hi.url,
                COALESCE(hi.title, '') as title,
                hi.visit_count,
                hv.visit_time
            FROM history_items hi
            LEFT JOIN (
                SELECT history_item, MAX(visit_time) as visit_time
                FROM history_visits
                GROUP BY history_item
            ) hv ON hv.history_item = hi.id
            ORDER BY hv.visit_time DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> HistoryItem? in
            guard let itemId = row["id"] as? Int,
                  let url = row["url"] as? String else { return nil }

            let lastVisit: Date?
            if let ts = row["visit_time"] as? Double {
                // Safari stores visit_time as seconds since 2001-01-01 (Core Data epoch)
                lastVisit = Date(timeIntervalSinceReferenceDate: ts)
            } else {
                lastVisit = nil
            }

            return HistoryItem(
                id: itemId,
                url: url,
                title: (row["title"] as? String) ?? "",
                visitCount: (row["visit_count"] as? Int) ?? 1,
                lastVisitDate: lastVisit
            )
        }
    }

    // MARK: - Export

    func exportBookmarks(to path: String) throws {
        let bookmarks = try getBookmarks()
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Safari Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
        """

        var currentFolder = ""
        for bookmark in bookmarks {
            if bookmark.parentTitle != currentFolder {
                if !currentFolder.isEmpty { html += "</DL><p>\n" }
                html += "<DT><H3>\(bookmark.parentTitle)</H3>\n<DL><p>\n"
                currentFolder = bookmark.parentTitle
            }
            html += "<DT><A HREF=\"\(bookmark.url)\">\(bookmark.displayTitle)</A>\n"
        }

        html += "</DL><p>\n</DL><p>"
        try html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func exportHistory(to path: String, format: MessageExportFormat = .csv) throws {
        let history = try getHistory()
        switch format {
        case .csv:
            var csv = "Title,URL,Visit Count,Last Visit\n"
            for item in history {
                let title = item.title.replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\"\(title)\",\"\(item.url)\",\(item.visitCount),\"\(item.formattedDate)\"\n"
            }
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
        case .json:
            let entries = history.map { item -> [String: Any] in
                [
                    "title": item.title,
                    "url": item.url,
                    "visit_count": item.visitCount,
                    "last_visit": item.lastVisitDate?.iso8601String ?? ""
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: ["history": entries], options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: path))
        default:
            var text = "Safari Browsing History\nExported by Phosphor\n\n"
            for item in history {
                text += "[\(item.formattedDate)] \(item.displayTitle)\n  \(item.url)\n\n"
            }
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
