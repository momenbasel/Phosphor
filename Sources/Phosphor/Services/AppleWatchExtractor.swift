import Foundation

/// Extracts Apple Watch data from a paired iPhone's backup.
/// Watch data lives within the iPhone backup in several locations:
/// - HomeDomain/Library/DeviceRegistry/ contains paired device metadata
/// - Domains containing "NanoUniverse" or "nano" for Watch-specific data
/// - HealthDomain stores Watch-synced health data
/// - WatchKit app extension domains for Watch app data
final class AppleWatchExtractor {

    let backupPath: String
    private let manifest: BackupManifest

    struct WatchInfo: Identifiable, Hashable {
        let id: String // UDID or serial
        let name: String
        let model: String
        let osVersion: String
        let serialNumber: String
        let pairedDate: Date?
        let lastSync: Date?
    }

    struct WatchApp: Identifiable, Hashable {
        let id: String // bundle ID
        let bundleId: String
        let name: String
        let domain: String
        let fileCount: Int
        let totalSize: UInt64
    }

    struct WatchActivitySummary: Identifiable {
        let id = UUID()
        let date: Date
        let moveCalories: Double
        let exerciseMinutes: Double
        let standHours: Double
        let moveGoal: Double
        let exerciseGoal: Double
        let standGoal: Double
    }

    init(backupPath: String) throws {
        self.backupPath = backupPath
        self.manifest = try BackupManifest(backupPath: backupPath)
    }

    // MARK: - Watch Discovery

    /// Find paired Apple Watch info from backup.
    func getPairedWatches() -> [WatchInfo] {
        var watches: [WatchInfo] = []

        // Method 1: Parse DeviceRegistry plist
        if let entries = try? manifest.files(matching: "%DeviceRegistry%") {
            // Look for NanoPairedDevices or similar plists
            for entry in entries where entry.relativePath.contains("NanoPaired") || entry.relativePath.hasSuffix(".plist") {
                if let info = parseWatchPlist(entry) {
                    watches.append(info)
                }
            }
        }

        // Method 2: Search for nano-related domains
        if watches.isEmpty, let domains = try? manifest.domains() {
            let nanoDomains = domains.filter {
                $0.lowercased().contains("nano") ||
                $0.lowercased().contains("watch") ||
                $0.contains("com.apple.NanoUniverse")
            }

            if !nanoDomains.isEmpty {
                // We found Watch-related domains - there's a paired Watch
                watches.append(WatchInfo(
                    id: "paired-watch",
                    name: "Apple Watch",
                    model: detectWatchModel(from: nanoDomains),
                    osVersion: "Unknown",
                    serialNumber: "",
                    pairedDate: nil,
                    lastSync: nil
                ))
            }
        }

        // Method 3: Check for Watch health data
        if watches.isEmpty {
            if let healthFiles = try? manifest.files(matching: "%healthdb%"),
               healthFiles.contains(where: { $0.relativePath.contains("Watch") || $0.domain.contains("Health") }) {
                // Health data from Watch exists
                watches.append(WatchInfo(
                    id: "health-watch",
                    name: "Apple Watch",
                    model: "Unknown",
                    osVersion: "Unknown",
                    serialNumber: "",
                    pairedDate: nil,
                    lastSync: nil
                ))
            }
        }

        return watches
    }

    // MARK: - Watch Apps

