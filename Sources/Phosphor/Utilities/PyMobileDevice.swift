import Foundation

/// Central wrapper for pymobiledevice3 CLI. Primary backend for all iOS device operations.
/// pymobiledevice3 supports iOS 17+ (including iOS 26), unlike libimobiledevice.
/// Searches for pymobiledevice3 binary at common install locations (pipx, pip, venv).
enum PyMobileDevice {

    /// Cached path to the pymobiledevice3 binary once found.
    private static var cachedBinaryPath: String?

    /// Python minor versions to probe for pipx or pip --user installs and system Python.
    private static let pythonMinorVersions = ["3.14", "3.13", "3.12", "3.11", "3.10"]

    /// Extended PATH for GUI apps that don't inherit terminal PATH.
    private static let extendedPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var extra = [
            "\(home)/.local/bin",
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        extra.append(contentsOf: pythonMinorVersions.map { "\(home)/Library/Python/\($0)/bin" })
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return extra.joined(separator: ":") + ":" + existing
    }()

    /// Find the pymobiledevice3 binary. Checks direct binary first (pipx, pip --user),
    /// then python3 -m pymobiledevice3 at various Python locations.
    private static func findBinary() -> String? {
        if let cached = cachedBinaryPath { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        // Direct binary locations (pipx, pip --user, Homebrew)
        var directPaths = [
            "\(home)/.local/bin/pymobiledevice3",
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
        ]
        // `pipx install pymobiledevice3` or older pip --user installs may drop the script here.
        directPaths.append(contentsOf: pythonMinorVersions.map {
            "\(home)/Library/Python/\($0)/bin/pymobiledevice3"
        })

        for path in directPaths {
            if fm.isExecutableFile(atPath: path), directBinaryWorks(at: path) {
                cachedBinaryPath = path
                return path
            }
        }

        // Try python3 -m pymobiledevice3 with various pythons
        var pythons = [
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        pythons.append(contentsOf: pythonMinorVersions.map { "/opt/homebrew/bin/python\($0)" })
        pythons.append(contentsOf: pythonMinorVersions.map { "/usr/local/bin/python\($0)" })

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

    /// Validate direct console-script shims before caching them. A stale pip/pipx
    /// shim can remain executable even when its Python environment was removed
    /// or upgraded, which would otherwise make Phosphor report pymobiledevice3 as
    /// installed and then fail every operation at runtime.
    private static func directBinaryWorks(at path: String) -> Bool {
        let version = Shell.run(path, arguments: ["version"], timeout: 10)
        if version.succeeded { return true }
        let alt = Shell.run(path, arguments: ["--version"], timeout: 10)
        return alt.succeeded
    }

    /// Clear the cached binary path so the next call re-probes the filesystem.
    /// Useful after the user installs or upgrades pymobiledevice3 mid-session.
    static func resetBinaryCache() {
        cachedBinaryPath = nil
    }

    /// Query installed pymobiledevice3 version, or nil if unavailable.
    static func version() async -> String? {
        guard findBinary() != nil else { return nil }
        let result = await runAsync(["version"], timeout: 10)
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded, !trimmed.isEmpty { return trimmed }
        // Some versions respond to --version instead.
        let alt = await runAsync(["--version"], timeout: 10)
        let altTrimmed = alt.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.succeeded && !altTrimmed.isEmpty ? altTrimmed : nil
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

    /// Expose binary path for tunnel launching.
    static func findBinaryPath() -> String? {
        findBinary()
    }

    /// Sudo-safe command for `pymobiledevice3 remote tunneld` that works even
    /// when sudo's secure_path strips the user's PATH (issue #11).
    /// Falls back to a generic command when the binary cannot be located yet.
    static func tunneldCommand() -> String {
        guard let binary = findBinary() else {
            return "sudo -E env \"PATH=$PATH\" pymobiledevice3 remote tunneld"
        }
        if usesDirectBinary {
            return "sudo \"\(binary)\" remote tunneld"
        } else {
            return "sudo \"\(binary)\" -m pymobiledevice3 remote tunneld"
        }
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
        timeout: TimeInterval? = nil,
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        guard let cmd = buildCommand(subcommands: subcommands) else {
            onError("pymobiledevice3 not found")
            completion(-1)
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = extendedPath
        return Shell.runStreaming(
            cmd.cmd,
            arguments: cmd.args,
            timeout: timeout,
            environment: environment,
            onOutput: onOutput,
            onError: onError,
            completion: completion
        )
    }

    // MARK: - Device Discovery

    /// List connected device UDIDs via usbmux.
    static func listDevices() async -> [String] {
        await listDevicesWithType().map(\.udid)
    }

    struct DeviceEntry {
        let udid: String
        let connectionType: String // "USB" or "Network"
        let discoveryMethod: String
        var discoveryInfo: [String: String]

        init(
            udid: String,
            connectionType: String,
            discoveryMethod: String = "usbmux",
            discoveryInfo: [String: String] = [:]
        ) {
            self.udid = udid
            self.connectionType = connectionType
            self.discoveryMethod = discoveryMethod
            self.discoveryInfo = discoveryInfo
        }
    }

    struct DeviceDiscoveryResult {
        let entries: [DeviceEntry]
        let usbProbeSucceeded: Bool
        let networkProbeSucceeded: Bool
        let fallbackProbeSucceeded: Bool?

        /// Only transport-specific probes can prove an omitted device is absent.
        /// The default fallback helps older pymobiledevice3 versions, but is not
        /// an authoritative transport snapshot.
        var isAuthoritative: Bool {
            usbProbeSucceeded && networkProbeSucceeded
        }

        var failureDescription: String? {
            guard !isAuthoritative else { return nil }
            var failed: [String] = []
            if !usbProbeSucceeded { failed.append("USB") }
            if !networkProbeSucceeded { failed.append("Wi-Fi") }
            return "pymobiledevice3 \(failed.joined(separator: " and ")) discovery failed; showing the last known compatible devices and retrying."
        }
    }

    struct BonjourDevice: Hashable {
        let id: String
        let name: String
        let host: String?
        let serviceName: String
    }

    /// List connected devices with connection type (USB vs Network/Wi-Fi).
    ///
    /// Query USB and network explicitly before merging. Some pymobiledevice3
    /// versions either omit Wi-Fi devices from the default usbmux snapshot or
    /// omit ConnectionType there, which can make paired Wi-Fi devices disappear
    /// or be misclassified as USB.
    static func listDevicesWithType() async -> [DeviceEntry] {
        await discoverDevicesWithType().entries.filter {
            $0.connectionType == "USB" || $0.connectionType == "Network"
        }
    }

    /// Return both entries and probe authority so callers do not collapse a
    /// timeout or tool failure into an authoritative empty snapshot.
    static func discoverDevicesWithType() async -> DeviceDiscoveryResult {
        // Discovery runs inside DeviceManager's recurring scan. Keep every
        // branch bounded so one wedged pymobiledevice3 process cannot leave
        // isScanning set for runAsync's five-minute default and suppress all
        // routine polls or an explicit Refresh Devices action in the meantime.
        async let usbResult = runAsync(["usbmux", "list", "--usb"], timeout: 5)
        async let networkResult = runAsync(["usbmux", "list", "--network"], timeout: 5)

        var entries: [DeviceEntry] = []
        let usb = await usbResult
        if usb.succeeded {
            entries += parseUsbmuxDeviceEntries(from: usb.output, defaultConnectionType: "USB")
        }

        let network = await networkResult
        if network.succeeded {
            entries += parseUsbmuxDeviceEntries(from: network.output, defaultConnectionType: "Network")
        }

        var fallbackSucceeded: Bool?
        if entries.isEmpty {
            let fallback = await runAsync(["usbmux", "list"], timeout: 5)
            fallbackSucceeded = fallback.succeeded
            if fallback.succeeded {
                // The unfiltered command can contain either transport. Older
                // versions sometimes omit ConnectionType, so do not fabricate
                // USB provenance for an entry whose route is actually unknown.
                entries = parseUsbmuxDeviceEntries(from: fallback.output, defaultConnectionType: "Unknown")
            }
        }

        return DeviceDiscoveryResult(
            entries: mergeDeviceEntries(entries),
            usbProbeSucceeded: usb.succeeded,
            networkProbeSucceeded: network.succeeded,
            fallbackProbeSucceeded: fallbackSucceeded
        )
    }

    /// List devices currently reachable over network/Wi-Fi with connection metadata.
    static func listNetworkDeviceEntries() async -> [DeviceEntry] {
        let result = await runAsync(["usbmux", "list", "--network"], timeout: 10)
        guard result.succeeded else { return [] }
        return parseUsbmuxDeviceEntries(from: result.output, defaultConnectionType: "Network")
    }

    /// List devices advertised by pymobiledevice3's mobdev2 Bonjour backend.
    ///
    /// This is the closest CLI path to Finder's wireless discovery on current
    /// iOS/macOS releases. Unlike raw dns-sd TXT identifiers, mobdev2 returns
    /// the real `UniqueDeviceID`, but it is still a discovery hint: current
    /// pymobiledevice3 backup commands may prompt when the same device is
    /// advertised on several addresses, which is unsafe in Phosphor's non-TTY
    /// process runner.
    static func listMobdev2DeviceEntries() async -> [DeviceEntry] {
        let result = await runAsync(["bonjour", "mobdev2", "--timeout", "3"], timeout: 6)
        guard result.succeeded else { return [] }
        return parseMobdev2DeviceEntries(from: result.output)
    }

    /// List iOS devices advertised through Apple's Bonjour MobileDevice service.
    ///
    /// Finder can show a wirelessly paired device through this path even when
    /// usbmux/lockdown tools cannot open a backup-capable connection yet. These
    /// entries are discovery hints only; callers should not treat them as backup
    /// targets because the Bonjour TXT identifier is not the device UDID.
    static func listBonjourMobileDevices(timeout: TimeInterval = 3) async -> [BonjourDevice] {
        let mobdev2Devices = await listMobdev2DeviceEntries()
        if !mobdev2Devices.isEmpty {
            return mobdev2Devices.map { entry in
                BonjourDevice(
                    id: entry.udid,
                    name: entry.discoveryInfo["DeviceName"] ?? "Wireless iPhone/iPad",
                    host: entry.discoveryInfo["ip"] ?? entry.discoveryInfo["Identifier"],
                    serviceName: "mobdev2"
                )
            }
        }

        let browse = await Shell.runAsync(
            "/usr/bin/dns-sd",
            arguments: ["-B", "_apple-mobdev2._tcp", "local"],
            timeout: timeout
        )
        let serviceNames = parseBonjourBrowseOutput(browse.stdout)
        guard !serviceNames.isEmpty else { return [] }

        var devices: [BonjourDevice] = []
        var seenIds: Set<String> = []
        for serviceName in serviceNames {
            let resolve = await Shell.runAsync(
                "/usr/bin/dns-sd",
                arguments: ["-L", serviceName, "_apple-mobdev2._tcp", "local"],
                timeout: timeout
            )
            let host = parseBonjourHost(from: resolve.stdout)
            let identifier = parseBonjourIdentifier(from: resolve.stdout)
            let id = identifier ?? host ?? serviceName
            guard seenIds.insert(id).inserted else { continue }
            devices.append(BonjourDevice(
                id: id,
                name: displayName(forBonjourHost: host) ?? "Wireless iPhone/iPad",
                host: host,
                serviceName: serviceName
            ))
        }

        return devices
    }

    private static func parseUsbmuxDeviceEntries(
        from output: String,
        defaultConnectionType: String
    ) -> [DeviceEntry] {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var byUdid: [String: DeviceEntry] = [:]
            var orderedUdids: [String] = []

            for entry in json {
                guard let udid = entry["Identifier"] as? String
                        ?? entry["UniqueDeviceID"] as? String
                        ?? entry["SerialNumber"] as? String else { continue }
                let connType = (entry["ConnectionType"] as? String)
                    ?? (entry["Properties"] as? [String: Any])?["ConnectionType"] as? String
                    ?? defaultConnectionType
                let isUSB = connType.lowercased().contains("usb") || connType == "1"
                let type = isUSB ? "USB" : "Network"

                if byUdid[udid] == nil { orderedUdids.append(udid) }
                if byUdid[udid]?.connectionType != "USB" || type == "USB" {
                    byUdid[udid] = DeviceEntry(udid: udid, connectionType: type)
                }
            }

            return orderedUdids.compactMap { byUdid[$0] }
        }

        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 20 }
            .map { DeviceEntry(udid: $0, connectionType: defaultConnectionType) }
    }

    private static func parseMobdev2DeviceEntries(from output: String) -> [DeviceEntry] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var byUdid: [String: DeviceEntry] = [:]
        var orderedUdids: [String] = []
        for entry in json {
            guard let udid = entry["UniqueDeviceID"] as? String else { continue }
            var info: [String: String] = [:]
            for (key, value) in entry {
                if let string = value as? String {
                    info[key] = string
                } else if let number = value as? NSNumber {
                    info[key] = "\(number)"
                }
            }

            if var existing = byUdid[udid] {
                for (key, value) in info where existing.discoveryInfo[key] == nil {
                    existing.discoveryInfo[key] = value
                }
                byUdid[udid] = existing
                continue
            }

            orderedUdids.append(udid)

            byUdid[udid] = DeviceEntry(
                udid: udid,
                connectionType: "Network",
                discoveryMethod: "mobdev2",
                discoveryInfo: info
            )
        }

        return orderedUdids.compactMap { byUdid[$0] }
    }

    private static func mergeDeviceEntries(_ entries: [DeviceEntry]) -> [DeviceEntry] {
        var byUdid: [String: DeviceEntry] = [:]
        var orderedUdids: [String] = []

        for entry in entries {
            if byUdid[entry.udid] == nil { orderedUdids.append(entry.udid) }
            // Prefer USB when both transports are currently present; otherwise
            // preserve Network so Wi-Fi-only backup paths can identify it.
            if byUdid[entry.udid]?.connectionType != "USB" || entry.connectionType == "USB" {
                byUdid[entry.udid] = entry
            }
        }

        return orderedUdids.compactMap { byUdid[$0] }
    }

    private static func parseBonjourBrowseOutput(_ output: String) -> [String] {
        var serviceNames: [String] = []
        var seen: Set<String> = []

        for line in output.components(separatedBy: "\n") {
            guard line.contains(" Add "),
                  let range = line.range(of: "_apple-mobdev2._tcp.") else { continue }
            let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            serviceNames.append(name)
        }

        return serviceNames
    }

    private static func parseBonjourHost(from output: String) -> String? {
        for line in output.components(separatedBy: "\n") where line.contains(" can be reached at ") {
            guard let start = line.range(of: " can be reached at ")?.upperBound else { continue }
            let suffix = line[start...]
            guard let end = suffix.range(of: ":")?.lowerBound else { continue }
            let host = String(suffix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty { return host }
        }
        return nil
    }

    private static func parseBonjourIdentifier(from output: String) -> String? {
        for token in output.components(separatedBy: .whitespacesAndNewlines) {
            guard token.hasPrefix("identifier=") else { continue }
            let id = String(token.dropFirst("identifier=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        return nil
    }

    private static func displayName(forBonjourHost host: String?) -> String? {
        guard var name = host?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        return name.replacingOccurrences(of: "\\032", with: " ")
    }

    // MARK: - Device Info

    /// Get full device info as key-value pairs. Parses JSON output from pymobiledevice3.
    static func deviceInfo(udid: String? = nil) async -> [String: String] {
        var args = ["lockdown", "info"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else { return [:] }

        // pymobiledevice3 outputs JSON
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var dict: [String: String] = [:]
            for (key, value) in json {
                if let str = value as? String {
                    dict[key] = str
                } else if let num = value as? NSNumber {
                    dict[key] = "\(num)"
                }
            }
            return dict
        }

        // Fallback: key-value text
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

    /// Get battery diagnostics (JSON output from `diagnostics battery single`).
    static func batteryInfo(udid: String? = nil) async -> [String: String] {
        var args = ["diagnostics", "battery", "single"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else { return [:] }

        // JSON output
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var dict: [String: String] = [:]
            for (key, value) in json {
                if let str = value as? String {
                    dict[key] = str
                } else if let num = value as? NSNumber {
                    dict[key] = "\(num)"
                } else if let bool = value as? Bool {
                    dict[key] = bool ? "true" : "false"
                }
            }
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

    /// Enable or disable Finder-style Wi-Fi connections for a USB-connected device.
    ///
    /// This maps to Finder's "Show this iPhone when on Wi-Fi" checkbox. It must be
    /// run while the device is reachable over USB/lockdown; Bonjour-only devices are
    /// discovery hints and cannot be promoted to backup-capable Wi-Fi targets here.
    static func setWiFiConnections(udid: String? = nil, enabled: Bool) async -> Shell.Result {
        var args = ["lockdown", "wifi-connections", "--state", enabled ? "on" : "off"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 20)
        return normalizeLockdownResult(result)
    }

    private static func normalizeLockdownResult(_ result: Shell.Result) -> Shell.Result {
        let combined = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .lowercased()
        let errorMarkers = ["error ", "error:", "device not found", "no device", "failed"]
        guard result.succeeded, errorMarkers.contains(where: { combined.contains($0) }) else {
            return result
        }
        let stderr = result.stderr.isEmpty ? "pymobiledevice3 reported an error despite exit code 0" : result.stderr
        return Shell.Result(exitCode: -1, stdout: result.stdout, stderr: stderr)
    }

    /// Unpair device.
    static func unpair(udid: String? = nil) async -> Bool {
        var args = ["lockdown", "unpair"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args)
        return result.succeeded
    }

    /// Validate pairing by querying device info (no validate subcommand in pymobiledevice3).
    static func validatePair(udid: String? = nil) async -> Bool {
        var args = ["lockdown", "info"]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 10)
        return result.succeeded && !result.output.isEmpty
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
    /// pymobiledevice3 outputs full paths like "/DCIM/100APPLE" - we extract just the name.
    static func afcList(path: String, udid: String? = nil) async -> [String] {
        await afcListRaw(path: path, udid: udid).entries
    }

    /// Detailed AFC list that preserves success/stderr so callers can distinguish
    /// "directory empty" from "permission denied" or "device not paired".
    struct AFCListResult {
        let succeeded: Bool
        let entries: [String]
        let stderr: String
    }

    static func afcListRaw(path: String, udid: String? = nil) async -> AFCListResult {
        var args = ["afc", "ls", path]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded else {
            return AFCListResult(succeeded: false, entries: [], stderr: result.stderr)
        }

        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        let entries = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line -> String? in
                if line == path || line == path + "/" { return nil }
                if line.hasPrefix(normalizedPath) {
                    let name = String(line.dropFirst(normalizedPath.count))
                    return name.isEmpty ? nil : name
                }
                let name = (line as NSString).lastPathComponent
                return name.isEmpty || name == "." || name == ".." ? nil : name
            }
        return AFCListResult(succeeded: true, entries: entries, stderr: result.stderr)
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
        preferNetwork: Bool = false,
        timeout: TimeInterval? = 6 * 60 * 60,
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        var args = ["backup2", "backup"]
        if full { args.append("--full") }
        // `--mobdev2` can prompt when the same wireless device is advertised on
        // multiple addresses, which crashes in Phosphor's non-interactive
        // Process runner. For Wi-Fi backups, let the libimobiledevice fallback
        // use `idevicebackup2 -n` instead of invoking an interactive CLI path.
        _ = preferNetwork
        if let udid { args += ["--udid", udid] }
        args.append(directory)

        return runStreaming(args, timeout: timeout, onOutput: onOutput, onError: onError, completion: completion)
    }

    /// Restore a backup.
    static func restore(
        directory: String,
        udid: String? = nil,
        sourceUDID: String? = nil,
        system: Bool = true,
        reboot: Bool = true,
        timeout: TimeInterval? = 6 * 60 * 60,
        onOutput: @escaping (String) -> Void,
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        var args = ["backup2", "restore"]
        if system { args.append("--system") }
        if reboot { args.append("--reboot") }
        if let udid, !udid.isEmpty { args += ["--udid", udid] }
        // An empty --source is worse than none: pymobiledevice3 falls back to the
        // target device's own UDID, quietly turning a cross-device restore into a
        // same-device one. Omitting the flag makes that fallback explicit.
        if let sourceUDID, !sourceUDID.isEmpty { args += ["--source", sourceUDID] }
        args.append(directory)

        return runStreaming(args, timeout: timeout, onOutput: onOutput, completion: completion)
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
        await listNetworkDeviceEntries().map(\.udid)
    }

    // MARK: - Diagnostics IORegistry

    /// Query IORegistry for a named entry (battery, USB, etc). Returns parsed JSON dict.
    static func diagnosticsIORegistry(udid: String? = nil, name: String) async -> [String: Any] {
        var args = ["diagnostics", "ioregistry", "--plane", "IOService", "--name", name]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args, timeout: 15)
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - Full Lockdown Info

    /// Fetch complete lockdown info (100+ keys). Superset of deviceInfo().
    static func lockdownInfoFull(udid: String? = nil) async -> [String: Any] {
        var args = ["lockdown", "info"]
        if let udid { args += ["--udid", udid] }

        let result = await runAsync(args)
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - Developer Screenshot

    /// Take a screenshot via developer tools. Returns true on success.
    static func developerScreenshot(udid: String? = nil, outputPath: String) async -> Bool {
        var args = ["developer", "dvt", "screenshot", outputPath]
        if let udid { args += ["--udid", udid] }
        let result = await runAsync(args, timeout: 30)
        return result.succeeded
    }

    // MARK: - Location Simulation

    /// Set simulated GPS location on device. Tries iOS 17+ DVT path first, then legacy.
    static func simulateLocationSet(udid: String? = nil, latitude: Double, longitude: Double) async -> (success: Bool, stderr: String) {
        // iOS 17+: developer dvt simulate-location set (--udid MUST come before --)
        var dvtArgs = ["developer", "dvt", "simulate-location", "set"]
        if let udid { dvtArgs += ["--udid", udid] }
        dvtArgs += ["--", String(latitude), String(longitude)]
        let dvtResult = await runAsync(dvtArgs, timeout: 15)
        if dvtResult.succeeded { return (true, "") }

        // iOS < 17 fallback
        var legacyArgs = ["developer", "simulate-location", "set"]
        if let udid { legacyArgs += ["--udid", udid] }
        legacyArgs += ["--", String(latitude), String(longitude)]
        let legacyResult = await runAsync(legacyArgs, timeout: 15)
        if legacyResult.succeeded { return (true, "") }

        return (false, dvtResult.stderr + "\n" + legacyResult.stderr)
    }

    /// Clear simulated GPS location. Tries iOS 17+ DVT path first, then legacy.
    static func simulateLocationClear(udid: String? = nil) async -> Bool {
        // iOS 17+
        var dvtArgs = ["developer", "dvt", "simulate-location", "clear"]
        if let udid { dvtArgs += ["--udid", udid] }
        if (await runAsync(dvtArgs, timeout: 15)).succeeded { return true }

        // Legacy
        var legacyArgs = ["developer", "simulate-location", "clear"]
        if let udid { legacyArgs += ["--udid", udid] }
        return (await runAsync(legacyArgs, timeout: 15)).succeeded
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
