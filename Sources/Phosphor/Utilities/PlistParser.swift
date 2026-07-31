import Foundation

/// Parses iOS backup Info.plist and Status.plist files.
enum PlistParser {

    /// Parse a plist file at the given path.
    static func parse(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data: data)
    }

    /// Parse plist from data.
    static func parse(data: Data) -> [String: Any]? {
        do {
            let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return obj as? [String: Any]
        } catch {
            return nil
        }
    }

    /// Parse the Info.plist from an iOS backup directory.
    static func parseBackupInfo(_ backupPath: String) -> BackupInfoPlist? {
        let infoPath = (backupPath as NSString).appendingPathComponent("Info.plist")
        guard let dict = parse(infoPath) else { return nil }

        return BackupInfoPlist(
            deviceName: dict["Device Name"] as? String ?? "Unknown",
            displayName: dict["Display Name"] as? String ?? "Unknown",
            productType: dict["Product Type"] as? String ?? "",
            productVersion: dict["Product Version"] as? String ?? "",
            buildVersion: dict["Build Version"] as? String ?? "",
            serialNumber: dict["Serial Number"] as? String ?? "",
            udid: dict["Target Identifier"] as? String ?? dict["Unique Identifier"] as? String ?? "",
            iccid: dict["ICCID"] as? String,
            imei: dict["IMEI"] as? String,
            meid: dict["MEID"] as? String,
            phoneNumber: dict["Phone Number"] as? String,
            lastBackupDate: dict["Last Backup Date"] as? Date,
            isEncrypted: dict["WasPasscodeSet"] as? Bool ?? false
        )
    }

    /// Parse the Status.plist from an iOS backup directory.
    static func parseBackupStatus(_ backupPath: String) -> BackupStatusPlist? {
        let statusPath = (backupPath as NSString).appendingPathComponent("Status.plist")
        guard let dict = parse(statusPath) else { return nil }

        return BackupStatusPlist(
            isFullBackup: dict["IsFullBackup"] as? Bool ?? false,
            version: dict["Version"] as? String ?? "",
            date: dict["Date"] as? Date,
            backupState: dict["BackupState"] as? String ?? "",
            snapshotState: dict["SnapshotState"] as? String ?? ""
        )
    }

    /// Parse Manifest.plist for backup metadata.
    static func parseManifest(_ backupPath: String) -> ManifestPlist? {
        let manifestPath = (backupPath as NSString).appendingPathComponent("Manifest.plist")
        guard let dict = parse(manifestPath) else { return nil }

        let apps = dict["Applications"] as? [String: Any]
        let isEncrypted = dict["IsEncrypted"] as? Bool ?? false

        return ManifestPlist(
            isEncrypted: isEncrypted,
            applicationBundleIds: apps?.keys.sorted() ?? [],
            systemVersion: dict["SystemDomainsVersion"] as? String,
            wasPasscodeSet: dict["WasPasscodeSet"] as? Bool ?? false
        )
    }
}

struct BackupInfoPlist {
    let deviceName: String
    let displayName: String
    let productType: String
    let productVersion: String
    let buildVersion: String
    let serialNumber: String
    let udid: String
    let iccid: String?
    let imei: String?
    let meid: String?
    let phoneNumber: String?
    let lastBackupDate: Date?
    let isEncrypted: Bool

    /// Convert product type (e.g., "iPhone14,2") to human-readable name.
    var modelName: String {
        let mapping: [String: String] = [
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,5": "iPhone 13",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone18,5": "iPhone 17e",
            "iPad16,3": "iPad Pro M4 11\"",
            "iPad16,4": "iPad Pro M4 11\"",
            "iPad16,5": "iPad Pro M4 13\"",
            "iPad16,6": "iPad Pro M4 13\"",
            "iPad14,8": "iPad Air M2 11\"",
            "iPad14,9": "iPad Air M2 11\"",
            "iPad14,10": "iPad Air M2 13\"",
            "iPad14,11": "iPad Air M2 13\"",
        ]
        return mapping[productType] ?? productType
    }
}

struct BackupStatusPlist {
    let isFullBackup: Bool
    let version: String
    let date: Date?
    let backupState: String
    let snapshotState: String
}

struct ManifestPlist {
    let isEncrypted: Bool
    let applicationBundleIds: [String]
    let systemVersion: String?
    let wasPasscodeSet: Bool
}

/// Per-app metadata pulled from Manifest.plist's Applications dictionary.
/// `PlaceholderIcon` is the PNG the App Store/download placeholder used at
/// backup time — the only app icon bytes actually present in a backup.
struct BackupApplicationInfo {
    let bundleID: String
    let name: String?
    let placeholderIconData: Data?
}

extension PlistParser {
    /// Parse per-app metadata (display names + placeholder icons) from
    /// Manifest.plist. Returns an empty array when the backup has no
    /// Applications dictionary (e.g. partial/legacy backups).
    static func parseApplications(_ backupPath: String) -> [BackupApplicationInfo] {
        let manifestPath = (backupPath as NSString).appendingPathComponent("Manifest.plist")
        guard let dict = parse(manifestPath),
              let apps = dict["Applications"] as? [String: [String: Any]] else { return [] }
        return apps.map { bundleID, info in
            // App names live inside the nested iTunesMetadata plist blob
            // (itemName / bundleDisplayName), not as top-level keys.
            var name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
            if name == nil,
               let metaData = info["iTunesMetadata"] as? Data,
               let meta = parse(data: metaData) {
                name = (meta["bundleDisplayName"] as? String)
                    ?? (meta["itemName"] as? String)
                    ?? (meta["title"] as? String)
            }
            let icon = (info["PlaceholderIcon"] as? Data)
                ?? (info["PlaceholderIconData"] as? Data)
            return BackupApplicationInfo(bundleID: bundleID, name: name, placeholderIconData: icon)
        }.sorted { $0.bundleID < $1.bundleID }
    }
}
