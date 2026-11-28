import Foundation
import SQLite3

extension BackupManager {

    /// True when the backup root directory itself contains payload files in 2-hex-character buckets (00-ff).
    nonisolated static func backupRootHasPayloadData(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return false }
        for entry in entries {
            if entry.count == 2 || entry.count == 40 {
                let subPath = (path as NSString).appendingPathComponent(entry)
                var st = stat()
                if stat(subPath, &st) == 0 {
                    let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                    if isDir {
                        // Fast O(1) check on APFS/HFS+: st_nlink > 2 means directory has children
                        if st.st_nlink > 2 {
                            return true
                        }
                        if let enumerator = fm.enumerator(at: URL(fileURLWithPath: subPath), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]),
                           enumerator.nextObject() != nil {
                            return true
                        }
                    } else if st.st_size > 0 {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// True when the incomplete backup folder contains real payload data (hashed directories/files).
    nonisolated static func incompleteBackupHasPayloadData(_ path: String) -> Bool {
        if backupRootHasPayloadData(path) {
            return true
        }

        // MobileBackup2 / pymobiledevice3 stores in-flight files in a 'Snapshot/' subdirectory before promotion
        let fm = FileManager.default
        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var isSnapshotDir: ObjCBool = false
        if fm.fileExists(atPath: snapshotPath, isDirectory: &isSnapshotDir), isSnapshotDir.boolValue {
            if backupRootHasPayloadData(snapshotPath) {
                return true
            }
        }

        return false
    }

    /// Prepares an existing backup directory for a new backup run by checking profile/exclusion
    /// compatibility (`inferFromExistingBackup`), snapshotting via APFS CoW (`cloneBackupSnapshot`)
    /// when incremental-compatible, or archiving (`archiveExistingBackup`) before a full backup.
    /// Returns `true` when the upcoming backup should run in incremental mode.
    nonisolated static func prepareExistingBackupForRun(
        udid: String,
        in directory: String? = nil,
        wantsIncremental: Bool,
        configuration: DeviceBackupConfiguration
    ) -> Bool {
        let root = directory ?? activeBackupDir
        if wantsIncremental {
            let existingConfig = DeviceBackupConfiguration.inferFromExistingBackup(udid: udid, in: root)
            let isCompatible = existingConfig.map { configuration.isCompatibleForIncremental(with: $0) } ?? true
            if isCompatible {
                _ = cloneBackupSnapshot(for: udid, in: root)
                return true
            } else {
                _ = archiveExistingBackup(for: udid, in: root)
                return false
            }
        } else if hasExistingBackup(for: udid, in: root) {
            _ = archiveExistingBackup(for: udid, in: root)
        }
        return false
    }

    // MARK: - Non-Destructive Metadata Rollback Guard & Quarantine

    /// Path to the hidden in-flight metadata guard directory (`<BackupRoot>/.<UDID>-phosphor-guard-bkp`).
    nonisolated static func metadataGuardPath(for udid: String, in directory: String? = nil) -> String {
        let root = directory ?? activeBackupDir
        return (root as NSString).appendingPathComponent(".\(udid)-phosphor-guard-bkp")
    }

    /// True when a directory name in `<BackupRoot>` is an internal guard or quarantine directory
    /// that must be skipped by `discoverBackups`.
    nonisolated static func isAuxiliaryBackupDirectoryName(_ itemName: String) -> Bool {
        if itemName.hasPrefix(".") { return true }
        if itemName.contains("-phosphor-guard-bkp") { return true }
        if itemName.contains("-phosphor-quarantine-bkp-") { return true }
        if itemName.contains("-phosphor-broken-bkp-") { return true }
        return false
    }

    /// Snapshots valid non-empty root metadata files (`Info.plist`, `Status.plist`, `Manifest.plist`)
    /// into `<BackupRoot>/.<UDID>-phosphor-guard-bkp` before a backup or resume subprocess starts.
    /// Never overwrites an already-staged valid guard file with a 0-byte or unparseable file.
    @discardableResult
    nonisolated static func stageMetadataGuard(for udid: String, in directory: String? = nil) -> Bool {
        let fm = FileManager.default
        let root = directory ?? activeBackupDir
        let targetDir = backupPath(for: udid, in: root)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetDir, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let guardDir = metadataGuardPath(for: udid, in: root)
        let metadataFiles = ["Info.plist", "Status.plist", "Manifest.plist"]
        var stagedAny = false

        for fileName in metadataFiles {
            let srcPath = (targetDir as NSString).appendingPathComponent(fileName)
            guard isNonEmptyFile(srcPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: srcPath)),
                  (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
                continue
            }
            if !fm.fileExists(atPath: guardDir) {
                try? fm.createDirectory(atPath: guardDir, withIntermediateDirectories: true)
            }
            let dstPath = (guardDir as NSString).appendingPathComponent(fileName)
            try? fm.removeItem(atPath: dstPath)
            if (try? fm.copyItem(atPath: srcPath, toPath: dstPath)) != nil {
                stagedAny = true
            }
        }
        return stagedAny
    }

    /// Restores clobbered or zero-byte root metadata files (`Info.plist`, `Status.plist`, `Manifest.plist`)
    /// from `<BackupRoot>/.<UDID>-phosphor-guard-bkp` when a backup or resume subprocess fails or aborts
    /// before completing (e.g., `MBErrorDomain/208 Device locked`).
    @discardableResult
    nonisolated static func restoreMetadataGuardIfNeeded(for udid: String, in directory: String? = nil) -> Int {
        let fm = FileManager.default
        let root = directory ?? activeBackupDir
        let targetDir = backupPath(for: udid, in: root)
        let guardDir = metadataGuardPath(for: udid, in: root)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: guardDir, isDirectory: &isDir), isDir.boolValue,
              fm.fileExists(atPath: targetDir, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }

        let snapshotPath = (targetDir as NSString).appendingPathComponent("Snapshot")
        let hasActiveSnapshot = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue
        var restoredCount = 0

        for fileName in ["Manifest.plist", "Status.plist", "Info.plist"] {
            let guardFile = (guardDir as NSString).appendingPathComponent(fileName)
            guard isNonEmptyFile(guardFile) else { continue }
            let targetFile = (targetDir as NSString).appendingPathComponent(fileName)

            let targetValid: Bool = {
                guard isNonEmptyFile(targetFile),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: targetFile)),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                    return false
                }
                // If pymobiledevice3 --full overwrote Status.plist with a pre-handshake "BackupState = new" stub
                // and no Snapshot/ directory was created before aborting, treat Status.plist as clobbered.
                if fileName == "Status.plist",
                   !hasActiveSnapshot,
                   (plist["BackupState"] as? String)?.lowercased() == "new" {
                    return false
                }
                return true
            }()

