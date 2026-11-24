import Foundation

/// Represents an iOS backup stored on disk.
struct BackupInfo: Identifiable, Hashable, Sendable {
    enum HealthState: String, Hashable, Sendable {
        case complete = "Complete"
        case paused = "Paused"
        case broken = "Broken"
    }

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
    var healthState: HealthState = .complete

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

    /// Clear, state-specific timestamp description for idle backup rows.
    var statusTimestampDescription: String {
        guard let lastBackupDate else { return "Unknown date" }
        let prefix: String = switch healthState {
        case .complete: "Completed"
        case .paused: "Last saved"
        case .broken: "Interrupted"
        }
        return "\(prefix) \(lastBackupDate.shortString) (\(lastBackupDate.relativeString))"
    }

    var sizeString: String {
        size.formattedFileSize
    }

    /// True when this backup folder is a timestamped historical archive
    /// (e.g., `<UDID>-phosphor-bkp-YYYYMMDD-HHmmss` or Finder `<UDID>-YYYYMMDD-HHmmss`)
    /// rather than the primary mutable `<UDID>` slot.
    var isArchivedSnapshot: Bool {
        guard !udid.isEmpty, !id.isEmpty else { return false }
        return id != udid
    }

    /// Concise status suffix for backup selector menus across Data tabs and Snapshot Comparison.
    var pickerStatusSuffix: String {
        switch (isArchivedSnapshot, healthState) {
        case (true, .complete):
            return " • Archived"
        case (true, .paused):
            return " • Archived (Paused)"
        case (true, .broken):
            return " • Archived (Broken)"
        case (false, .paused):
            return " • Paused"
        case (false, .broken):
            return " • Broken"
        case (false, .complete):
            return ""
        }
    }

    /// Deterministic 3-state health classification:
    /// - `.complete`: Manifest metadata exists, payload buckets (`00`..`ff`) exist at root, no unpromoted `Snapshot/`, and `SnapshotState == "finished"`.
    /// - `.paused`: Payload files exist in `00`..`ff` or `Snapshot/`, and backup is awaiting resumption (`Snapshot/` exists or `SnapshotState != "finished"`).
    /// - `.broken`: Metadata files exist (`Info.plist` / `Manifest.db`), but zero payload files exist in `00`..`ff` or `Snapshot/`.
    static func computeHealthState(at path: String, snapshotState: String? = nil) -> HealthState {
        let manifestDb = (path as NSString).appendingPathComponent("Manifest.db")
        let manifestPlist = (path as NSString).appendingPathComponent("Manifest.plist")
        let fm = FileManager.default
        let hasManifest = (fm.fileExists(atPath: manifestDb) && ((try? fm.attributesOfItem(atPath: manifestDb)[.size] as? UInt64) ?? 0) > 0) ||
                          (fm.fileExists(atPath: manifestPlist) && ((try? fm.attributesOfItem(atPath: manifestPlist)[.size] as? UInt64) ?? 0) > 0)
        let hasRootPayload = BackupManager.backupRootHasPayloadData(path)
        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var isSnapshotDir: ObjCBool = false
        let hasSnapshotDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isSnapshotDir) && isSnapshotDir.boolValue
        let hasSnapshotPayload = hasSnapshotDir && BackupManager.backupRootHasPayloadData(snapshotPath)
        let hasAnyPayload = hasRootPayload || hasSnapshotPayload

        let resolvedSnapshotState: String? = {
            if let snapshotState { return snapshotState }
            let statusPath = (path as NSString).appendingPathComponent("Status.plist")
            guard let data = fm.contents(atPath: statusPath),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                return nil
            }
            return plist["SnapshotState"] as? String
        }()

        // If Snapshot/ directory exists with SnapshotState == "uploading", it is an in-progress/paused snapshot, not broken
        if hasSnapshotDir && resolvedSnapshotState?.lowercased() == "uploading" {
            return .paused
        }

        guard hasAnyPayload else { return .broken }
        guard hasManifest else { return .paused }

        if hasSnapshotPayload {
            return .paused
        }

        guard let resolvedSnapshotState else {
            return hasRootPayload ? .paused : .broken
        }
        return (hasRootPayload && resolvedSnapshotState.lowercased() == "finished") ? .complete : .paused
    }

    /// Whether this backup has sealed metadata and completed snapshot files.
    var isComplete: Bool {
        healthState == .complete
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
        let health = computeHealthState(at: path, snapshotState: status?.snapshotState)

        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        let snapshotManifestDbPath = (path as NSString).appendingPathComponent("Snapshot/Manifest.db")
        let statusPlistPath = (path as NSString).appendingPathComponent("Status.plist")
        let infoPlistPath = (path as NSString).appendingPathComponent("Info.plist")
        let fm = FileManager.default
        let diskModDate: Date? = [manifestDbPath, snapshotManifestDbPath, statusPlistPath, infoPlistPath]
            .compactMap { (try? fm.attributesOfItem(atPath: $0)[.modificationDate]) as? Date }
            .max()
        let now = Date()
        let sanitizePlistDate: (Date?) -> Date? = { candidate in
            guard let candidate else { return nil }
            // If a plist date was serialized with a future timezone offset (e.g. +1h ahead of local wall clock),
            // prefer the actual filesystem modification date on disk or clamp to `now`.
            if candidate > now.addingTimeInterval(60) {
                if let diskModDate, diskModDate <= now.addingTimeInterval(60) {
                    return diskModDate
                }
                return now
            }
            return candidate
        }
        let resolvedDate: Date? = {
            if let infoDate = sanitizePlistDate(info.lastBackupDate) { return infoDate }
            // If Status.plist is a pre-handshake "BackupState = new" stub from an aborted run,
            // prefer Manifest.db's modification date over the aborted attempt timestamp.
            if status?.backupState.lowercased() == "new", let diskModDate {
                return diskModDate
            }
            return sanitizePlistDate(status?.date) ?? diskModDate
        }()

        return BackupInfo(
            id: dirName,
            path: path,
            deviceName: info.deviceName,
            displayName: info.displayName,
            productType: info.productType,
            iosVersion: info.productVersion,
            serialNumber: info.serialNumber,
            udid: info.udid,
            lastBackupDate: resolvedDate,
            isEncrypted: manifest?.isEncrypted ?? info.isEncrypted,
            isFullBackup: status?.isFullBackup ?? false,
            size: size,
            sizeResolved: includeSize,
            appCount: manifest?.applicationBundleIds.count ?? info.appCount,
            healthState: health
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
            appCount: appCount,
            healthState: healthState
        )
    }
}
