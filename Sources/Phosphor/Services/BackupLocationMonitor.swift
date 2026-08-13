import AppKit
import Combine
import Darwin
import Foundation

struct BackupLocationPreflight: Equatable, Sendable {
    let status: BackupLocationStatus
    let message: String?

    var canWrite: Bool {
        status == .local || status == .available
    }
}

@MainActor
final class BackupLocationMonitor: ObservableObject {
    nonisolated static let recordUserDefaultsKey = "phosphor.backupDirectory.networkLocation"

    @Published private(set) var status: BackupLocationStatus = .local
    @Published private(set) var message: String?
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private let workspaceNotifications: NotificationCenter
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var started = false

    init(
        defaults: UserDefaults = .standard,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.defaults = defaults
        self.workspaceNotifications = workspaceNotifications
    }

    deinit {
        refreshTask?.cancel()
    }

    var isDesignatedNetworkLocation: Bool {
        Self.loadRecord(defaults: defaults).map {
            $0.matchesConfiguredPath(BackupManager.activeBackupDir)
        } == true
    }

    func start() {
        guard !started else {
            refresh()
            return
        }
        started = true
        Publishers.Merge(
            workspaceNotifications.publisher(for: NSWorkspace.didMountNotification),
            workspaceNotifications.publisher(for: NSWorkspace.didUnmountNotification)
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        .store(in: &cancellables)
        refresh()
    }

    func stop() {
        started = false
        cancellables.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh() {
        refresh(path: BackupManager.activeBackupDir)
    }

    func refresh(path: String) {
        refreshTask?.cancel()
        isRefreshing = true
        let record = Self.reconciledRecord(for: path, defaults: defaults)
        refreshTask = Task { [weak self] in
            let result = await Self.preflightForWrite(path: path, record: record)
            guard !Task.isCancelled, let self else { return }
            self.status = result.status
            self.message = result.message
            self.isRefreshing = false
        }
    }

    func designateCurrentPath(_ path: String) async throws {
        let record = try await Task.detached(priority: .utility) {
            guard let snapshot = try Self.snapshotForExistingPath(path) else {
                throw BackupLocationDesignationError.notMountedVolume
            }
            return try BackupLocationRecord.capture(configuredPath: path, volume: snapshot)
        }.value
        guard record.matchesConfiguredPath(BackupManager.activeBackupDir) else {
            throw BackupLocationDesignationError.pathChanged
        }
        Self.saveRecord(record, defaults: defaults)
        refresh(path: path)
    }

    func clearDesignation() {
        Self.saveRecord(nil, defaults: defaults)
        refresh()
    }

    static func backupDirectoryDidChange(
        to path: String,
        defaults: UserDefaults = .standard
    ) {
        _ = reconciledRecord(for: path, defaults: defaults)
    }

    nonisolated static func preflightForWrite(path: String) async -> BackupLocationPreflight {
        let record = loadRecord()
        return await preflightForWrite(path: path, record: record)
    }

    nonisolated static func preflightForWrite(
        path: String,
        record: BackupLocationRecord?
    ) async -> BackupLocationPreflight {
        await Task.detached(priority: .utility) {
            probe(path: path, record: record)
        }.value
    }

    nonisolated private static func probe(
        path: String,
        record: BackupLocationRecord?
    ) -> BackupLocationPreflight {
        let configured = standardized(path)
        let isVolumesPath = configured.hasPrefix("/Volumes/")

        if let record {
            guard record.matchesConfiguredPath(configured) else {
                return BackupLocationPreflight(
                    status: .invalid,
                    message: "The saved network-location identity does not match the selected backup folder. Choose the folder again in Settings."
                )
            }
            let mounted: BackupVolumeSnapshot
            switch BackupLocationClassifier.resolveMountedVolume(
                record: record,
                volumes: mountedVolumes()
            ) {
            case let .match(volume):
                mounted = volume
            case .offline:
                return BackupLocationPreflight(
                    status: .offline,
                    message: "Network Backup Location Offline. Reconnect or mount the saved network volume; Phosphor will retry when macOS reports that it is available."
                )
            case .invalid:
                return BackupLocationPreflight(
                    status: .invalid,
                    message: "A different volume is mounted at the saved network location. Choose the backup folder again before writing."
                )
            }
            guard let snapshot = try? snapshotForExistingPath(configured, mountedVolume: mounted) else {
                return BackupLocationPreflight(
                    status: .invalid,
                    message: "The network volume is mounted, but the selected backup folder is missing or inaccessible. Choose a valid folder on that volume."
                )
            }
            switch BackupLocationClassifier.classify(
                configuredPath: configured,
                record: record,
                volume: snapshot
            ) {
            case .available:
                return BackupLocationPreflight(status: .available, message: nil)
            case .offline:
                return BackupLocationPreflight(
                    status: .offline,
                    message: "Network Backup Location Offline. Reconnect or mount the saved network volume."
                )
            case .invalid:
                return BackupLocationPreflight(
                    status: .invalid,
                    message: "The selected network backup folder is not readable and writable on the saved remote volume."
                )
            }
        }

        let mounted = isVolumesPath ? bestMountedVolume(containing: configured) : nil
        switch BackupLocationClassifier.classifyUnrecorded(
            configuredPath: configured,
            volume: mounted
        ) {
        case .local:
            return BackupLocationPreflight(status: .local, message: nil)
        case .invalid where mounted == nil || standardized(mounted?.mountPath ?? "/") == "/":
            return BackupLocationPreflight(
                status: .invalid,
                message: "The selected /Volumes location is not currently mounted. Phosphor will not create a local folder in place of a missing external or network volume."
            )
        case .invalid:
            return BackupLocationPreflight(
                status: .invalid,
                message: "This folder is on a network volume. Use “Use as Network Location” in Settings before Phosphor writes backups there."
            )
        case .available, .offline:
            return BackupLocationPreflight(
                status: .invalid,
                message: "Choose the backup location again in Settings before writing."
            )
        }
    }

    nonisolated private static func reconciledRecord(
        for path: String,
        defaults: UserDefaults = .standard
    ) -> BackupLocationRecord? {
        let existing = loadRecord(defaults: defaults)
        let reconciled = BackupLocationRecord.reconciled(existing, configuredPath: path)
        if existing != nil, reconciled == nil {
            saveRecord(nil, defaults: defaults)
        }
        return reconciled
    }

    nonisolated private static func loadRecord(
        defaults: UserDefaults = .standard
    ) -> BackupLocationRecord? {
        guard let data = defaults.data(forKey: recordUserDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(BackupLocationRecord.self, from: data)
    }

    nonisolated private static func saveRecord(_ record: BackupLocationRecord?, defaults: UserDefaults) {
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: recordUserDefaultsKey)
        } else {
            defaults.removeObject(forKey: recordUserDefaultsKey)
        }
    }

    nonisolated private static func mountedVolumes() -> [BackupVolumeSnapshot] {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey,
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsLocalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let volumeURL = values.volume else { return nil }
            let identity = volumeIdentity(at: volumeURL.path)
            return BackupVolumeSnapshot(
                mountPath: volumeURL.path,
                volumeUUID: values.volumeUUIDString,
                volumeName: values.volumeName,
                volumeSource: identity.source,
                fileSystemType: identity.fileSystemType,
                isLocal: values.volumeIsLocal ?? true,
                pathExists: true,
                isDirectory: true,
                isReadable: true,
                isWritable: true,
                pathResolvesWithinMount: true
            )
        }
    }

