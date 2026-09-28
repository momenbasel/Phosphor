import Foundation

/// Per-device persistent backup configuration for profile and app exclusions (Issues #4 & #5).
public struct DeviceBackupConfiguration: Codable, Equatable, Sendable {
    public var profileType: BackupProfileType
    public var excludedBundleIds: Set<String>
    public var excludeMediaAbove50MB: Bool
    public var excludeAppCaches: Bool
    public var excludedFilePatterns: [String]
    public var excludedRelativePaths: Set<String>
    public var customIncludedDomains: Set<String>
    public var alwaysUseProfile: Bool

    public init(
        profileType: BackupProfileType = .full,
        excludedBundleIds: Set<String> = [],
        excludeMediaAbove50MB: Bool = false,
        excludeAppCaches: Bool = false,
        excludedFilePatterns: [String] = [],
        excludedRelativePaths: Set<String> = [],
        customIncludedDomains: Set<String> = [],
        alwaysUseProfile: Bool = false
    ) {
        self.profileType = profileType
        self.excludedBundleIds = excludedBundleIds
        self.excludeMediaAbove50MB = excludeMediaAbove50MB
        self.excludeAppCaches = excludeAppCaches
        self.excludedFilePatterns = excludedFilePatterns
        self.excludedRelativePaths = excludedRelativePaths
        self.customIncludedDomains = customIncludedDomains
        self.alwaysUseProfile = alwaysUseProfile
    }

    private static func storageKey(for udid: String) -> String {
        "Phosphor.DeviceBackupConfiguration.\(udid)"
    }

    /// Load saved configuration for a given device UDID, or default to .full.
    public static func load(for udid: String) -> DeviceBackupConfiguration {
        guard !udid.isEmpty,
              let data = UserDefaults.standard.data(forKey: storageKey(for: udid)),
              let decoded = try? JSONDecoder().decode(DeviceBackupConfiguration.self, from: data) else {
            return DeviceBackupConfiguration()
        }
        return decoded
    }

    /// Save configuration for a given device UDID.
    public func save(for udid: String) {
        guard !udid.isEmpty,
              let encoded = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.storageKey(for: udid))
    }
}
