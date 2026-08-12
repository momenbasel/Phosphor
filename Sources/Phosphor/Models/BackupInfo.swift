import Foundation

/// Represents an iOS backup stored on disk.
struct BackupInfo: Identifiable, Hashable, Sendable {
    let id: String // backup directory name (usually UDID or UDID+timestamp)
    let path: String
    let deviceName: String
    let displayName: String
    let productType: String
    let iosVersion: String
    let serialNumber: String
    let udid: String
    let lastBackupDate: Date?
    let isEncrypted: Bool
    let isFullBackup: Bool
    let size: UInt64
    let sizeResolved: Bool
    let appCount: Int

    var modelName: String {
        BackupInfoPlist(
            deviceName: deviceName,
            displayName: displayName,
            productType: productType,
            productVersion: iosVersion,
            buildVersion: "",
            serialNumber: serialNumber,
            udid: udid,
            iccid: nil, imei: nil, meid: nil, phoneNumber: nil,
            lastBackupDate: lastBackupDate,
            isEncrypted: isEncrypted
        ).modelName
    }

    /// Short, stable discriminator. Prefer the authoritative backup UDID, then
    /// fall back to its serial or backup-folder identity for incomplete metadata.
    var shortUDID: String {
        let source = !udid.isEmpty ? udid : (!serialNumber.isEmpty ? serialNumber : id)
        guard !source.isEmpty else { return "Unknown" }
        return String(source.suffix(8))
    }

    /// Shared user-facing identity for backup lists and pickers. The identifier
    /// suffix keeps same-name, same-model backups visibly distinct without
    /// exposing a complete hardware identifier throughout the UI.
    var deviceIdentityLabel: String {
        let identifier: String
        if !udid.isEmpty {
            identifier = "ID …\(shortUDID)"
        } else if !serialNumber.isEmpty {
            identifier = "Serial …\(shortUDID)"
        } else if !id.isEmpty {
            identifier = "Backup …\(shortUDID)"
        } else {
            identifier = "Unknown device ID"
        }
        return "\(deviceName) • \(modelName) • \(identifier)"
    }

    var dateString: String {
        lastBackupDate?.shortString ?? "Unknown"
    }

    var relativeDate: String {
        lastBackupDate?.relativeString ?? "Unknown"
    }

    var sizeString: String {
        size.formattedFileSize
    }

    /// Initialize from a backup directory by parsing its plists.
    /// Size calculation recursively walks the whole backup and can be very slow
    /// for large backups, so startup discovery can skip it and fill sizes later.
    static func fromDirectory(_ path: String, includeSize: Bool = true) -> BackupInfo? {
        let dirName = (path as NSString).lastPathComponent
        guard let info = PlistParser.parseBackupInfo(path) else { return nil }
        let status = PlistParser.parseBackupStatus(path)
        let manifest = PlistParser.parseManifest(path)
        let size = includeSize ? FileManager.default.directorySize(at: path) : 0

        return BackupInfo(
            id: dirName,
            path: path,
            deviceName: info.deviceName,
            displayName: info.displayName,
            productType: info.productType,
            iosVersion: info.productVersion,
            serialNumber: info.serialNumber,
            udid: info.udid,
            lastBackupDate: info.lastBackupDate ?? status?.date,
            isEncrypted: manifest?.isEncrypted ?? info.isEncrypted,
            isFullBackup: status?.isFullBackup ?? false,
            size: size,
            sizeResolved: includeSize,
            appCount: manifest?.applicationBundleIds.count ?? 0
        )
    }

    func withSize(_ size: UInt64) -> BackupInfo {
        BackupInfo(
            id: id,
            path: path,
            deviceName: deviceName,
            displayName: displayName,
            productType: productType,
            iosVersion: iosVersion,
            serialNumber: serialNumber,
            udid: udid,
            lastBackupDate: lastBackupDate,
            isEncrypted: isEncrypted,
            isFullBackup: isFullBackup,
            size: size,
            sizeResolved: true,
            appCount: appCount
        )
    }
}
