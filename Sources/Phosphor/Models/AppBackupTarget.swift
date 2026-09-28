import Foundation

/// Entity representing an installed application for selective backup exclusion (Issue #4).
public struct AppBackupTarget: Identifiable, Hashable, Sendable {
    public let id: String // CFBundleIdentifier
    public let displayName: String
    public let version: String
    public let dynamicDiskBytes: Int64 // App caches, downloads, offline media
    public let staticDiskBytes: Int64 // App binary size
    public var isExcluded: Bool
    public var isMediaExcludedOnly: Bool // Keep settings/DBs, exclude videos > 50 MB
    public let isSystemApp: Bool

    public init(
        id: String,
        displayName: String,
        version: String = "",
        dynamicDiskBytes: Int64 = 0,
        staticDiskBytes: Int64 = 0,
        isExcluded: Bool = false,
        isMediaExcludedOnly: Bool = false,
        isSystemApp: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.dynamicDiskBytes = dynamicDiskBytes
        self.staticDiskBytes = staticDiskBytes
        self.isExcluded = isExcluded
        self.isMediaExcludedOnly = isMediaExcludedOnly
        self.isSystemApp = isSystemApp
    }

    public var formattedDynamicSize: String {
        guard dynamicDiskBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: dynamicDiskBytes, countStyle: .file)
    }

    public var formattedTotalSize: String {
        let total = dynamicDiskBytes + staticDiskBytes
        guard total > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
