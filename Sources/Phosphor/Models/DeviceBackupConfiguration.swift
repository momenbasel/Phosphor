import Foundation

/// Per-device persistent backup configuration for profile and app exclusions.
public struct DeviceBackupConfiguration: Codable, Equatable, Sendable {
    public var profileType: BackupProfileType
    public var excludedBundleIds: Set<String>

    public init(
        profileType: BackupProfileType = .full,
        excludedBundleIds: Set<String> = []
    ) {
        self.profileType = profileType
        self.excludedBundleIds = excludedBundleIds
    }

    private static func storageKey(for udid: String) -> String {
        "Phosphor.DeviceBackupConfiguration.\(udid)"
    }

    /// Returns true when a persisted configuration exists in UserDefaults for the given device UDID.
    public static func hasPersistedConfiguration(for udid: String) -> Bool {
        !udid.isEmpty && UserDefaults.standard.data(forKey: storageKey(for: udid)) != nil
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

    /// Infers the backup profile and excluded app bundle IDs directly from an existing
    /// `<UDID>/Manifest.db` and `Info.plist` on disk (portable across any Mac without
    /// requiring local `UserDefaults` or non-Apple sidecar files inside `<UDID>/`).
    public static func inferFromExistingBackup(udid: String, in directory: String) -> DeviceBackupConfiguration? {
        let backupPath = (directory as NSString).appendingPathComponent(udid)
        let manifestDbPath = (backupPath as NSString).appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: manifestDbPath) else { return nil }

        // Only query unencrypted Manifest.db directly; encrypted backups cannot be queried without password unlock.
        if let manifestPlist = PlistParser.parseManifest(backupPath), manifestPlist.isEncrypted {
            return nil
        }
        guard let db = try? SQLiteReader(path: manifestDbPath),
              let rows = try? db.query("SELECT DISTINCT domain FROM Files") else {
            return nil
        }

        let domains = Set(rows.compactMap { $0["domain"] as? String })
        guard !domains.isEmpty else { return nil }

        let hasCameraRoll = domains.contains("CameraRollDomain")
        let communicationApps: Set<String> = [
            "net.whatsapp.WhatsApp",
            "net.whatsapp.WhatsAppSMB",
            "org.whispersystems.signal",
            "ph.telegra.Telegraph",
            "com.tencent.xin"
        ]

        let backedUpThirdPartyApps: Set<String> = Set(
            domains.compactMap { domain -> String? in
                if domain.hasPrefix("AppDomain-") {
                    let bundleId = String(domain.dropFirst("AppDomain-".count))
                    guard !bundleId.hasPrefix("com.apple.") else { return nil }
                    return bundleId
                }
                if domain.hasPrefix("AppDomainGroup-") {
                    let groupId = String(domain.dropFirst("AppDomainGroup-".count))
                    guard !groupId.hasPrefix("group.com.apple.") else { return nil }
                    if let matchedCommApp = communicationApps.first(where: { groupId.contains($0) }) {
                        return matchedCommApp
                    }
                    return groupId
                }
                return nil
            }
        )

        if backedUpThirdPartyApps.isEmpty {
            if hasCameraRoll {
                return DeviceBackupConfiguration(profileType: .essentialPhotos)
            } else {
                return DeviceBackupConfiguration(profileType: .bareMinimal)
            }
        }

        if !hasCameraRoll && backedUpThirdPartyApps.isSubset(of: communicationApps) {
            return DeviceBackupConfiguration(profileType: .communicationAndIdentity)
        }

        // Full backup profile: all installed applications are included by default.
        // Never speculatively uncheck apps based on historical manifest differences.
        return DeviceBackupConfiguration(
            profileType: .full,
            excludedBundleIds: []
        )
    }

    /// True when two configurations produce the same effective backup domain/exclusion filter.
    public func isCompatibleForIncremental(with existing: DeviceBackupConfiguration) -> Bool {
        profileType == existing.profileType && excludedBundleIds == existing.excludedBundleIds
    }
}
