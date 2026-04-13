import Foundation

/// Extracts calendar events from iOS backup.
/// Parses Calendar.sqlitedb (CalendarItem, Calendar tables).
final class CalendarExtractor {

    let backupPath: String
    private let manifest: BackupManifest

    struct CalendarInfo: Identifiable, Hashable {
        let id: Int
        let title: String
        let colorHex: String
        let eventCount: Int
    }

    struct CalendarEvent: Identifiable, Hashable {
        let id: Int
        let title: String
        let location: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let calendarTitle: String
        let notes: String
        let url: String

        var durationString: String {
            if isAllDay { return "All Day" }
            let duration = endDate.timeIntervalSince(startDate)
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }
    }

    init(backupPath: String) throws {
        self.backupPath = backupPath
        self.manifest = try BackupManifest(backupPath: backupPath)
    }

    // MARK: - Extraction

    /// Get all calendars from backup.
    func getCalendars() throws -> [CalendarInfo] {
        let db = try openDatabase()
        let tables = try db.tableNames()

        guard tables.contains("Calendar") else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Calendar database not found"])
        }

        let rows = try db.query("""
            SELECT c.ROWID, c.title, c.color_r, c.color_g, c.color_b,
                   (SELECT COUNT(*) FROM CalendarItem ci WHERE ci.calendar_id = c.ROWID) as event_count
            FROM Calendar c
            ORDER BY c.title
        """)

        return rows.compactMap { row -> CalendarInfo? in
            guard let rowId = row["ROWID"] as? Int,
                  let title = row["title"] as? String else { return nil }

            let r = Int((row["color_r"] as? Double) ?? 0.0 * 255)
            let g = Int((row["color_g"] as? Double) ?? 0.0 * 255)
            let b = Int((row["color_b"] as? Double) ?? 0.0 * 255)
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            let count = (row["event_count"] as? Int) ?? 0

            return CalendarInfo(id: rowId, title: title, colorHex: hex, eventCount: count)
        }
    }

    /// Get events from a specific calendar or all calendars.
    func getEvents(calendarId: Int? = nil, limit: Int = 1000) throws -> [CalendarEvent] {
        let db = try openDatabase()

        var query = """
            SELECT ci.ROWID, ci.summary, ci.location_id, ci.start_date, ci.end_date,
                   ci.all_day, ci.description, ci.url, c.title as calendar_title
            FROM CalendarItem ci
            LEFT JOIN Calendar c ON ci.calendar_id = c.ROWID
        """

        var params: [String] = []
        if let calId = calendarId {
            query += " WHERE ci.calendar_id = ?"
            params.append(String(calId))
        }
        query += " ORDER BY ci.start_date DESC LIMIT \(limit)"

        let rows = try db.query(query, params: params)

        return rows.compactMap { row -> CalendarEvent? in
            guard let rowId = row["ROWID"] as? Int,
                  let title = row["summary"] as? String else { return nil }

            // Core Data epoch: seconds since 2001-01-01
            let startInterval = (row["start_date"] as? Double) ?? 0
            let endInterval = (row["end_date"] as? Double) ?? startInterval
            let startDate = Date(timeIntervalSinceReferenceDate: startInterval)
            let endDate = Date(timeIntervalSinceReferenceDate: endInterval)

            return CalendarEvent(
                id: rowId,
                title: title,
                location: "", // Location is in separate table
                startDate: startDate,
                endDate: endDate,
                isAllDay: ((row["all_day"] as? Int) ?? 0) == 1,
                calendarTitle: (row["calendar_title"] as? String) ?? "",
                notes: (row["description"] as? String) ?? "",
                url: (row["url"] as? String) ?? ""
            )
        }
    }

    // MARK: - Export

    /// Export events as ICS (iCalendar) format with proper RFC 5545 escaping.
    func exportAsICS(events: [CalendarEvent], to path: String) throws {
        var ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Phosphor//Phosphor//EN\r\nCALSCALE:GREGORIAN\r\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        for event in events {
            ics += "BEGIN:VEVENT\r\n"
            ics += "DTSTART:\(dateFormatter.string(from: event.startDate))\r\n"
            ics += "DTEND:\(dateFormatter.string(from: event.endDate))\r\n"
            ics += "SUMMARY:\(escapeICS(event.title))\r\n"
            if !event.location.isEmpty {
                ics += "LOCATION:\(escapeICS(event.location))\r\n"
            }
            if !event.notes.isEmpty {
                ics += "DESCRIPTION:\(escapeICS(event.notes))\r\n"
            }
            ics += "END:VEVENT\r\n"
        }

        ics += "END:VCALENDAR\r\n"
        try ics.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// RFC 5545 text escaping: backslash, semicolon, comma, newlines.
    private func escapeICS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Export as CSV with proper RFC 4180 escaping.
    func exportAsCSV(events: [CalendarEvent], to path: String) throws {
        var csv = "Title,Start,End,All Day,Calendar,Location,Notes\r\n"
        for event in events {
            csv += "\(csvEscape(event.title)),\(csvEscape(event.startDate.iso8601String)),\(csvEscape(event.endDate.iso8601String)),\(event.isAllDay),\(csvEscape(event.calendarTitle)),\(csvEscape(event.location)),\(csvEscape(event.notes))\r\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// RFC 4180 CSV escaping: double-quote fields containing commas, quotes, or newlines.
    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    // MARK: - Private

    private func openDatabase() throws -> SQLiteReader {
        // Calendar.sqlitedb known hash
        let knownHash = "2041457d5fe04f8a8d0141078f3a780f24edd0a3"
        var dbPath = "\(backupPath)/\(knownHash.prefix(2))/\(knownHash)"

        if !FileManager.default.fileExists(atPath: dbPath) {
            guard let entry = try manifest.files(matching: "%Calendar.sqlitedb").first(where: { $0.domain == "HomeDomain" }) else {
                throw NSError(domain: "Phosphor", code: 404, userInfo: [NSLocalizedDescriptionKey: "Calendar database not found in backup"])
            }
            dbPath = entry.diskPath(backupRoot: backupPath)
        }

        return try SQLiteReader(path: dbPath)
    }
}