    /// List WatchKit extension apps from backup.
    func getWatchApps() -> [WatchApp] {
        guard let domains = try? manifest.domains() else { return [] }

        var apps: [WatchApp] = []

        for domain in domains {
            // WatchKit extensions are in AppDomain-com.app.watchkitextension
            // or AppDomainGroup domains containing "watchkit"
            let isWatchApp = domain.lowercased().contains("watchkit") ||
                             domain.lowercased().contains("watch") && domain.contains("AppDomain")

            guard isWatchApp else { continue }

            // Extract bundle ID from domain
            let bundleId: String
            if domain.hasPrefix("AppDomain-") {
                bundleId = String(domain.dropFirst("AppDomain-".count))
            } else if domain.hasPrefix("AppDomainGroup-") {
                bundleId = String(domain.dropFirst("AppDomainGroup-".count))
            } else {
                bundleId = domain
            }

            let files = (try? manifest.files(inDomain: domain)) ?? []
            let totalSize = files.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.size)) }

            // Derive display name from bundle ID
            let name = bundleId
                .components(separatedBy: ".")
                .last?
                .replacingOccurrences(of: "watchkitextension", with: "")
                .replacingOccurrences(of: "watchkitapp", with: "")
                .capitalized ?? bundleId

            apps.append(WatchApp(
                id: bundleId,
                bundleId: bundleId,
                name: name,
                domain: domain,
                fileCount: files.filter(\.isFile).count,
                totalSize: totalSize
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Activity Rings

    /// Extract Activity ring summaries from Health database.
    func getActivitySummaries() -> [WatchActivitySummary] {
        // Primary: search manifest for healthdb_secure
        if let entry = try? manifest.files(matching: "%healthdb_secure%").first {
            let path = entry.diskPath(backupRoot: backupPath)
            if FileManager.default.fileExists(atPath: path) {
                return loadActivityFromDB(path)
            }
        }

        // Fallback: known hash (may vary between iOS versions)
        let knownHashes = [
            "cc61d40c8de1653f24ef0e0dd4e7e08abab7ff42",
            "6a3a8e5c6e3b8e1d2f4a0c9b7e5d3f1a8c6b4e2d"
        ]
        for hash in knownHashes {
            let dbPath = "\(backupPath)/\(hash.prefix(2))/\(hash)"
            if FileManager.default.fileExists(atPath: dbPath) {
                return loadActivityFromDB(dbPath)
            }
        }

        return []
    }

    private func loadActivityFromDB(_ dbPath: String) -> [WatchActivitySummary] {
        guard let db = try? SQLiteReader(path: dbPath) else { return [] }

        // Activity summaries are in activity_caches or similar tables
        let tables = (try? db.tableNames()) ?? []
        let activityTable = tables.first { $0.lowercased().contains("activity") && $0.lowercased().contains("cache") }

        guard let tableName = activityTable else { return [] }

        let rows = (try? db.query(
            "SELECT * FROM \(tableName) ORDER BY date_components DESC LIMIT 365"
        )) ?? []

        return rows.compactMap { row -> WatchActivitySummary? in
            let moveGoal = (row["active_energy_burned_goal"] as? Double) ?? 0
            let move = (row["active_energy_burned"] as? Double) ?? 0
            let exercise = (row["apple_exercise_time"] as? Double) ?? 0
            let stand = (row["apple_stand_hours"] as? Double) ?? 0

            // Parse date from date_components (encoded as integer YYYYMMDD or similar)
            let dateVal = (row["date_components"] as? Int) ?? 0
            let date: Date
            if dateVal > 20000000 {
                let year = dateVal / 10000
                let month = (dateVal % 10000) / 100
                let day = dateVal % 100
                var components = DateComponents()
                components.year = year
                components.month = month
                components.day = day
                date = Calendar.current.date(from: components) ?? Date()
            } else {
                date = Date(timeIntervalSinceReferenceDate: TimeInterval(dateVal))
            }

            return WatchActivitySummary(
                date: date,
                moveCalories: move,
                exerciseMinutes: exercise,
                standHours: stand,
                moveGoal: moveGoal > 0 ? moveGoal : 500,
                exerciseGoal: 30,
                standGoal: 12
            )
        }
    }

    // MARK: - Extract Watch Data

    /// Extract all Watch-related files from backup.
    func extractWatchData(to destination: String) throws -> Int {
        guard let domains = try? manifest.domains() else { return 0 }

        let watchDomains = domains.filter {
            $0.lowercased().contains("watch") ||
            $0.lowercased().contains("nano") ||
            $0.lowercased().contains("watchkit")
        }

        var extracted = 0
        let fm = FileManager.default

        for domain in watchDomains {
            let domainDir = (destination as NSString).appendingPathComponent(domain)
            try fm.createDirectory(atPath: domainDir, withIntermediateDirectories: true)

            let files = (try? manifest.files(inDomain: domain)) ?? []
            for file in files where file.isFile {
                let destPath = (domainDir as NSString).appendingPathComponent(file.fileName)
                do {
                    try manifest.extractFile(file, to: destPath)
                    extracted += 1
                } catch {
                    continue
                }
            }
        }

        return extracted
    }

    // MARK: - Helpers

    private func parseWatchPlist(_ entry: BackupManifest.FileEntry) -> WatchInfo? {
        let diskPath = entry.diskPath(backupRoot: backupPath)
        guard FileManager.default.fileExists(atPath: diskPath),
              let data = FileManager.default.contents(atPath: diskPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let name = (plist["DeviceName"] as? String) ?? (plist["Name"] as? String) ?? "Apple Watch"
        let model = (plist["ProductType"] as? String) ?? (plist["ModelNumber"] as? String) ?? "Unknown"
        let serial = (plist["SerialNumber"] as? String) ?? ""
        let osVersion = (plist["ProductVersion"] as? String) ?? (plist["WatchOSVersion"] as? String) ?? "Unknown"
        let udid = (plist["UDID"] as? String) ?? serial

        return WatchInfo(
            id: udid.isEmpty ? UUID().uuidString : udid,
            name: name,
            model: watchModelName(from: model),
            osVersion: osVersion,
            serialNumber: serial,
            pairedDate: plist["PairingDate"] as? Date,
            lastSync: plist["LastSyncDate"] as? Date
        )
    }

    private func detectWatchModel(from domains: [String]) -> String {
        // Try to infer Watch model from domain data
        if domains.contains(where: { $0.contains("Ultra") }) { return "Apple Watch Ultra" }
        return "Apple Watch"
    }

    private func watchModelName(from productType: String) -> String {
        let mapping: [String: String] = [
            "Watch7,1": "Apple Watch Ultra 2",
            "Watch7,2": "Apple Watch Ultra 2",
            "Watch7,3": "Apple Watch Series 10 (42mm)",
            "Watch7,4": "Apple Watch Series 10 (46mm)",
            "Watch7,5": "Apple Watch SE (2024)",
            "Watch6,18": "Apple Watch Ultra",
            "Watch6,14": "Apple Watch Series 9 (41mm)",
            "Watch6,15": "Apple Watch Series 9 (45mm)",
            "Watch6,16": "Apple Watch SE 2 (40mm)",
            "Watch6,17": "Apple Watch SE 2 (44mm)",
            "Watch6,6": "Apple Watch Series 8 (41mm)",
            "Watch6,7": "Apple Watch Series 8 (45mm)",
            "Watch6,1": "Apple Watch Series 7 (41mm)",
            "Watch6,2": "Apple Watch Series 7 (45mm)",
        ]
        return mapping[productType] ?? productType
    }
}
