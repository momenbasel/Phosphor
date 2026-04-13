import Foundation

/// Represents an iOS backup stored on disk.
struct BackupInfo: Identifiable, Hashable {
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
    static func fromDirectory(_ path: String) -> BackupInfo? {
        let dirName = (path as NSString).lastPathComponent
        guard let info = PlistParser.parseBackupInfo(path) else { return nil }
        let status = PlistParser.parseBackupStatus(path)
        let manifest = PlistParser.parseManifest(path)
        let size = FileManager.default.directorySize(at: path)

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
            appCount: manifest?.applicationBundleIds.count ?? 0
        )
    }
}
