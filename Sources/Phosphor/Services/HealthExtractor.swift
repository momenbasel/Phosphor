import Foundation

/// Extracts Apple Health data from iOS backup.
///
/// Health data is stored in HealthDomain/Library/Health/healthdb_secure.sqlite
/// Key tables: samples, quantity_samples, category_samples, workout_events
final class HealthExtractor {

    private let db: SQLiteReader

    struct HealthSample: Identifiable, Hashable {
        let id: Int
        let dataType: String
        let value: Double
        let unit: String
        let startDate: Date
        let endDate: Date
        let sourceName: String

        var formattedValue: String {
            if unit == "count" { return "\(Int(value))" }
            if unit == "count/min" { return String(format: "%.0f BPM", value) }
            if unit == "%" { return String(format: "%.0f%%", value * 100) }
            if unit == "m" && value > 1000 { return String(format: "%.1f km", value / 1000) }
            if unit == "kcal" { return String(format: "%.0f kcal", value) }
            if unit == "kg" { return String(format: "%.1f kg", value) }
            if unit == "cm" { return String(format: "%.1f cm", value) }
            if unit == "ms" { return String(format: "%.0f ms", value) }
            return String(format: "%.2f %@", value, unit)
        }
    }

    struct Workout: Identifiable, Hashable {
        let id: Int
        let activityType: Int
        let duration: TimeInterval
        let totalEnergyBurned: Double?
        let totalDistance: Double?
        let startDate: Date
        let endDate: Date
        let sourceName: String

        var activityName: String {
            let mapping: [Int: String] = [
                1: "Walking", 2: "Running", 3: "Cycling", 4: "Swimming",
                5: "Hiking", 6: "Yoga", 7: "Dance", 13: "Strength Training",
                16: "Elliptical", 20: "Functional Training", 24: "High Intensity Interval Training",
                35: "Cooldown", 37: "Core Training", 46: "Rowing",
                50: "Other", 52: "Walking", 63: "Mixed Cardio"
            ]
            return mapping[activityType] ?? "Workout (\(activityType))"
        }

        var durationString: String {
            let minutes = Int(duration) / 60
            let hours = minutes / 60
            let mins = minutes % 60
            if hours > 0 { return "\(hours)h \(mins)m" }
            return "\(mins)m"
        }
    }

    struct DailyAggregate: Identifiable, Hashable {
        let id: String
        let date: Date
        let dataType: String
        let totalValue: Double
        let avgValue: Double
        let minValue: Double
        let maxValue: Double
        let sampleCount: Int
        let unit: String
    }

    init(databasePath: String) throws {
        self.db = try SQLiteReader(path: databasePath)
    }

