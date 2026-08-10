import Foundation

enum BackupComparisonError: LocalizedError {
    case sameBackup
    case differentDevices
    case backupInProgress
    case invalidChronology

    var errorDescription: String? {
        switch self {
        case .sameBackup:
            return "Choose two different backups to compare."
        case .differentDevices:
            return "Backups must belong to the same device before they can be compared."
        case .backupInProgress:
            return "Wait for the active backup to finish before comparing snapshots."
        case .invalidChronology:
            return "Choose an older dated snapshot on the left and a newer snapshot on the right."
        }
    }
}

enum BackupComparisonService {
    static func compare(older: BackupInfo, newer: BackupInfo) throws -> BackupComparisonResult {
        let olderIdentity = try filesystemIdentity(for: older.path)
        let newerIdentity = try filesystemIdentity(for: newer.path)
        guard olderIdentity != newerIdentity else { throw BackupComparisonError.sameBackup }
        guard !older.udid.isEmpty, older.udid == newer.udid else {
            throw BackupComparisonError.differentDevices
        }
        guard let olderDate = older.lastBackupDate,
              let newerDate = newer.lastBackupDate,
              olderDate < newerDate else {
            throw BackupComparisonError.invalidChronology
        }
        guard let operationToken = BackupOperationCoordinator.shared.beginComparison() else {
            throw BackupComparisonError.backupInProgress
        }
        defer { BackupOperationCoordinator.shared.endComparison(operationToken) }

        let olderManifest = try BackupManifest(backupPath: older.path)
        let newerManifest = try BackupManifest(backupPath: newer.path)
        let olderCursor = try olderManifest.makeComparisonCursor()
        let newerCursor = try newerManifest.makeComparisonCursor()
        return try BackupComparisonEngine.compareOrdered(
            nextOlder: { try olderCursor.next() },
            nextNewer: { try newerCursor.next() }
        )
    }

    private struct FilesystemIdentity: Equatable {
        let canonicalPath: String
        let volumeIdentifier: String?
        let fileResourceIdentifier: String?

        static func == (lhs: FilesystemIdentity, rhs: FilesystemIdentity) -> Bool {
            if lhs.canonicalPath == rhs.canonicalPath { return true }
            guard let lhsVolume = lhs.volumeIdentifier,
                  let rhsVolume = rhs.volumeIdentifier,
                  let lhsFile = lhs.fileResourceIdentifier,
                  let rhsFile = rhs.fileResourceIdentifier else { return false }
            return lhsVolume == rhsVolume && lhsFile == rhsFile
        }
    }

    private static func filesystemIdentity(for path: String) throws -> FilesystemIdentity {
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ])
        guard values.isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return FilesystemIdentity(
            canonicalPath: url.path,
            volumeIdentifier: values.volumeIdentifier.map(String.init(describing:)),
            fileResourceIdentifier: values.fileResourceIdentifier.map(String.init(describing:))
        )
    }
}