    nonisolated private static func bestMountedVolume(containing path: String) -> BackupVolumeSnapshot? {
        mountedVolumes()
            .filter {
                let mount = standardized($0.mountPath)
                return path == mount || path.hasPrefix(mount + "/")
            }
            .max { standardized($0.mountPath).count < standardized($1.mountPath).count }
    }

    nonisolated private static func volumeIdentity(at path: String) -> (
        source: String?,
        fileSystemType: String?
    ) {
        var fileSystem = statfs()
        guard path.withCString({ statfs($0, &fileSystem) }) == 0 else {
            return (nil, nil)
        }
        let source = withUnsafePointer(to: &fileSystem.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        let fileSystemType = withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        return (normalizedIdentity(source), normalizedIdentity(fileSystemType))
    }

    nonisolated private static func normalizedIdentity(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated private static func snapshotForExistingPath(
        _ path: String,
        mountedVolume: BackupVolumeSnapshot? = nil
    ) throws -> BackupVolumeSnapshot? {
        let configured = standardized(path)
        let mounted = mountedVolume ?? bestMountedVolume(containing: configured)
        guard let mounted else { return nil }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory)
        let resolvesWithinMount = BackupLocationPathSafety.resolvesWithinMount(
            configuredPath: configured,
            mountPath: mounted.mountPath
        )
        return BackupVolumeSnapshot(
            mountPath: mounted.mountPath,
            volumeUUID: mounted.volumeUUID,
            volumeName: mounted.volumeName,
            volumeSource: mounted.volumeSource,
            fileSystemType: mounted.fileSystemType,
            isLocal: mounted.isLocal,
            pathExists: exists,
            isDirectory: isDirectory.boolValue,
            isReadable: exists && FileManager.default.isReadableFile(atPath: configured),
            isWritable: exists && FileManager.default.isWritableFile(atPath: configured),
            pathResolvesWithinMount: resolvesWithinMount
        )
    }

    nonisolated private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

enum BackupLocationDesignationError: LocalizedError {
    case notMountedVolume
    case pathChanged

    var errorDescription: String? {
        switch self {
        case .notMountedVolume:
            return "Choose an existing folder on a mounted network volume."
        case .pathChanged:
            return "The backup folder changed while Phosphor was checking it. Try again with the current folder."
        }
    }
}