    convenience init(backupPath: String) throws {
        let manifest = try BackupManifest(backupPath: backupPath)
        let candidates = try manifest.search("healthdb_secure.sqlite")
        guard let entry = candidates.first(where: { $0.isFile }) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "healthdb_secure.sqlite not found in backup"])
        }

        let filePath = entry.diskPath(backupRoot: backupPath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Health database file not found on disk"])
        }

        try self.init(databasePath: filePath)
    }

    // MARK: - Data Types

    func getAvailableDataTypes() throws -> [(type: String, count: Int)] {
        let sql = """
            SELECT
                dt.data_type as type_name,
                COUNT(*) as sample_count
            FROM samples s
            JOIN data_type dt ON s.data_type = dt.ROWID
            GROUP BY dt.data_type
            ORDER BY sample_count DESC
        """
        let rows = try db.query(sql)
        return rows.compactMap { row -> (String, Int)? in
            guard let type = row["type_name"] as? String,
                  let count = row["sample_count"] as? Int else { return nil }
            return (type, count)
        }
    }

    // MARK: - Samples

    func getSamples(dataType: String, limit: Int = 1000) throws -> [HealthSample] {
        let sql = """
            SELECT
                s.ROWID,
                dt.data_type,
                qs.quantity,
                u.unit_string,
                s.start_date,
                s.end_date,
                COALESCE(src.name, '') as source_name
            FROM samples s
            JOIN data_type dt ON s.data_type = dt.ROWID
            LEFT JOIN quantity_samples qs ON qs.data_id = s.data_id
            LEFT JOIN unit_strings u ON qs.original_unit = u.ROWID
            LEFT JOIN source_devices sd ON s.source_id = sd.ROWID
            LEFT JOIN sources src ON sd.source_id = src.ROWID
            WHERE dt.data_type = ?
            ORDER BY s.start_date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: [dataType])
        return rows.compactMap { row -> HealthSample? in
            guard let rowId = row["ROWID"] as? Int else { return nil }

            let startDate: Date
            if let ts = row["start_date"] as? Double {
                startDate = Date(timeIntervalSinceReferenceDate: ts)
            } else {
                startDate = .distantPast
            }

            let endDate: Date
            if let ts = row["end_date"] as? Double {
                endDate = Date(timeIntervalSinceReferenceDate: ts)
            } else {
                endDate = startDate
            }

            return HealthSample(
                id: rowId,
                dataType: (row["data_type"] as? String) ?? dataType,
                value: (row["quantity"] as? Double) ?? 0,
                unit: (row["unit_string"] as? String) ?? "",
                startDate: startDate,
                endDate: endDate,
                sourceName: (row["source_name"] as? String) ?? ""
            )
        }
    }

    // MARK: - Workouts

    func getWorkouts(limit: Int = 500) throws -> [Workout] {
        let sql = """
            SELECT
                s.ROWID,
                w.activity_type,
                w.duration,
                w.total_energy_burned,
                w.total_distance,
                s.start_date,
                s.end_date,
                COALESCE(src.name, '') as source_name
            FROM workouts w
            JOIN samples s ON w.data_id = s.data_id
            LEFT JOIN source_devices sd ON s.source_id = sd.ROWID
            LEFT JOIN sources src ON sd.source_id = src.ROWID
            ORDER BY s.start_date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> Workout? in
            guard let rowId = row["ROWID"] as? Int else { return nil }

            let startDate = (row["start_date"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) } ?? .distantPast
            let endDate = (row["end_date"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) } ?? startDate

            return Workout(
                id: rowId,
                activityType: (row["activity_type"] as? Int) ?? 50,
                duration: (row["duration"] as? Double) ?? 0,
                totalEnergyBurned: row["total_energy_burned"] as? Double,
                totalDistance: row["total_distance"] as? Double,
                startDate: startDate,
                endDate: endDate,
                sourceName: (row["source_name"] as? String) ?? ""
            )
        }
    }

    // MARK: - Export

    func exportSamples(dataType: String, to path: String) throws {
        let samples = try getSamples(dataType: dataType, limit: 50000)
        var csv = "Date,Value,Unit,Source\n"
        for s in samples {
            csv += "\"\(s.startDate.shortString)\",\(s.value),\"\(s.unit)\",\"\(s.sourceName)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func exportWorkouts(to path: String) throws {
        let workouts = try getWorkouts(limit: 10000)
        var csv = "Date,Activity,Duration,Energy (kcal),Distance (m),Source\n"
        for w in workouts {
            csv += "\"\(w.startDate.shortString)\",\"\(w.activityName)\",\"\(w.durationString)\","
            csv += "\(w.totalEnergyBurned ?? 0),\(w.totalDistance ?? 0),\"\(w.sourceName)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func exportAll(to directory: String) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var count = 0

        // Export workouts
        let workoutsPath = (directory as NSString).appendingPathComponent("workouts.csv")
        try exportWorkouts(to: workoutsPath)
        count += 1

        // Export each data type
        let types = try getAvailableDataTypes()
        for (type, _) in types.prefix(20) {
            let safeName = type
                .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            let path = (directory as NSString).appendingPathComponent("\(safeName).csv")
            try exportSamples(dataType: type, to: path)
            count += 1
        }

        return count
    }
}