            if !targetValid {
                try? fm.removeItem(atPath: targetFile)
                if (try? fm.copyItem(atPath: guardFile, toPath: targetFile)) != nil {
                    restoredCount += 1
                }
            }
        }
        // Once target plists are verified or restored and no Snapshot/ staging is active,
        // remove the temporary guard folder so it never lingers as an orphan on disk.
        if !hasActiveSnapshot && looksLikeBackupFolder(targetDir) {
            try? fm.removeItem(atPath: guardDir)
        }
        return restoredCount
    }

    /// Removes `<BackupRoot>/.<UDID>-phosphor-guard-bkp` once a backup finishes and passes verification.
    nonisolated static func commitMetadataGuard(for udid: String, in directory: String? = nil) {
        let guardDir = metadataGuardPath(for: udid, in: directory)
        try? FileManager.default.removeItem(atPath: guardDir)
    }

    /// Moves a broken backup folder out of the active `<UDID>` slot by renaming it to
    /// `<BackupRoot>/<UDID>-phosphor-broken-bkp-<yyyyMMdd-HHmmss>` so no user data is deleted
    /// and a clean repair backup can run without collision.
    @discardableResult
    nonisolated static func quarantineBrokenBackup(at path: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let parentDir = (path as NSString).deletingLastPathComponent
        let dirName = (path as NSString).lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let quarantineName = "\(dirName)-phosphor-broken-bkp-\(timestamp)"
        let quarantinePath = (parentDir as NSString).appendingPathComponent(quarantineName)

        do {
            try fm.moveItem(atPath: path, toPath: quarantinePath)
            commitMetadataGuard(for: dirName, in: parentDir)
            return quarantinePath
        } catch {
            return nil
        }
    }

    struct IncompleteBackupStats {
        let fileCount: Int
        let totalBytes: UInt64
        let lastModified: Date?

        var formattedSize: String {
            totalBytes.formattedFileSize
        }

        var relativeTimeDescription: String {
            guard let lastModified else { return "recently" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: lastModified, relativeTo: Date())
        }

        /// Calculate completion percentage against target device used storage.
        /// Returns nil if device storage capacity is unknown (retrocompatible).
        func completionFraction(for device: DeviceInfo?) -> Double? {
            guard let device else { return nil }
            // If device total & available disk space are reported from lockdown
            if let total = device.totalDiskCapacity, let available = device.availableDiskSpace, total > available {
                let used = total - available
                if used > 0 {
                    let fraction = Double(totalBytes) / Double(used)
                    return min(max(fraction, 0.01), 0.99)
                }
            }
            // Fallback to totalDataCapacity if available
            if let totalData = device.totalDataCapacity, totalData > 0 {
                let fraction = Double(totalBytes) / Double(totalData)
                return min(max(fraction, 0.01), 0.99)
            }
            return nil
        }

        /// Calculate remaining payload bytes against target device used storage.
        /// Returns nil if device storage capacity is unknown.
        func remainingBytes(for device: DeviceInfo?) -> UInt64? {
            guard let device else { return nil }
            if let total = device.totalDiskCapacity, let available = device.availableDiskSpace, total > available {
                let used = total - available
                return used > totalBytes ? (used - totalBytes) : 0
            }
            if let totalData = device.totalDataCapacity, totalData > totalBytes {
                return totalData - totalBytes
            }
            return nil
        }

        /// Estimated time to resume remaining data based on connection type.
        /// USB ~35 MB/s, Wi-Fi ~10 MB/s. Returns nil if remaining bytes are unknown.
        func estimatedResumeTime(for device: DeviceInfo?) -> String? {
            guard let remaining = remainingBytes(for: device), remaining > 0 else { return nil }
            let bytesPerSec: Double = (device?.connectionType == .wifi) ? 10_000_000 : 35_000_000
            let seconds = Int(Double(remaining) / bytesPerSec)
            if seconds < 60 {
                return "~1m"
            } else if seconds < 3600 {
                let m = max(1, seconds / 60)
                return "~\(m)m"
            } else {
                let h = seconds / 3600
                let m = (seconds % 3600) / 60
                return m > 0 ? "~\(h)h \(m)m" : "~\(h)h"
            }
        }
    }

    /// Trustworthiness of a backup's manifest, or nil when it cannot be opened.
    nonisolated static func backupIntegrity(for udid: String, in directory: String? = nil) -> BackupManifest.IntegrityReport? {
        guard let manifest = try? BackupManifest(backupPath: backupPath(for: udid, in: directory)) else {
            return nil
        }
        return manifest.integrityReport()
    }

    nonisolated static func incompleteBackupStats(for udid: String, in directory: String? = nil, knownDirectorySize: UInt64? = nil) -> IncompleteBackupStats? {
        let fm = FileManager.default
        let path = backupPath(for: udid, in: directory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        var snapshotExists = false
        if fm.fileExists(atPath: snapshotPath, isDirectory: &isDir), isDir.boolValue {
            snapshotExists = true
        }

        // Scan both Snapshot/ (if present) and root path for 2-char hex buckets (00..ff)
        // so partially consolidated backups count all transferred files across both locations.
        var candidateDirs: [String] = []
        if snapshotExists { candidateDirs.append(snapshotPath) }
        candidateDirs.append(path)

        var count = 0
        var totalBytes: UInt64 = 0
        var latestDate: Date?
        var bucketPaths: [String] = []

        for dir in candidateDirs {
            guard let subdirs = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let hexBuckets = subdirs.filter { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }.sorted()
            for sub in hexBuckets {
                if Task.isCancelled { return nil }
                let subPath = (dir as NSString).appendingPathComponent(sub)
                var st = stat()
                let bucketFiles = FileManager.fastDirectoryEntryCount(atPath: subPath, statBuf: &st)
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    if bucketFiles > 0 {
                        count += bucketFiles
                        bucketPaths.append(subPath)
                    }
                    let mod = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    if latestDate == nil || mod > latestDate! {
                        latestDate = mod
                    }
                }
            }
        }

        // Fallback to Manifest.db file count if no hex bucket links were found
        if count == 0 {
            for candidateManifest in [
                (snapshotPath as NSString).appendingPathComponent("Manifest.db"),
                (path as NSString).appendingPathComponent("Manifest.db")
            ] {
                if fm.fileExists(atPath: candidateManifest),
                   let reader = try? SQLiteReader(path: candidateManifest),
                   let rowCount: Int = try? reader.scalar("SELECT count(*) FROM Files WHERE flags = 1"),
                   rowCount > 0 {
                    count = rowCount
                    if let modDate = (try? fm.attributesOfItem(atPath: candidateManifest)[.modificationDate]) as? Date {
                        if latestDate == nil || modDate > latestDate! {
                            latestDate = modDate
                        }
                    }
                    break
                }
            }
        }

        if count > 0 {
            let infoPath = (path as NSString).appendingPathComponent("Info.plist")
            if let attrs = try? fm.attributesOfItem(atPath: infoPath),
               let mod = attrs[.modificationDate] as? Date {
                if latestDate == nil || mod > latestDate! {
                    latestDate = mod
                }
            }

            if let known = knownDirectorySize, known > 0 {
                totalBytes = known
            } else if !bucketPaths.isEmpty {
                if Task.isCancelled { return nil }
                if let sampled = FileManager.sampledHexBucketSize(bucketPaths: bucketPaths, totalBucketFiles: count) {
                    totalBytes = sampled
                } else if Task.isCancelled {
                    return nil
                } else {
                    totalBytes = UInt64(count) * 700_000
                }
            } else {
                totalBytes = UInt64(count) * 700_000
            }
        }

        guard count > 0 || totalBytes > 0 else { return nil }
        return IncompleteBackupStats(fileCount: count, totalBytes: totalBytes, lastModified: latestDate)
    }

    /// Queries the target device's live disk usage (`TotalDiskCapacity`, `AmountDataAvailable`, `TotalDataCapacity`)
    /// directly via lockdown so a backup job can independently calculate its exact target size and completion fraction
    /// even when the passed-in `DeviceInfo` did not have disk capacity populated.
    nonisolated static func fetchTargetDeviceUsedBytes(for udid: String) async -> UInt64? {
        var diskInfo = await PyMobileDevice.diskUsage(udid: udid)
        if diskInfo.isEmpty {
            let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.disk_usage"], timeout: 8)
            if result.succeeded {
                diskInfo = result.output.parseKeyValuePairs()
            }
        }
        if let total = diskInfo["TotalDiskCapacity"].flatMap(UInt64.init),
           let available = diskInfo["AmountDataAvailable"].flatMap(UInt64.init),
           total > available {
            let used = total - available
            if used > 0 { return used }
        }
        if let totalData = diskInfo["TotalDataCapacity"].flatMap(UInt64.init),
           let available = diskInfo["AmountDataAvailable"].flatMap(UInt64.init),
           totalData > available {
            let usedData: UInt64 = totalData - available
            return usedData
        }
        if let totalData = diskInfo["TotalDataCapacity"].flatMap(UInt64.init), totalData > 0 {
            return totalData
        }
        return nil
    }

    /// Returns the most recent file modification timestamp inside the active backup directory
    /// (`Snapshot/` or root `00..ff` / metadata plists) so the liveness monitor knows when disk I/O
    /// is actively occurring even if the CLI tool has not emitted a new stderr progress line yet.
    nonisolated static func latestBackupDiskActivityDate(for udid: String, in directory: String? = nil) -> Date? {
        let fm = FileManager.default
        let path = backupPath(for: udid, in: directory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        var newestDate: Date?
        let updateNewest: (String) -> Void = { itemPath in
            if let attrs = try? fm.attributesOfItem(atPath: itemPath),
               let mod = attrs[.modificationDate] as? Date {
                if newestDate == nil || mod > newestDate! {
                    newestDate = mod
                }
            }
        }

        updateNewest(path)
        for meta in ["Status.plist", "Info.plist", "Manifest.db", "Manifest.db-wal", "Manifest.plist"] {
            updateNewest((path as NSString).appendingPathComponent(meta))
        }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        let targetDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue ? snapshotPath : path
        updateNewest(targetDir)

        if let subdirs = try? fm.contentsOfDirectory(atPath: targetDir) {
            var recentBuckets: [(path: String, mtime: TimeInterval)] = []
            for sub in subdirs where sub.count == 2 {
                if Task.isCancelled { return newestDate }
                var st = stat()
                let subPath = (targetDir as NSString).appendingPathComponent(sub)
                if stat(subPath, &st) == 0 {
                    let mtimeSec = TimeInterval(st.st_mtimespec.tv_sec)
                    let mod = Date(timeIntervalSince1970: mtimeSec)
                    if newestDate == nil || mod > newestDate! {
                        newestDate = mod
                    }
                    recentBuckets.append((subPath, mtimeSec))
                }
            }

            // APFS updates a bucket directory's mtime whenever a file is created or renamed into it,
            // and Manifest.db-wal / Status.plist update on metadata writes. For large in-flight files,
            // sample at most 20 entries in the single most recently modified bucket so liveness checks
            // finish in <2ms instead of stalling external USB drives on 18,000 stat() calls.
            if let newestBucket = recentBuckets.max(by: { $0.mtime < $1.mtime }),
               let dp = opendir(newestBucket.path) {
                defer { closedir(dp) }
                var checked = 0
                while let ep = readdir(dp), checked < 20 {
                    if Task.isCancelled { return newestDate }
                    guard ep.pointee.d_type == DT_REG else { continue }
                    let name = withUnsafePointer(to: ep.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(ep.pointee.d_namlen) + 1) {
                            String(cString: $0)
                        }
                    }
                    checked += 1
                    var fst = stat()
                    let filePath = (newestBucket.path as NSString).appendingPathComponent(name)
                    if stat(filePath, &fst) == 0 {
                        let fmod = Date(timeIntervalSince1970: TimeInterval(fst.st_mtimespec.tv_sec))
                        if newestDate == nil || fmod > newestDate! {
                            newestDate = fmod
                        }
                    }
                }
            }
        }
        return newestDate
    }

    /// Samples the currently written domain by finding the most recently modified
    /// file in the active backup directory and resolving its domain from Manifest.db.
    /// Returns nil if no Manifest.db exists yet or if the file cannot be mapped.
    nonisolated static func sampleActiveDomain(for udid: String, in directory: String? = nil) -> String? {
        let fm = FileManager.default
        let path = backupPath(for: udid, in: directory)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let snapshotPath = (path as NSString).appendingPathComponent("Snapshot")
        let targetDir = fm.fileExists(atPath: snapshotPath, isDirectory: &isDir) && isDir.boolValue ? snapshotPath : path

        guard let subdirs = try? fm.contentsOfDirectory(atPath: targetDir) else { return nil }
        var newestBucketPath: String?
        var newestBucketMtime: TimeInterval = 0

        for sub in subdirs where sub.count == 2 {
            if Task.isCancelled { return nil }
            let subPath = (targetDir as NSString).appendingPathComponent(sub)
            var st = stat()
            if stat(subPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                if mtime >= newestBucketMtime {
                    newestBucketMtime = mtime
                    newestBucketPath = subPath
                }
            }
        }

        guard let bucketPath = newestBucketPath, let dp = opendir(bucketPath) else { return nil }
        defer { closedir(dp) }
        var newestFileID: String?
        var newestDate: Date?
        var checked = 0
        while let ep = readdir(dp), checked < 25 {
            if Task.isCancelled { return nil }
            guard ep.pointee.d_type == DT_REG else { continue }
            let name = withUnsafePointer(to: ep.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ep.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            checked += 1
            let filePath = (bucketPath as NSString).appendingPathComponent(name)
            var fst = stat()
            if stat(filePath, &fst) == 0 {
                let mod = Date(timeIntervalSince1970: TimeInterval(fst.st_mtimespec.tv_sec))
                if newestDate == nil || mod > newestDate! {
                    newestDate = mod
                    newestFileID = name
                }
            }
        }

        guard let fileID = newestFileID else { return nil }
        guard let manifest = try? BackupManifest(backupPath: path) else { return nil }
        return manifest.entry(withFileID: fileID)?.domain
    }

    /// Sanitize an interrupted backup folder before resuming to prevent com.apple.mobilebackup2
    /// and idevicebackup2 / pymobiledevice3 from failing with MBErrorDomain/205 ("cannot parse null plist").
    /// - Checks and cleans up 0-byte or corrupted plist stubs (Status.plist, Info.plist).
    struct SanitizeResult: Sendable, Equatable {
        let filesScanned: Int
        let filesCleaned: Int
        let walCheckpointed: Bool
    }

    /// Sanitize an interrupted backup folder before resuming to prevent com.apple.mobilebackup2
    /// and idevicebackup2 / pymobiledevice3 from failing with MBErrorDomain/205 ("cannot parse null plist").
    /// - Checks and cleans up 0-byte or corrupted plist stubs (Status.plist, Info.plist).
    /// - Performs SQLite WAL checkpoint and removes stale lock files (Manifest.db-wal, Manifest.db-shm).
    /// - Removes transient staging or temp files.
    @discardableResult
    nonisolated static func sanitizeIncompleteBackup(at path: String) -> SanitizeResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return SanitizeResult(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
        }
        // Do not touch a backup that already completed with no leftover WAL/SHM sidecars.
        let walFile = (path as NSString).appendingPathComponent("Manifest.db-wal")
        let shmFile = (path as NSString).appendingPathComponent("Manifest.db-shm")
        if looksLikeBackupFolder(path) && !fm.fileExists(atPath: walFile) && !fm.fileExists(atPath: shmFile) {
            return SanitizeResult(filesScanned: 0, filesCleaned: 0, walCheckpointed: false)
        }

        var scanned = 0
        var cleaned = 0
        var walCheckpointed = false

        let parentDir = (path as NSString).deletingLastPathComponent
        let dirName = (path as NSString).lastPathComponent
        var createdQuarantineDir: String?
        let quarantineNonEmptyFile: (String, String) -> Bool = { filePath, fileName in
            if createdQuarantineDir == nil {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let ts = formatter.string(from: Date())
                let qDir = (parentDir as NSString).appendingPathComponent("\(dirName)-phosphor-quarantine-bkp-\(ts)")
                try? fm.createDirectory(atPath: qDir, withIntermediateDirectories: true)
                createdQuarantineDir = qDir
            }
            guard let qDir = createdQuarantineDir else { return false }
            let dst = (qDir as NSString).appendingPathComponent(fileName)
            try? fm.removeItem(atPath: dst)
            return (try? fm.moveItem(atPath: filePath, toPath: dst)) != nil
        }

        // First restore any valid metadata from .<UDID>-phosphor-guard-bkp if present
        cleaned += restoreMetadataGuardIfNeeded(for: dirName, in: parentDir)

        // 1. Remove 0-byte or quarantine unparseable Status.plist so mobilebackup2 starts a clean phase
        let statusPath = (path as NSString).appendingPathComponent("Status.plist")
        if fm.fileExists(atPath: statusPath) {
            scanned += 1
            if !isNonEmptyFile(statusPath) {
                if (try? fm.removeItem(atPath: statusPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if quarantineNonEmptyFile(statusPath, "Status.plist") { cleaned += 1 }
            }
        }

        // 2. Remove 0-byte or quarantine unparseable Info.plist
        let infoPath = (path as NSString).appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: infoPath) {
            scanned += 1
            if !isNonEmptyFile(infoPath) {
                if (try? fm.removeItem(atPath: infoPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if quarantineNonEmptyFile(infoPath, "Info.plist") { cleaned += 1 }
            }
        }

        // 3. Remove 0-byte or quarantine unparseable Manifest.plist
        let manifestPlistPath = (path as NSString).appendingPathComponent("Manifest.plist")
        if fm.fileExists(atPath: manifestPlistPath) {
            scanned += 1
            if !isNonEmptyFile(manifestPlistPath) {
                if (try? fm.removeItem(atPath: manifestPlistPath)) != nil { cleaned += 1 }
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPlistPath)),
                      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) == nil {
                if quarantineNonEmptyFile(manifestPlistPath, "Manifest.plist") { cleaned += 1 }
            }
        }

        // 4. Checkpoint SQLite Manifest.db if WAL sidecars exist
        let manifestDbPath = (path as NSString).appendingPathComponent("Manifest.db")
        let walPath = (path as NSString).appendingPathComponent("Manifest.db-wal")
        let shmPath = (path as NSString).appendingPathComponent("Manifest.db-shm")
        if fm.fileExists(atPath: manifestDbPath) && isNonEmptyFile(manifestDbPath) {
            scanned += 1
            if fm.fileExists(atPath: walPath) || fm.fileExists(atPath: shmPath) {
                scanned += (fm.fileExists(atPath: walPath) ? 1 : 0) + (fm.fileExists(atPath: shmPath) ? 1 : 0)
                // Execute a quick truncate checkpoint if possible via sqlite3
                var dbPointer: OpaquePointer?
                if sqlite3_open(manifestDbPath, &dbPointer) == SQLITE_OK, let db = dbPointer {
                    var logFrames: Int32 = 0
                    var ckptFrames: Int32 = 0
                    if sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &ckptFrames) == SQLITE_OK {
                        walCheckpointed = true
                    }
                    sqlite3_close(db)
                }
                // If WAL is still 0-bytes or leftover, remove it
                if fm.fileExists(atPath: walPath) && !isNonEmptyFile(walPath) {
                    if (try? fm.removeItem(atPath: walPath)) != nil { cleaned += 1 }
                }
                if fm.fileExists(atPath: shmPath) && !isNonEmptyFile(shmPath) {
                    if (try? fm.removeItem(atPath: shmPath)) != nil { cleaned += 1 }
                }
            }
        } else if fm.fileExists(atPath: manifestDbPath) && !isNonEmptyFile(manifestDbPath) {
            scanned += 1
            // A zero-byte Manifest.db will cause sqlite3 / mobilebackup2 to fail
            if (try? fm.removeItem(atPath: manifestDbPath)) != nil { cleaned += 1 }
            if fm.fileExists(atPath: walPath) {
                scanned += 1
                if (try? fm.removeItem(atPath: walPath)) != nil { cleaned += 1 }
            }
            if fm.fileExists(atPath: shmPath) {
                scanned += 1
                if (try? fm.removeItem(atPath: shmPath)) != nil { cleaned += 1 }
            }
        }

        // 5. Clean up 0-byte leftover temporary files (.tmp, .staging) and quarantine non-empty foreign files
        let validRootNames: Set<String> = [
            "Info.plist", "Status.plist", "Manifest.plist",
            "Manifest.db", "Manifest.db-wal", "Manifest.db-shm",
            "Manifest.mbdb", "Snapshot"
        ]
        let isTwoCharHex: (String) -> Bool = { name in
            guard name.count == 2 else { return false }
            return name.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: path) {
            for entry in entries {
                if validRootNames.contains(entry) || isTwoCharHex(entry) { continue }
                let entryPath = (path as NSString).appendingPathComponent(entry)
                scanned += 1
                if entry == ".DS_Store" || ((entry.hasSuffix(".tmp") || entry.hasSuffix(".staging")) && !isNonEmptyFile(entryPath)) {
                    if (try? fm.removeItem(atPath: entryPath)) != nil {
                        cleaned += 1
                    }
                } else {
                    if quarantineNonEmptyFile(entryPath, entry) {
                        cleaned += 1
                    }
                }
            }
        }

        return SanitizeResult(filesScanned: scanned, filesCleaned: cleaned, walCheckpointed: walCheckpointed)
    }
}
