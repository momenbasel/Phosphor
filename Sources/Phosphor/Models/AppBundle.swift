import Foundation

/// Represents an iOS application found in a backup or on device.
struct AppBundle: Identifiable, Hashable {
    let id: String // bundle identifier
    let name: String
    let version: String
    let shortVersion: String
    let domain: String // AppDomain-com.example.app
    let containerPath: String?
    let dataSize: UInt64

    var displayName: String {
        name.isEmpty ? id : name
    }

    var sizeString: String {
        dataSize.formattedFileSize
    }
}

/// Represents an installed app on a connected device (from ideviceinstaller).
struct InstalledApp: Identifiable, Hashable {
    let id: String // bundle identifier
    let name: String
    let version: String
    let appType: AppType
    let signerIdentity: String?
    let path: String?

    enum AppType: String, Hashable {
        case user = "User"
        case system = "System"
        case hidden = "Hidden"
    }

    var displayName: String {
        name.isEmpty ? id : name
    }
}
