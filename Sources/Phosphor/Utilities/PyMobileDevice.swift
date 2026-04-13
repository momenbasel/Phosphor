import Foundation

/// Central wrapper for pymobiledevice3 CLI. Primary backend for all iOS device operations.
/// pymobiledevice3 supports iOS 17+ (including iOS 26), unlike libimobiledevice.
/// All operations go through `python3 -m pymobiledevice3 <subcommand> [args]`.
enum PyMobileDevice {

    /// Check if pymobiledevice3 is installed and importable.
    static func available() -> Bool {
        let result = Shell.run("python3", arguments: ["-c", "import pymobiledevice3"])
        return result.succeeded
    }

    /// Run a pymobiledevice3 subcommand synchronously.
    @discardableResult
    static func run(_ subcommands: [String], timeout: TimeInterval = 60) -> Shell.Result {
        Shell.run("python3", arguments: ["-m", "pymobiledevice3"] + subcommands, timeout: timeout)
    }

    /// Run a pymobiledevice3 subcommand asynchronously.
    static func runAsync(_ subcommands: [String], timeout: TimeInterval = 300) async -> Shell.Result {
        await Shell.runAsync("python3", arguments: ["-m", "pymobiledevice3"] + subcommands, timeout: timeout)
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
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "pymobiledevice3"] + subcommands
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        if var path = process.environment?["PATH"] {
            path = "/opt/homebrew/bin:/usr/local/bin:" + path
            process.environment?["PATH"] = path
        }

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
