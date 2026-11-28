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
            lastError = result.stderr.nilIfEmpty ?? "Failed to list apps. Install pymobiledevice3: pipx install pymobiledevice3"
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

    /// List installed apps instantly, returning AppBackupTarget entries without waiting for disk size scans.
    func listInstalledAppsFast(udid: String) async -> [AppBackupTarget] {
        let pyApps = await PyMobileDevice.appsList(udid: udid, calculateSizes: false, timeoutOverride: 30)
        return parseAppBackupTargets(from: pyApps)
    }

    /// List installed apps with exact DynamicDiskUsage and StaticDiskUsage.
    func listInstalledAppsWithSizes(udid: String, timeout: TimeInterval? = nil) async -> [AppBackupTarget] {
        let pyApps = await PyMobileDevice.appsList(udid: udid, calculateSizes: true, timeoutOverride: timeout)
        return parseAppBackupTargets(from: pyApps)
    }

    private func parseAppBackupTargets(from pyApps: [[String: Any]]) -> [AppBackupTarget] {
        var targets: [AppBackupTarget] = []

        for appDict in pyApps {
            let bundleId = appDict["CFBundleIdentifier"] as? String ?? ""
            guard !bundleId.isEmpty else { continue }

            let name = appDict["CFBundleDisplayName"] as? String
                ?? appDict["CFBundleName"] as? String
                ?? bundleId.split(separator: ".").last.map(String.init) ?? bundleId
            let version = appDict["CFBundleShortVersionString"] as? String
                ?? appDict["CFBundleVersion"] as? String ?? ""

            let dynamicBytes = (appDict["DynamicDiskUsage"] as? NSNumber)?.int64Value
            let staticBytes = (appDict["StaticDiskUsage"] as? NSNumber)?.int64Value

            let isApple = bundleId.hasPrefix("com.apple.")
            if isApple {
                // Known user-facing Apple productivity and media applications that store user documents
                let userFacingAppleApps: Set<String> = [
                    "com.apple.iBooks",
                    "com.apple.Pages",
                    "com.apple.Keynote",
                    "com.apple.Numbers",
                    "com.apple.garageband",
                    "com.apple.iMovie",
                    "com.apple.podcasts",
                    "com.apple.shortcuts",
                    "com.apple.freeform",
                    "com.apple.clips",
                    "com.apple.Music",
                    "com.apple.mobileslideshow"
                ]

                // If it's an internal Apple system daemon/service or has 0 bytes, completely exclude from UI
                let isAllowedUserApp = userFacingAppleApps.contains(bundleId)
                if !isAllowedUserApp {
                    // Do not expose internal system services/daemons to backup exclusion list
                    continue
                }
            }

            targets.append(AppBackupTarget(
                id: bundleId,
                displayName: name,
                version: version,
                dynamicDiskBytes: dynamicBytes,
                staticDiskBytes: staticBytes,
                isSystemApp: isApple
            ))
        }

        return targets.sorted {
            let total0 = $0.effectiveTotalBytes
            let total1 = $1.effectiveTotalBytes
            if total0 != total1 {
                return total0 > total1
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Backup Apps

    func loadBackupApps(backupPath: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Sizing an app domain stats every file in it, so a backup with hundreds
        // of apps is seconds of blocking work. Do it off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            Self.readBackupApps(backupPath: backupPath)
        }.value

        switch result {
        case .success(let apps):
            backupApps = apps
        case .failure(let message):
            backupApps = []
            lastError = message
        }
    }

    private enum BackupAppsResult {
        case success([AppBundle])
        case failure(String)
    }

    private nonisolated static func readBackupApps(backupPath: String) -> BackupAppsResult {
        guard let manifest = PlistParser.parseManifest(backupPath) else {
            return .failure("Failed to parse backup manifest")
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
                    dataSize = UInt64(backupManifest.totalSize(for: files))
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

            return .success(apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        } catch {
            return .failure(error.localizedDescription)
        }
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
        to selectedDirectory: String
    ) async -> Int {
        lastError = nil
        do {
            let manifest = try BackupManifest(backupPath: backupPath)
            let files = try manifest.appFiles(bundleId: bundleId)

            let fm = FileManager.default
            let extractionRoot = try SafeExtractionPath.prepareExtractionRoot(
                selectedDirectory: URL(fileURLWithPath: selectedDirectory, isDirectory: true),
                component: bundleId,
                fileManager: fm
            )

            // Preflight every entry before writing anything, but skip the unsafe
            // rows instead of aborting: one malformed manifest row should not cost
            // the user the whole extraction. Rejected rows are counted and reported.
            var extractionPlan: [(BackupManifest.FileEntry, URL)] = []
            var rejected = 0
            for entry in files where entry.isFile {
                guard let destinationURL = try? SafeExtractionPath.prepareDestination(
                    root: extractionRoot,
                    relativePath: entry.relativePath,
                    fileManager: fm
                ) else {
                    rejected += 1
                    continue
                }
                extractionPlan.append((entry, destinationURL))
            }

            var extracted = 0
            for (entry, destinationURL) in extractionPlan {
                do {
                    try manifest.extractFile(entry, to: destinationURL.path)
                    extracted += 1
                } catch {
                    continue
                }
            }
            if rejected > 0 {
                lastError = "Skipped \(rejected) backup \(rejected == 1 ? "entry" : "entries") with an unsafe extraction path."
            }
            return extracted
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }
}
