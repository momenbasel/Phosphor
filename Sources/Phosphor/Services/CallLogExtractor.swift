import Foundation

/// Extracts call history from iOS backup call_history.db.
///
/// Stored in HomeDomain/Library/CallHistoryDB/CallHistory.storedata
/// Table: ZCALLRECORD
final class CallLogExtractor {

    private let db: SQLiteReader

    init(databasePath: String) throws {
        self.db = try SQLiteReader(path: databasePath)
    }

    convenience init(backupPath: String) throws {
        let manifest = try BackupManifest(backupPath: backupPath)

        // Try modern CallHistory.storedata first
        let candidates = try manifest.search("CallHistory.storedata")
        if let entry = candidates.first(where: { $0.isFile }) {
            let filePath = entry.diskPath(backupRoot: backupPath)
            if FileManager.default.fileExists(atPath: filePath) {
                try self.init(databasePath: filePath)
                return
            }
        }

        // Try legacy call_history.db
        let legacy = try manifest.search("call_history.db")
        if let entry = legacy.first(where: { $0.isFile }) {
            let filePath = entry.diskPath(backupRoot: backupPath)
            if FileManager.default.fileExists(atPath: filePath) {
                try self.init(databasePath: filePath)
                return
            }
        }

        throw NSError(domain: "Phosphor", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "Call history database not found in backup"])
    }

    // MARK: - Query

    func getCallLog(limit: Int = 5000) throws -> [CallLogEntry] {
        let tables = try db.tableNames()

        if tables.contains("ZCALLRECORD") {
            return try getModernCallLog(limit: limit)
        } else if tables.contains("call") {
            return try getLegacyCallLog(limit: limit)
        }

        return []
    }

    private func getModernCallLog(limit: Int) throws -> [CallLogEntry] {
        let sql = """
            SELECT
                Z_PK,
                ZADDRESS,
                ZDATE,
                ZDURATION,
                ZCALLTYPE,
                ZISO_COUNTRY_CODE
            FROM ZCALLRECORD
            ORDER BY ZDATE DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> CallLogEntry? in
            guard let pk = row["Z_PK"] as? Int,
                  let address = row["ZADDRESS"] as? String else { return nil }

            let date: Date
            if let ts = row["ZDATE"] as? Double {
                date = Date(timeIntervalSinceReferenceDate: ts)
            } else if let ts = row["ZDATE"] as? Int {
                date = Date(timeIntervalSinceReferenceDate: TimeInterval(ts))
            } else {
                date = .distantPast
            }

            let duration = (row["ZDURATION"] as? Double) ?? (row["ZDURATION"] as? Int).map(TimeInterval.init) ?? 0
            let rawType = (row["ZCALLTYPE"] as? Int) ?? 1

            return CallLogEntry(
                id: pk,
                address: address,
                date: date,
                duration: duration,
                callType: CallLogEntry.CallType(rawValue: rawType) ?? .incoming,
                countryCode: row["ZISO_COUNTRY_CODE"] as? String
            )
        }
    }

    private func getLegacyCallLog(limit: Int) throws -> [CallLogEntry] {
        let sql = """
            SELECT ROWID, address, date, duration, flags
            FROM call
            ORDER BY date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> CallLogEntry? in
            guard let rowId = row["ROWID"] as? Int,
                  let address = row["address"] as? String else { return nil }

            let timestamp = (row["date"] as? Int) ?? 0
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let duration = (row["duration"] as? Double) ?? (row["duration"] as? Int).map(TimeInterval.init) ?? 0
            let flags = (row["flags"] as? Int) ?? 1

            // Legacy flags: 4=incoming, 5=outgoing
            let callType: CallLogEntry.CallType
            switch flags {
            case 4: callType = .incoming
            case 5: callType = .outgoing
            default: callType = .incoming
            }

            return CallLogEntry(
                id: rowId,
                address: address,
                date: date,
                duration: duration,
                callType: callType,
                countryCode: nil
            )
        }
    }

    // MARK: - Export

    func exportCSV(to path: String) throws {
        let calls = try getCallLog()
        var csv = "Date,Number,Type,Duration\n"
        for call in calls {
            csv += "\"\(call.date.shortString)\",\"\(call.address)\",\"\(call.callType.label)\",\"\(call.durationString)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Stats

    func getStats() throws -> (total: Int, incoming: Int, outgoing: Int, missed: Int, totalDuration: TimeInterval) {
        let calls = try getCallLog()
        let incoming = calls.filter { $0.callType == .incoming }.count
        let outgoing = calls.filter { $0.callType == .outgoing }.count
        let missed = calls.filter { $0.callType == .missed }.count
        let duration = calls.reduce(0.0) { $0 + $1.duration }
        return (calls.count, incoming, outgoing, missed, duration)
    }
}
