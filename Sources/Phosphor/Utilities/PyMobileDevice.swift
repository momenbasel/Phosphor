import Foundation

/// Central wrapper for pymobiledevice3 CLI. Primary backend for all iOS device operations.
/// pymobiledevice3 supports iOS 17+ (including iOS 26), unlike libimobiledevice.
/// Searches for pymobiledevice3 binary at common install locations (pipx, pip, venv).
enum PyMobileDevice {

    /// Cached path to the pymobiledevice3 binary once found.
    private static var cachedBinaryPath: String?

    /// Extended PATH for GUI apps that don't inherit terminal PATH.
    private static let extendedPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "\(home)/.local/bin",
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/Library/Python/3.13/bin",
            "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.10/bin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return extra.joined(separator: ":") + ":" + existing
    }()

    /// Find the pymobiledevice3 binary. Checks direct binary first (pipx),
    /// then python3 -m pymobiledevice3 at various Python locations.
    private static func findBinary() -> String? {
        if let cached = cachedBinaryPath { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        // Direct binary locations (pipx, pip --user)
        let directPaths = [
            "\(home)/.local/bin/pymobiledevice3",
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
        ]

        for path in directPaths {
            if fm.isExecutableFile(atPath: path) {
                cachedBinaryPath = path
                return path
            }
        }

        // Try python3 -m pymobiledevice3 with various pythons
        let pythons = [
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for python in pythons {
            guard fm.isExecutableFile(atPath: python) else { continue }
            let result = Shell.run(python, arguments: ["-c", "import pymobiledevice3"])
            if result.succeeded {
                // Use "python3 -m pymobiledevice3" mode via this python
                cachedBinaryPath = python
                return python
            }
        }

        return nil
    }

    /// Whether the found binary is a direct pymobiledevice3 binary (vs python3 path).
    private static var usesDirectBinary: Bool {
        cachedBinaryPath?.hasSuffix("pymobiledevice3") == true
            && cachedBinaryPath?.contains("python") != true
    }

    /// Build command and arguments for running pymobiledevice3.
    private static func buildCommand(subcommands: [String]) -> (cmd: String, args: [String])? {
        guard let binary = findBinary() else { return nil }
        if usesDirectBinary {
            return (cmd: binary, args: subcommands)
        } else {
            // It's a python3 path - use -m
            return (cmd: binary, args: ["-m", "pymobiledevice3"] + subcommands)
        }
    }

    /// Check if pymobiledevice3 is installed and accessible.
    static func available() -> Bool {
        findBinary() != nil
    }

    /// Run a pymobiledevice3 subcommand synchronously.
    @discardableResult
    static func run(_ subcommands: [String], timeout: TimeInterval = 60) -> Shell.Result {
        guard let cmd = buildCommand(subcommands: subcommands) else {
            return Shell.Result(exitCode: -1, stdout: "", stderr: "pymobiledevice3 not found")
        }
        return Shell.run(cmd.cmd, arguments: cmd.args, timeout: timeout)
    }

    /// Run a pymobiledevice3 subcommand asynchronously.
    static func runAsync(_ subcommands: [String], timeout: TimeInterval = 300) async -> Shell.Result {
        guard let cmd = buildCommand(subcommands: subcommands) else {
            return Shell.Result(exitCode: -1, stdout: "", stderr: "pymobiledevice3 not found")
        }
        return await Shell.runAsync(cmd.cmd, arguments: cmd.args, timeout: timeout)
    }

    /// Run a pymobiledevice3 command with real-time output streaming.
    /// Returns the Process reference so callers can terminate it.
    @discardableResult
    static func runStreaming(
        _ subcommands: [String],
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        guard let cmd = buildCommand(subcommands: subcommands) else {
            onError("pymobiledevice3 not found")
            completion(-1)
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: cmd.cmd)
        process.arguments = cmd.args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["PATH"] = extendedPath

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { onOutput(str) }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { onError(str) }
            }
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { completion(proc.terminationStatus) }
        }

        do {
            try process.run()
            return process
        } catch {
            onError("Failed to launch pymobiledevice3: \(error.localizedDescription)")
            completion(-1)
            return nil
        }
    }

    // MARK: - Device Discovery

    /// List connected device UDIDs via usbmux.
    static func listDevices() async -> [String] {
        let result = await runAsync(["usbmux", "list"])
        guard result.succeeded else { return [] }

        // Output is typically JSON array or one UDID per line
        let output = result.output
        // Try JSON parse first
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return json.compactMap { $0["UniqueDeviceID"] as? String ?? $0["SerialNumber"] as? String }
        }

        // Fallback: line-based parsing
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 20 }
    }

    // MARK: - Device Info

    /// Get full device info as key-value pairs.
    static func deviceInfo(udid: String? = nil) async -> [String: String] {
        var args = ["lockdown", "info"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else { return [:] }
        return result.output.parseKeyValuePairs()
    }

    /// Get device name.
    static func deviceName(udid: String? = nil) async -> String? {
        var args = ["lockdown", "device-name"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args, timeout: 10)
        return result.succeeded ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: - Battery & Diagnostics

    /// Get battery diagnostics.
    static func batteryInfo(udid: String? = nil) async -> [String: String] {
        var args = ["diagnostics", "battery"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else { return [:] }

        // Try JSON
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var dict: [String: String] = [:]
            for (key, value) in json { dict[key] = "\(value)" }
            return dict
        }

        return result.output.parseKeyValuePairs()
    }

    // MARK: - Pairing

    /// Pair with device.
    static func pair(udid: String? = nil) async -> Bool {
        var args = ["lockdown", "pair"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args)
        return result.succeeded
    }

    /// Unpair device.
    static func unpair(udid: String? = nil) async -> Bool {
        var args = ["lockdown", "unpair"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args)
        return result.succeeded
    }

    /// Validate pairing.
    static func validatePair(udid: String? = nil) async -> Bool {
        var args = ["lockdown", "validate"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 10)
        return result.succeeded
    }

    // MARK: - Screenshots

    /// Take screenshot and save to path.
    static func screenshot(udid: String? = nil, saveTo path: String) async -> Bool {
        // Try developer screenshot first (requires DeveloperDiskImage)
        var args = ["developer", "screenshot", path]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 30)
        if result.succeeded { return true }

        // Fallback: springboard screenshot
        var springArgs = ["springboard", "screenshot", path]
        if let udid { springArgs += ["--udid", udid] }
        let springResult = await runAsync(springArgs, timeout: 30)
        return springResult.succeeded
    }

    // MARK: - Device Actions

    static func restart(udid: String? = nil) async -> Bool {
        var args = ["diagnostics", "restart"]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    static func shutdown(udid: String? = nil) async -> Bool {
        var args = ["diagnostics", "shutdown"]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    static func sleep(udid: String? = nil) async -> Bool {
        var args = ["diagnostics", "sleep"]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    // MARK: - AFC (Apple File Conduit)

    /// List files at a remote path on device.
    static func afcList(path: String, udid: String? = nil) async -> [String] {
        var args = ["afc", "ls", path]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else { return [] }

        return result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Pull (download) file/directory from device to local path.
    static func afcPull(remotePath: String, localPath: String, udid: String? = nil) async -> Bool {
        var args = ["afc", "pull", remotePath, localPath]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 600)
        return result.succeeded
    }

    /// Push (upload) local file to device.
    static func afcPush(localPath: String, remotePath: String, udid: String? = nil) async -> Bool {
        var args = ["afc", "push", localPath, remotePath]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 600)
        return result.succeeded
    }

    /// Remove file on device.
    static func afcRemove(path: String, udid: String? = nil) async -> Bool {
        var args = ["afc", "rm", path]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    // MARK: - Apps

    /// List installed apps. Returns JSON array.
    static func appsList(udid: String? = nil) async -> [[String: Any]] {
        var args = ["apps", "list"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args, timeout: 60)
        guard result.succeeded else { return [] }

        // Try JSON
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return json
        }

        // Try as dict of dicts (pymobiledevice3 format: {bundleId: {info}})
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            return json.map { (key, value) in
                var entry = value
                entry["CFBundleIdentifier"] = key
                return entry
            }
        }

        return []
    }

    /// Install app from IPA path.
    static func installApp(path: String, udid: String? = nil) async -> Bool {
        var args = ["apps", "install", path]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 300)
        return result.succeeded
    }

    /// Uninstall app by bundle ID.
    static func uninstallApp(bundleId: String, udid: String? = nil) async -> Bool {
        var args = ["apps", "uninstall", bundleId]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    // MARK: - Backup

    /// Create a backup.
    static func backup(
        directory: String,
        udid: String? = nil,
        full: Bool = true,
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        var args = ["backup2", "backup"]
        if full { args.append("--full") }
        if let udid { args += ["--udid", udid] }
        args.append(directory)

        return runStreaming(args, onOutput: onOutput, onError: onError, completion: completion)
    }

    /// Restore a backup.
    static func restore(
        directory: String,
        udid: String? = nil,
        system: Bool = true,
        reboot: Bool = true,
        onOutput: @escaping (String) -> Void,
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        var args = ["backup2", "restore"]
        if system { args.append("--system") }
        if reboot { args.append("--reboot") }
        if let udid { args += ["--udid", udid] }
        args.append(directory)

        return runStreaming(args, onOutput: onOutput, completion: completion)
    }

    /// Check/change encryption.
    static func encryptionStatus(udid: String? = nil) async -> Bool {
        var args = ["backup2", "encryption"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args)
        return result.output.lowercased().contains("on") || result.output.lowercased().contains("enabled")
    }

    static func setEncryption(enabled: Bool, password: String, udid: String? = nil) async -> Bool {
        var args = ["backup2", "encryption", enabled ? "on" : "off", password]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    static func changeEncryptionPassword(oldPassword: String, newPassword: String, udid: String? = nil) async -> Bool {
        var args = ["backup2", "change-password", oldPassword, newPassword]
        if let udid { args += ["--udid", udid] }
        return (await runAsync(args)).succeeded
    }

    // MARK: - Syslog

    /// Start streaming syslog. Returns Process for termination.
    static func startSyslog(
        udid: String? = nil,
        onOutput: @escaping (String) -> Void,
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        var args = ["syslog", "live"]
        if let udid { args += ["--udid", udid] }
        return runStreaming(args, onOutput: onOutput, completion: completion)
    }

    // MARK: - Crash Reports

    /// Pull crash reports to local directory.
    static func pullCrashReports(to directory: String, udid: String? = nil) async -> Bool {
        var args = ["crash", "pull", directory]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 120)
        return result.succeeded
    }

    // MARK: - Process List

    /// Get running processes on device.
    static func processList(udid: String? = nil) async -> [[String: Any]] {
        var args = ["developer", "dvt", "proclist"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args, timeout: 30)
        guard result.succeeded else { return [] }

        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return json
        }
        return []
    }

    // MARK: - Companion (Apple Watch)

    /// List paired companion devices (Apple Watch).
    static func companionList(udid: String? = nil) async -> [[String: Any]] {
        var args = ["companion", "list"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args, timeout: 15)
        guard result.succeeded else { return [] }

        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return json
        }
        return []
    }

    // MARK: - Network Discovery

    /// List devices available over network.
    static func listNetworkDevices() async -> [String] {
        let result = await runAsync(["usbmux", "list", "--network"], timeout: 10)
        guard result.succeeded else { return [] }

        let output = result.output
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return json.compactMap { $0["UniqueDeviceID"] as? String }
        }

        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 20 }
    }

    // MARK: - Utility

    /// Parse backup progress from pymobiledevice3 tqdm output.
    /// Matches patterns like "42%|..." or "Progress: 42%"
    static func parseProgress(from text: String) -> Double? {
        let pattern = #"(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        return value / 100.0
    }
}
