import Foundation

/// Manages iOS applications: listing, installing, removing, extracting.
/// Primary: pymobiledevice3 apps. Fallback: ideviceinstaller.
@MainActor
final class AppManager: ObservableObject {

    @Published var installedApps: [InstalledApp] = []
    @Published var backupApps: [AppBundle] = []
    @Published var isLoading = false
    @Published var lastError: String?

    // MARK: - Installed Apps

    /// List all installed apps on a connected device.
    func listInstalledApps(udid: String) async {
        isLoading = true
        lastError = nil

        // Primary: pymobiledevice3 apps list (JSON output)
        let pyApps = await PyMobileDevice.appsList(udid: udid)
        if !pyApps.isEmpty {
            var apps: [InstalledApp] = []
            for appDict in pyApps {
                let bundleId = appDict["CFBundleIdentifier"] as? String ?? ""
                guard !bundleId.isEmpty else { continue }

                let name = appDict["CFBundleDisplayName"] as? String
                    ?? appDict["CFBundleName"] as? String
                    ?? bundleId.split(separator: ".").last.map(String.init) ?? bundleId
                let version = appDict["CFBundleShortVersionString"] as? String
                    ?? appDict["CFBundleVersion"] as? String ?? ""
                let appType: InstalledApp.AppType = bundleId.hasPrefix("com.apple.") ? .system : .user

                apps.append(InstalledApp(
                    id: bundleId,
                    name: name,
                    version: version,
                    appType: appType,
                    signerIdentity: appDict["SignerIdentity"] as? String,
                    path: appDict["Path"] as? String
                ))
            }

            installedApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isLoading = false
            return
        }

        // Fallback: ideviceinstaller
        var result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "list", "--all"])
        if !result.succeeded {
            result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "-l", "-o", "list_all"])
        }
        guard result.succeeded else {
            lastError = result.stderr.nilIfEmpty ?? "Failed to list apps. Install pymobiledevice3: pip3 install pymobiledevice3"
            isLoading = false
            return
        }

        var apps: [InstalledApp] = []
        for line in result.output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ", ")
            guard parts.count >= 2 else { continue }

            let bundleId = parts[0].trimmingCharacters(in: .whitespaces)
            guard bundleId.contains(".") else { continue }

            let name = parts.count > 1 ? parts[1] : bundleId
            let version = parts.count > 2 ? parts[2] : ""
            let appType: InstalledApp.AppType = bundleId.hasPrefix("com.apple.") ? .system : .user

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

    /// Install an IPA. pymobiledevice3 primary, multiple fallbacks.
    func installIPA(path: String, udid: String) async -> Bool {
        // Primary: pymobiledevice3
        if await PyMobileDevice.installApp(path: path, udid: udid) { return true }

        // Fallback chain: ideviceinstaller -> xcrun devicectl -> ios-deploy
        var result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "install", path], timeout: 300)
        if result.succeeded { return true }

        if result.stderr.contains("invalid option") || result.output.contains("invalid option") {
            result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "-i", path], timeout: 300)
            if result.succeeded { return true }
        }

        let devicectlResult = await Shell.runAsync("xcrun", arguments: ["devicectl", "device", "install", "app", "--device", udid, path], timeout: 300)
        if devicectlResult.succeeded { return true }

        let iosDeployResult = await Shell.runAsync("ios-deploy", arguments: ["--id", udid, "--bundle", path], timeout: 300)
        if iosDeployResult.succeeded { return true }

        lastError = result.stderr.nilIfEmpty ?? "Installation failed with all methods"
        return false
    }

    /// Uninstall an app. pymobiledevice3 primary, fallbacks.
    func uninstallApp(bundleId: String, udid: String) async -> Bool {
        // Primary: pymobiledevice3
        if await PyMobileDevice.uninstallApp(bundleId: bundleId, udid: udid) { return true }

        // Fallback chain
        var result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "uninstall", bundleId])
        if result.succeeded { return true }

        if result.stderr.contains("invalid option") || result.output.contains("invalid option") {
            result = await Shell.runAsync("ideviceinstaller", arguments: ["-u", udid, "-U", bundleId])
            if result.succeeded { return true }
        }

        let devicectlResult = await Shell.runAsync("xcrun", arguments: ["devicectl", "device", "uninstall", "app", "--device", udid, bundleId])
        if devicectlResult.succeeded { return true }

        lastError = result.stderr.nilIfEmpty ?? result.output
        return false
    }

    /// Extract app data from a backup.
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
