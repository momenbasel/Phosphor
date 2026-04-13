import Foundation

/// Manages iOS applications: listing installed apps, extracting app data from backups,
/// installing/removing IPAs on connected devices.
@MainActor
final class AppManager: ObservableObject {

    @Published var installedApps: [InstalledApp] = []
    @Published var backupApps: [AppBundle] = []
    @Published var isLoading = false
    @Published var lastError: String?

    // MARK: - Installed Apps (via ideviceinstaller)

    /// List all installed apps on a connected device.
    func listInstalledApps(udid: String) async {
        isLoading = true
        lastError = nil

        // Modern syntax: "list --all", Legacy: "-l -o list_all"
        var result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "list", "--all"])
        if !result.succeeded {
            result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "-l", "-o", "list_all"])
        }
        guard result.succeeded else {
            lastError = result.stderr.nilIfEmpty ?? "Failed to list apps. Is ideviceinstaller installed?"
            isLoading = false
            return
        }

        var apps: [InstalledApp] = []
        // Output format: "com.apple.mobilesafari, Safari, 18.0"
        // or XML plist depending on version
        for line in result.output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ", ")
            guard parts.count >= 2 else { continue }

            let bundleId = parts[0].trimmingCharacters(in: .whitespaces)
            // Skip header lines
            guard bundleId.contains(".") else { continue }

            let name = parts.count > 1 ? parts[1] : bundleId
            let version = parts.count > 2 ? parts[2] : ""

            let appType: InstalledApp.AppType
            if bundleId.hasPrefix("com.apple.") {
                appType = .system
            } else {
                appType = .user
            }

            apps.append(InstalledApp(
                id: bundleId,
                name: name,
                version: version,
                appType: appType,
                signerIdentity: nil,
                path: nil
            ))
        }

        installedApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    // MARK: - Backup Apps

    /// Discover apps stored in a backup via Manifest.plist.
    func loadBackupApps(backupPath: String) {
        isLoading = true

        guard let manifest = PlistParser.parseManifest(backupPath) else {
            lastError = "Failed to parse backup manifest"
            isLoading = false
            return
        }

        do {
            let backupManifest = try BackupManifest(backupPath: backupPath)
            let domains = try backupManifest.domains()

            var apps: [AppBundle] = []
            for bundleId in manifest.applicationBundleIds {
                let appDomain = "AppDomain-\(bundleId)"
                let hasData = domains.contains(appDomain)

                // Try to get app name from bundle ID (last component, cleaned up)
                let nameParts = bundleId.split(separator: ".")
                let guessedName = nameParts.last.map(String.init) ?? bundleId

                var dataSize: UInt64 = 0
                if hasData {
                    let files = try backupManifest.files(inDomain: appDomain)
                    dataSize = UInt64(files.reduce(0) { $0 + $1.size })
                }

                apps.append(AppBundle(
                    id: bundleId,
                    name: guessedName.capitalized,
                    version: "",
                    shortVersion: "",
                    domain: appDomain,
                    containerPath: nil,
                    dataSize: dataSize
                ))
            }

            backupApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - App Installation

    /// Install an IPA file on a connected device.
    /// Tries modern subcommand syntax first, falls back to legacy -i flag,
    /// then tries xcrun devicectl as last resort.
    func installIPA(path: String, udid: String) async -> Bool {
        // Modern ideviceinstaller (1.2+): "install PATH"
        var result = await Shell.runAsync(
            "ideviceinstaller",
            arguments: ["-u", udid, "install", path],
            timeout: 300
        )

        if result.succeeded { return true }

        // Legacy ideviceinstaller: "-i PATH"
        if result.stderr.contains("invalid option") || result.output.contains("invalid option") {
            result = await Shell.runAsync(
                "ideviceinstaller",
                arguments: ["-u", udid, "-i", path],
                timeout: 300
            )
            if result.succeeded { return true }
        }

        // Fallback: Apple's xcrun devicectl (Xcode 15+)
        let devicectlResult = await Shell.runAsync(
            "xcrun",
            arguments: ["devicectl", "device", "install", "app", "--device", udid, path],
            timeout: 300
        )
        if devicectlResult.succeeded { return true }

        // Fallback: ios-deploy
        let iosDeployResult = await Shell.runAsync(
            "ios-deploy",
            arguments: ["--id", udid, "--bundle", path],
            timeout: 300
        )
        if iosDeployResult.succeeded { return true }

        lastError = result.stderr.nilIfEmpty ?? result.output.nilIfEmpty ?? devicectlResult.stderr.nilIfEmpty ?? "Installation failed with all methods. Try: brew install ios-deploy"
        return false
    }

    /// Uninstall an app from a connected device.
    func uninstallApp(bundleId: String, udid: String) async -> Bool {
        // Modern syntax first
        var result = await Shell.runAsync(
            "ideviceinstaller",
            arguments: ["-u", udid, "uninstall", bundleId]
        )

        if result.succeeded { return true }

        // Legacy fallback
        if result.stderr.contains("invalid option") || result.output.contains("invalid option") {
            result = await Shell.runAsync(
                "ideviceinstaller",
                arguments: ["-u", udid, "-U", bundleId]
            )
            if result.succeeded { return true }
        }

        // Apple devicectl fallback
        let devicectlResult = await Shell.runAsync(
            "xcrun",
            arguments: ["devicectl", "device", "uninstall", "app", "--device", udid, bundleId]
        )
        if devicectlResult.succeeded { return true }

        lastError = result.stderr.nilIfEmpty ?? result.output
        return false
    }

    /// Extract app data from a backup to a destination.
    func extractAppData(
        bundleId: String,
        from backupPath: String,
        to destination: String
    ) async -> Int {
        do {
            let manifest = try BackupManifest(backupPath: backupPath)
            let files = try manifest.appFiles(bundleId: bundleId)

            let fm = FileManager.default
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)

            var extracted = 0
            for entry in files where entry.isFile {
                let destPath = (destination as NSString).appendingPathComponent(entry.relativePath)
                let destDir = (destPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

                do {
                    try manifest.extractFile(entry, to: destPath)
                    extracted += 1
                } catch {
                    continue
                }
            }
            return extracted
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }
}
