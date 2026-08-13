import CryptoKit
import Foundation

enum BackupLocationStatus: String, Equatable, Sendable {
    case local
    case available
    case offline
    case invalid
}

enum ScheduledNetworkBackupPolicy {
    static func shouldKeepScheduleDue(for status: BackupLocationStatus) -> Bool {
        status == .offline || status == .invalid
    }
}

enum BackupLocationAvailability: Equatable, Sendable {
    case available
    case offline
    case invalid
}

struct BackupVolumeSnapshot: Equatable, Sendable {
    let mountPath: String
    let volumeUUID: String?
    let volumeName: String?
    let volumeSource: String?
    let fileSystemType: String?
    let isLocal: Bool
    let pathExists: Bool
    let isDirectory: Bool
    let isReadable: Bool
    let isWritable: Bool
    let pathResolvesWithinMount: Bool

    init(
        mountPath: String,
        volumeUUID: String?,
        volumeName: String?,
        volumeSource: String? = nil,
        fileSystemType: String? = nil,
        isLocal: Bool,
        pathExists: Bool,
        isDirectory: Bool,
        isReadable: Bool,
        isWritable: Bool,
        pathResolvesWithinMount: Bool = true
    ) {
        self.mountPath = mountPath
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.volumeSource = volumeSource
        self.fileSystemType = fileSystemType
        self.isLocal = isLocal
        self.pathExists = pathExists
        self.isDirectory = isDirectory
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.pathResolvesWithinMount = pathResolvesWithinMount
    }
}

struct BackupLocationRecord: Codable, Equatable, Sendable {
    enum RecordError: Error {
        case notRemote
        case pathOutsideVolume
        case missingIdentity
    }

    let configuredPath: String
    let mountPath: String
    let volumeUUID: String?
    let volumeName: String?
    let volumeSourceHash: String?
    let fileSystemType: String?
    let relativePath: String

    static func capture(configuredPath: String, volume: BackupVolumeSnapshot) throws -> BackupLocationRecord {
        guard !volume.isLocal else { throw RecordError.notRemote }
        let configured = standardized(configuredPath)
        let mount = standardized(volume.mountPath)
        guard configured == mount || configured.hasPrefix(mount + "/") else {
            throw RecordError.pathOutsideVolume
        }
        guard volume.pathResolvesWithinMount else { throw RecordError.pathOutsideVolume }
        let uuid = normalized(volume.volumeUUID)
        let name = normalized(volume.volumeName)
        let sourceHash = volumeSourceIdentityHash(volume.volumeSource)
        let fileSystemType = normalized(volume.fileSystemType)
        guard uuid != nil || (sourceHash != nil && fileSystemType != nil) else {
            throw RecordError.missingIdentity
        }
        let relative = configured == mount ? "" : String(configured.dropFirst(mount.count + 1))
        return BackupLocationRecord(
            configuredPath: configured,
            mountPath: mount,
            volumeUUID: uuid,
            volumeName: name,
            volumeSourceHash: sourceHash,
            fileSystemType: fileSystemType,
            relativePath: relative
        )
    }

    func matchesConfiguredPath(_ path: String) -> Bool {
        Self.standardized(path) == configuredPath
    }

    func matchesVolumeIdentity(_ volume: BackupVolumeSnapshot) -> Bool {
        let currentSourceHash = Self.volumeSourceIdentityHash(volume.volumeSource)
        if let expectedSourceHash = volumeSourceHash,
           let expectedFileSystemType = fileSystemType,
           currentSourceHash == expectedSourceHash,
           volume.fileSystemType == expectedFileSystemType {
            return true
        }
        guard let expectedUUID = volumeUUID else { return false }
        return volume.volumeUUID == expectedUUID
    }

    static func reconciled(_ record: BackupLocationRecord?, configuredPath: String) -> BackupLocationRecord? {
        guard let record, record.matchesConfiguredPath(configuredPath) else { return nil }
        return record
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.standardizedFileURLPath
    }

    fileprivate static func normalizedVolumeSource(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }

        let prefix: String
        let authorityStart: String.Index
        if value.hasPrefix("//") {
            prefix = "//"
            authorityStart = value.index(value.startIndex, offsetBy: 2)
        } else if let schemeSeparator = value.range(of: "://") {
            prefix = String(value[..<schemeSeparator.upperBound])
            authorityStart = schemeSeparator.upperBound
        } else {
            guard let at = value.lastIndex(of: "@") else { return value }
            return String(value[value.index(after: at)...])
        }

        let authorityEnd = value[authorityStart...].firstIndex(of: "/") ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return value }
        let hostStart = authority.index(after: at)
        return prefix + value[hostStart...]
    }

    private static func volumeSourceIdentityHash(_ value: String?) -> String? {
        guard let normalized = normalizedVolumeSource(value) else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum BackupLocationPathSafety {
    static func resolvesWithinMount(configuredPath: String, mountPath: String) -> Bool {
        let configured = URL(fileURLWithPath: configuredPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let mount = URL(fileURLWithPath: mountPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return configured == mount || configured.hasPrefix(mount + "/")
    }
}

enum BackupLocationClassifier {
    enum MountedVolumeResolution: Equatable, Sendable {
        case match(BackupVolumeSnapshot)
        case offline
        case invalid
    }

    static func resolveMountedVolume(
        record: BackupLocationRecord,
        volumes: [BackupVolumeSnapshot]
    ) -> MountedVolumeResolution {
        let expectedMount = standardized(record.mountPath)
        if let mountedAtExpectedPath = volumes.first(where: {
            standardized($0.mountPath) == expectedMount
        }) {
            return record.matchesVolumeIdentity(mountedAtExpectedPath)
                ? .match(mountedAtExpectedPath)
                : .invalid
        }
        return volumes.contains(where: record.matchesVolumeIdentity) ? .invalid : .offline
    }

    static func classifyUnrecorded(
        configuredPath: String,
        volume: BackupVolumeSnapshot?
    ) -> BackupLocationStatus {
        let configured = standardized(configuredPath)
        guard configured.hasPrefix("/Volumes/") else { return .local }
        guard let volume else { return .invalid }

        let mount = standardized(volume.mountPath)
        guard mount != "/",
              configured == mount || configured.hasPrefix(mount + "/") else {
            return .invalid
        }
        return volume.isLocal ? .local : .invalid
    }

    static func classify(
        configuredPath: String,
        record: BackupLocationRecord,
        volume: BackupVolumeSnapshot?
    ) -> BackupLocationAvailability {
        guard record.matchesConfiguredPath(configuredPath) else { return .invalid }
        guard let volume else { return .offline }
        guard !volume.isLocal else { return .offline }
        guard identityMatches(record: record, volume: volume) else { return .invalid }
        guard volume.pathExists,
              volume.isDirectory,
              volume.isReadable,
              volume.isWritable,
              volume.pathResolvesWithinMount else { return .invalid }
        return .available
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func identityMatches(record: BackupLocationRecord, volume: BackupVolumeSnapshot) -> Bool {
        record.matchesVolumeIdentity(volume)
    }
}

private extension String {
    var standardizedFileURLPath: String {
        URL(fileURLWithPath: self).standardizedFileURL.path
    }
}
