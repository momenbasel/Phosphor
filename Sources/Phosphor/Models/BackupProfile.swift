import Foundation

/// Pre-configured domain and content profile templates for iOS backups.
public enum BackupProfileType: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 100% of device storage — all domains, photos, videos, and app data.
    case full = "full"
    
    /// Disaster recovery: System identity, Settings, Keychain, Accounts, Wi-Fi, Health, SMS, Contacts.
    /// Excludes Photos, Videos, Podcasts, Music, and third-party app caches.
    case bareMinimal = "bare_minimal"
    
    /// Bare Minimal + Instant Messaging containers (WhatsApp, Signal, Telegram, WeChat).
    case communicationAndIdentity = "communication_identity"
    
    /// Bare Minimal + Photos & Videos (`CameraRollDomain`), excluding third-party app caches.
    case essentialPhotos = "essential_photos"
    
    /// Custom user-selected domain categories and app exclusions.
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full:
            return "Complete Archive"
        case .bareMinimal:
            return "Bare Minimal (Disaster Recovery)"
        case .communicationAndIdentity:
            return "Communication & Identity"
        case .essentialPhotos:
            return "Photos & Essentials"
        case .custom:
            return "Custom Profile"
        }
    }

    public var iconName: String {
        switch self {
        case .full:
            return "archivebox.fill"
        case .bareMinimal:
            return "shield.lefthalf.filled"
        case .communicationAndIdentity:
            return "bubble.left.and.bubble.right.fill"
        case .essentialPhotos:
            return "photo.on.rectangle.angled"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    public var subtitle: String {
        switch self {
        case .full:
            return "Everything: photos, videos, media, messages, accounts, and all apps."
        case .bareMinimal:
            return "Settings, Keychain, passwords, messages, and contacts. Fast 5-15 min restore."
        case .communicationAndIdentity:
            return "Bare Minimal plus WhatsApp, Telegram, and Signal messaging databases."
        case .essentialPhotos:
            return "Identity and Camera Roll photos/videos. Skips third-party app caches."
        case .custom:
            return "Granular domain rules and custom app exclusion checklist."
        }
    }

    public var estimatedTimeBadge: String {
        switch self {
        case .full:
            return "Full Duration"
        case .bareMinimal:
            return "~5 - 15 min"
        case .communicationAndIdentity:
            return "~10 - 25 min"
        case .essentialPhotos:
            return "Variable"
        case .custom:
            return "Custom"
        }
    }

    /// Content summary items (included and excluded) for high-transparency display in UI cards.
    public var contentSummary: (included: [String], excluded: [String]) {
        switch self {
        case .full:
            return (
                included: ["Keychain & Settings", "Messages & Health", "Photos & Videos", "All Apps & Data"],
                excluded: []
            )
        case .bareMinimal:
            return (
                included: ["Keychain & Passwords", "System Settings", "SMS & Contacts", "Health Data", "Apple Stock Apps"],
                excluded: ["Photos & Videos", "3rd-Party Apps", "Music & Podcasts"]
            )
        case .communicationAndIdentity:
            return (
                included: ["Keychain & Settings", "SMS & Contacts", "WhatsApp / Signal / Telegram", "Health Data"],
                excluded: ["Photos & Videos", "Non-Chat Apps", "Music & Podcasts"]
            )
        case .essentialPhotos:
            return (
                included: ["Keychain & Settings", "SMS & Contacts", "Photos & Videos (Camera Roll)", "Health Data"],
                excluded: ["3rd-Party Apps", "Music & Podcasts"]
            )
        case .custom:
            return (
                included: ["Custom Domain Selection"],
                excluded: ["User-Selected Exclusions"]
            )
        }
    }

    /// User-facing description of how apps are treated in this profile.
    public var appInclusionSummary: String {
        switch self {
        case .full:
            return "All installed apps and local data included."
        case .bareMinimal:
            return "All 3rd-party apps and data excluded (clean device restore)."
        case .communicationAndIdentity:
            return "Only messaging apps (WhatsApp, Signal, Telegram, WeChat) included."
        case .essentialPhotos:
            return "All 3rd-party apps and data excluded (saves 100+ GB)."
        case .custom:
            return "Granular custom app selection."
        }
    }

    /// Returns nil if no domain filtering is needed (full archive).
    public func preservationRegex(
        customDomains: Set<String> = [],
        excludedBundleIds: Set<String> = []
    ) -> [String]? {
        let bundleNegativeLookahead: String
        if !excludedBundleIds.isEmpty {
            let excludedPattern = excludedBundleIds
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            bundleNegativeLookahead = "(?!AppDomain(-(\(excludedPattern))|Group-.*(\(excludedPattern))).*)"
        } else {
            bundleNegativeLookahead = ""
        }

        switch self {
        case .full:
            guard !excludedBundleIds.isEmpty else { return nil }
            return ["^\(bundleNegativeLookahead).*$"]

        case .bareMinimal:
            // Core identity, communication, health, settings. Excludes CameraRoll, Media, and third-party apps.
            return [
                "^\(bundleNegativeLookahead)(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|AppDomain(Group-group\\.|Plugin-|-)(com\\.apple\\..*))$"
            ]

        case .communicationAndIdentity:
            // Bare Minimal + popular communication apps (WhatsApp, Signal, Telegram, WeChat)
            return [
                "^\(bundleNegativeLookahead)(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|AppDomain(Group-group\\.|Plugin-|-)(com\\.apple\\..*)|AppDomain(Group-.*|-)(net\\.whatsapp\\.WhatsApp|net\\.whatsapp\\.WhatsAppSMB|org\\.whispersystems\\.signal|ph\\.telegra\\.Telegraph|com\\.tencent\\.xin).*)$"
            ]

        case .essentialPhotos:
            // Bare Minimal + Camera Roll photos/videos
            return [
                "^\(bundleNegativeLookahead)(HomeDomain|SystemPreferencesDomain|KeychainDomain|RootDomain|ManagedPreferencesDomain|WirelessDomain|HealthDomain|TonesDomain|CameraRollDomain|AppDomain(Group-group\\.|Plugin-|-)(com\\.apple\\..*))$"
            ]

        case .custom:
            guard !customDomains.isEmpty || !excludedBundleIds.isEmpty else { return nil }
            if !customDomains.isEmpty {
                let domainPattern = customDomains.joined(separator: "|")
                return ["^\(bundleNegativeLookahead)(\(domainPattern)).*$"]
            }
            return ["^\(bundleNegativeLookahead).*$"]
        }
    }
}
