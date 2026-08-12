import Foundation

/// Compact metadata used to compare one manifest entry across two backups.
struct BackupComparisonRecord: Hashable, Sendable {
    let fileID: String
    let domain: String
    let relativePath: String
    let flags: Int
    let size: Int
    let modifiedTime: TimeInterval?
    let metadataDigest: Data
    let metadataComplete: Bool

    init(
        fileID: String,
        domain: String,
        relativePath: String,
        flags: Int,
        size: Int,
        modifiedTime: TimeInterval?,
        metadataDigest: Data = Data(),
        metadataComplete: Bool = true
    ) {
        self.fileID = fileID
        self.domain = domain
        self.relativePath = relativePath
        self.flags = flags
        self.size = size
        self.modifiedTime = modifiedTime
        self.metadataDigest = metadataDigest
        self.metadataComplete = metadataComplete
    }

    var key: String { "\(domain)\u{1F}\(relativePath)" }
    var cursorOrderKey: String { "\(fileID)\u{1F}\(domain)\u{1F}\(relativePath)" }

    fileprivate func hasSameMetadata(as other: BackupComparisonRecord) -> Bool {
        // Deliberately does NOT compare metadataDigest. That digest covers the
        // raw MBFile blob, which on an encrypted backup carries a freshly
        // generated per-file wrapped AES key every time iOS archives the file.
        // Since iOS pins encryption on at the device level, comparing it
        // reported virtually every file as "Metadata Changed" even when
        // content, size and mtime were identical, making the diff useless.
        // flags, size and modifiedTime carry the real signal.
        metadataComplete && other.metadataComplete
            && flags == other.flags
            && size == other.size
            && modifiedTime == other.modifiedTime
    }
}

enum BackupChangeKind: String, CaseIterable, Sendable {
    case added
    case modified
    case removed

    fileprivate var sortOrder: Int {
        switch self {
        case .added: return 0
        case .modified: return 1
        case .removed: return 2
        }
    }
}

struct BackupComparisonChange: Identifiable, Hashable, Sendable {
    let kind: BackupChangeKind
    let before: BackupComparisonRecord?
    let after: BackupComparisonRecord?

    var id: String { "\(kind.rawValue):\(record.key)" }
    var record: BackupComparisonRecord { after ?? before! }
    var domain: String { record.domain }
    var relativePath: String { record.relativePath }
    var fileName: String { (relativePath as NSString).lastPathComponent }
    var sizeDelta: Int { (after?.size ?? 0) - (before?.size ?? 0) }
}

struct BackupComparisonResult: Sendable {
    /// Deterministic, per-kind bounded sample used by the UI. Aggregate counts
    /// remain exact even when a very large manifest diff is truncated.
    let changes: [BackupComparisonChange]
    let addedCount: Int
    let modifiedCount: Int
    let removedCount: Int
    let unchangedCount: Int

    var totalChanges: Int { addedCount + modifiedCount + removedCount }
    var hasHiddenChanges: Bool { totalChanges > changes.count }
}

enum BackupComparisonEngine {
    static func compare(
        older: [BackupComparisonRecord],
        newer: [BackupComparisonRecord],
        displayLimitPerKind: Int = 2_000
    ) -> BackupComparisonResult {
        let oldByKey = Dictionary(older.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(newer.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = Set(oldByKey.keys).union(newByKey.keys).sorted()
        let limit = max(0, displayLimitPerKind)

        var added: [BackupComparisonChange] = []
        var modified: [BackupComparisonChange] = []
        var removed: [BackupComparisonChange] = []
        var addedCount = 0
        var modifiedCount = 0
        var removedCount = 0
        var unchangedCount = 0

        for key in keys {
            let before = oldByKey[key]
            let after = newByKey[key]
            switch (before, after) {
            case (nil, let after?):
                addedCount += 1
                if added.count < limit {
                    added.append(BackupComparisonChange(kind: .added, before: nil, after: after))
                }
            case (let before?, nil):
                removedCount += 1
                if removed.count < limit {
                    removed.append(BackupComparisonChange(kind: .removed, before: before, after: nil))
                }
            case (let before?, let after?):
                if before.hasSameMetadata(as: after) {
                    unchangedCount += 1
                } else {
                    modifiedCount += 1
                    if modified.count < limit {
                        modified.append(BackupComparisonChange(kind: .modified, before: before, after: after))
                    }
                }
            case (nil, nil):
                break
            }
        }

        return BackupComparisonResult(
            changes: added + modified + removed,
            addedCount: addedCount,
            modifiedCount: modifiedCount,
            removedCount: removedCount,
            unchangedCount: unchangedCount
        )
    }

    /// Merge two manifest cursors ordered by the indexed manifest `fileID`.
    /// The file ID is deterministically derived from `(domain, relativePath)`;
    /// domain/path remain the logical identity displayed and filtered by the UI.
    /// Only exact counters and the bounded UI samples are kept; callers never
    /// need to materialize either complete manifest in memory.
    static func compareOrdered(
        nextOlder: () throws -> BackupComparisonRecord?,
        nextNewer: () throws -> BackupComparisonRecord?,
        displayLimitPerKind: Int = 2_000
    ) throws -> BackupComparisonResult {
        let limit = max(0, displayLimitPerKind)
        var before = try nextOlder()
        var after = try nextNewer()
        var added: [BackupComparisonChange] = []
        var modified: [BackupComparisonChange] = []
        var removed: [BackupComparisonChange] = []
        var addedCount = 0
        var modifiedCount = 0
        var removedCount = 0
        var unchangedCount = 0

        while before != nil || after != nil {
            try Task.checkCancellation()
            switch (before, after) {
            case (nil, let current?):
                addedCount += 1
                if added.count < limit {
                    added.append(BackupComparisonChange(kind: .added, before: nil, after: current))
                }
                after = try nextNewer()
            case (let current?, nil):
                removedCount += 1
                if removed.count < limit {
                    removed.append(BackupComparisonChange(kind: .removed, before: current, after: nil))
                }
                before = try nextOlder()
            case (let old?, let new?):
                if old.cursorOrderKey < new.cursorOrderKey {
                    removedCount += 1
                    if removed.count < limit {
                        removed.append(BackupComparisonChange(kind: .removed, before: old, after: nil))
                    }
                    before = try nextOlder()
                } else if new.cursorOrderKey < old.cursorOrderKey {
                    addedCount += 1
                    if added.count < limit {
                        added.append(BackupComparisonChange(kind: .added, before: nil, after: new))
                    }
                    after = try nextNewer()
                } else {
                    if old.hasSameMetadata(as: new) {
                        unchangedCount += 1
                    } else {
                        modifiedCount += 1
                        if modified.count < limit {
                            modified.append(BackupComparisonChange(kind: .modified, before: old, after: new))
                        }
                    }
                    before = try nextOlder()
                    after = try nextNewer()
                }
            case (nil, nil):
                break
            }
        }

        return BackupComparisonResult(
            changes: added + modified + removed,
            addedCount: addedCount,
            modifiedCount: modifiedCount,
            removedCount: removedCount,
            unchangedCount: unchangedCount
        )
    }
}
