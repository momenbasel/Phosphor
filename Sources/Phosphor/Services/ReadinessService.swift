import Foundation

/// High-level readiness status for user-facing setup and safety checks.
enum ReadinessStatus: String {
    case ready = "Ready"
    case warning = "Warning"
    case blocked = "Blocked"
    case info = "Info"
}

/// Recovery operation that can be launched directly from a readiness row after user confirmation.
enum ReadinessOperation: Hashable {
    case deleteIncompleteBackupAndRunFull(udid: String, path: String)
}

/// One actionable readiness row shown in the Readiness Center and diagnostic report.
struct ReadinessItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String
    let status: ReadinessStatus
    let recoveryAction: String?
    let technicalDetail: String?
    let operation: ReadinessOperation?

    init(
        title: String,
        detail: String,
        status: ReadinessStatus,
        recoveryAction: String? = nil,
        technicalDetail: String? = nil,
        operation: ReadinessOperation? = nil
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.recoveryAction = recoveryAction
        self.technicalDetail = technicalDetail
        self.operation = operation
    }
}

/// Snapshot of whether Phosphor is ready for common user-facing workflows.
struct ReadinessReport {
    let generatedAt: Date
    let items: [ReadinessItem]
    let backupDirectory: String
    let connectedDeviceCount: Int
    let wifiDeviceCount: Int
    let nearbyWirelessHintCount: Int

    var hasBlockers: Bool { items.contains { $0.status == .blocked } }
    var hasWarnings: Bool { items.contains { $0.status == .warning } }

    var summary: String {
        if hasBlockers { return "Setup needs attention before backups and exports are reliable." }
        if hasWarnings { return "Phosphor is usable, with a few recommended fixes." }
        return "Phosphor is ready for backups, browsing, diagnostics, and exports."
    }

    var diagnosticMarkdown: String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = [
            "# Phosphor Diagnostic Report",
            "",
            "Generated: \(formatter.string(from: generatedAt))",
            "Summary: \(summary)",
            "Backup Directory: \(Self.redactedValue(backupDirectory))",
            "Connected Devices: \(connectedDeviceCount)",
            "Backup-capable Wi-Fi Devices: \(wifiDeviceCount)",
            "Nearby Finder/Bonjour Hints: \(nearbyWirelessHintCount)",
            "",
            "## Readiness Items"
        ]

        for item in items {
            lines.append("- [\(item.status.rawValue)] \(item.title): \(Self.redactedValue(item.detail))")
            if let recoveryAction = item.recoveryAction, !recoveryAction.isEmpty {
                lines.append("  - Recovery: \(Self.redactedValue(recoveryAction))")
            }
            if let technicalDetail = item.technicalDetail, !technicalDetail.isEmpty {
                lines.append("  - Technical: \(Self.redactedValue(technicalDetail))")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Privacy",
            "This report intentionally avoids UDIDs, serial numbers, phone numbers, and device names. Paths are home-folder redacted."
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    private static func redactedValue(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var redacted = value.replacingOccurrences(of: home, with: "~")
        redacted = replacing(pattern: "\\b[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}\\b", in: redacted, with: "<device-id>")
        redacted = replacing(pattern: "\\b[A-Fa-f0-9]{40}\\b", in: redacted, with: "<device-id>")
        return redacted
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

enum ReadinessService {
    /// Check CLI dependencies off the main actor without consuming an unbounded global
    /// dispatch worker from SwiftUI views. Shell.checkDependencies remains synchronous,
    /// but Task.detached keeps first paint and view updates responsive.
    static func dependencyStatus() async -> [String: Bool] {
        await Task.detached(priority: .utility) {
            Shell.checkDependencies()
        }.value
    }

    @MainActor
    static func evaluate(
        devices: [DeviceInfo],
        nearbyWirelessDevices: [PyMobileDevice.BonjourDevice],
        backupDirectory: String
    ) async -> ReadinessReport {
        async let dependencies = dependencyStatus()
        let dependencyMap = await dependencies

        var items: [ReadinessItem] = []
        items.append(toolReadinessItem(dependencyMap))
        items.append(await backupFolderItem(path: backupDirectory))
        if let warning = BackupManager.backupDirectoryWarning(for: backupDirectory) {
            items.append(ReadinessItem(
                title: "Backup Folder Warning",
                detail: warning,
                status: .warning,
                recoveryAction: "Choose a local folder such as ~/Documents/Phosphor Backups for active iOS backups.",
                technicalDetail: backupDirectory
            ))
        }

        items.append(contentsOf: incompleteBackupItems(in: backupDirectory, devices: devices))
        items.append(deviceVisibilityItem(devices: devices, nearbyWirelessDevices: nearbyWirelessDevices))
        items.append(wifiBackupItem(devices: devices, nearbyWirelessDevices: nearbyWirelessDevices))
        items.append(ReadinessItem(
            title: "Safe Operations",
            detail: "Exports, imports, deletes, and backup actions should show a clear destination or destructive-action summary before changing files.",
            status: .info,
            recoveryAction: "Review the action summary before confirming; prefer Reveal in Finder after exports."
        ))
        items.append(ReadinessItem(
            title: "Diagnostic Report",
            detail: "A redacted Markdown report can be exported for bug reports without UDIDs, serial numbers, phone numbers, or device names.",
            status: .info,
            recoveryAction: "Use Export Diagnostic Report before filing an issue."
        ))
        items.append(ReadinessItem(
            title: "Next Steps",
            detail: nextSteps(devices: devices, dependencies: dependencyMap),
            status: nextStepStatus(devices: devices, dependencies: dependencyMap)
        ))

        return ReadinessReport(
            generatedAt: Date(),
            items: items,
            backupDirectory: backupDirectory,
            connectedDeviceCount: devices.count,
            wifiDeviceCount: devices.filter { $0.connectionType == .wifi }.count,
            nearbyWirelessHintCount: nearbyWirelessDevices.count
        )
    }

    private static func toolReadinessItem(_ dependencies: [String: Bool]) -> ReadinessItem {
        let hasPymobiledevice = dependencies["pymobiledevice3"] == true
        let hasLibimobiledeviceBackup = dependencies["idevice_id"] == true &&
            dependencies["ideviceinfo"] == true &&
            dependencies["idevicebackup2"] == true
        let missing = dependencies.filter { !$0.value }.map(\.key).sorted()

        if hasPymobiledevice || hasLibimobiledeviceBackup {
            let detail = hasPymobiledevice
                ? "pymobiledevice3 is available for modern iOS workflows; libimobiledevice tools remain optional fallbacks."
                : "libimobiledevice backup tools are available; install pymobiledevice3 for best iOS 17-26 support."
            return ReadinessItem(
                title: "Tool Readiness",
                detail: detail,
                status: hasPymobiledevice ? .ready : .warning,
                recoveryAction: hasPymobiledevice ? nil : "Install pymobiledevice3 with pipx or Homebrew."
            )
        }

        return ReadinessItem(
            title: "Tool Readiness",
            detail: "No supported iOS command-line backend is available.",
            status: .blocked,
            recoveryAction: "Install pymobiledevice3, or install libimobiledevice tools including idevice_id, ideviceinfo, and idevicebackup2.",
            technicalDetail: missing.isEmpty ? nil : "Missing tools: \(missing.joined(separator: ", "))"
        )
    }

    private static func backupFolderItem(path: String) async -> ReadinessItem {
        let locationPreflight = await BackupLocationMonitor.preflightForWrite(path: path)
        if locationPreflight.status == .offline {
            return ReadinessItem(
                title: "Network Backup Location",
                detail: locationPreflight.message ?? "The saved network backup location is offline.",
                status: .warning,
                recoveryAction: "Reconnect or mount the saved network volume. Phosphor will refresh automatically when it returns.",
                technicalDetail: path
            )
        }
        if locationPreflight.status == .invalid {
            return ReadinessItem(
                title: "Backup Folder",
                detail: locationPreflight.message ?? "The active backup folder is not safe to use.",
                status: .blocked,
                recoveryAction: "Open Settings and choose the folder again before writing backups.",
                technicalDetail: path
            )
        }
        if locationPreflight.status == .available {
            return ReadinessItem(
                title: "Network Backup Location",
                detail: "The saved network backup location is mounted, readable, and writable.",
                status: .ready,
                technicalDetail: path
            )
        }
        let validation = await MainActor.run {
            BackupManager.validateBackupDirectory(path, createIfMissing: false)
        }
        if validation.ok {
            return ReadinessItem(
                title: "Backup Folder",
                detail: "The active backup folder is readable and writable.",
                status: .ready,
                technicalDetail: path
            )
        }
        return ReadinessItem(
            title: "Backup Folder",
            detail: validation.reason ?? "The active backup folder is not usable.",
            status: .blocked,
            recoveryAction: "Open Settings and choose a user-owned local backup folder such as ~/Documents/Phosphor Backups.",
            technicalDetail: path
        )
    }

    @MainActor
    private static func incompleteBackupItems(in directory: String, devices: [DeviceInfo]) -> [ReadinessItem] {
        var candidates = Set(devices.map(\.id))
        let fm = FileManager.default
        let childNames = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        for childName in childNames {
            let childPath = (directory as NSString).appendingPathComponent(childName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard BackupManager.incompleteBackupHasKnownMarkers(childPath) else { continue }
            candidates.insert(childName)
        }

        return candidates.compactMap { udid in
            guard case .incomplete(let path) = BackupManager.backupMetadataHealth(for: udid, in: directory) else {
                return nil
            }
            return ReadinessItem(
                title: "Incomplete Backup Found",
                detail: "A previous backup for this device did not finish, so iOS may reject another backup in this folder.",
                status: .blocked,
                recoveryAction: "Move the incomplete folder to Trash, then run a fresh full backup with the device unlocked and connected over USB when possible.",
                technicalDetail: path,
                operation: .deleteIncompleteBackupAndRunFull(udid: udid, path: path)
            )
        }
        .sorted { ($0.technicalDetail ?? $0.title) < ($1.technicalDetail ?? $1.title) }
    }

    private static func deviceVisibilityItem(
        devices: [DeviceInfo],
        nearbyWirelessDevices: [PyMobileDevice.BonjourDevice]
    ) -> ReadinessItem {
        if !devices.isEmpty {
            let usb = devices.filter { $0.connectionType == .usb }.count
            let wifi = devices.filter { $0.connectionType == .wifi }.count
            return ReadinessItem(
                title: "Device Visibility",
                detail: "Phosphor sees \(devices.count) backup-capable device(s): \(usb) USB, \(wifi) Wi-Fi.",
                status: .ready
            )
        }
        if !nearbyWirelessDevices.isEmpty {
            return ReadinessItem(
                title: "Device Visibility",
                detail: "macOS/Finder can see \(nearbyWirelessDevices.count) nearby wireless iOS device hint(s), but Phosphor does not yet have a backup-capable usbmux/lockdown connection.",
                status: .warning,
                recoveryAction: "Connect over USB once, unlock the device, tap Trust, enable Wi-Fi sync in Finder, then refresh Phosphor."
            )
        }
        return ReadinessItem(
            title: "Device Visibility",
            detail: "No USB, backup-capable Wi-Fi, or Finder/Bonjour-visible iOS device is currently visible.",
            status: .warning,
            recoveryAction: "Unlock the iPhone or iPad, connect via USB, tap Trust, then refresh."
        )
    }

    @MainActor
    private static func wifiBackupItem(
        devices: [DeviceInfo],
        nearbyWirelessDevices: [PyMobileDevice.BonjourDevice]
    ) -> ReadinessItem {
        let wifiDevices = devices.filter { $0.connectionType == .wifi }
        if wifiDevices.isEmpty {
            if nearbyWirelessDevices.isEmpty {
                return ReadinessItem(
                    title: "Wi-Fi Backup",
                    detail: "No backup-capable Wi-Fi device is visible right now.",
                    status: .info,
                    recoveryAction: "Use USB for first setup; Wi-Fi backups become available after pairing and Finder Wi-Fi sync are working."
                )
            }
            return ReadinessItem(
                title: "Wi-Fi Backup",
                detail: "Nearby wireless hints are visible, but Phosphor will not enable backup actions until usbmux/lockdown reports a real device UDID.",
                status: .warning,
                recoveryAction: "Use USB once to establish trust, then verify `pymobiledevice3 usbmux list --network` or `idevice_id -n` can see the device."
            )
        }

        let devicesWithoutFullBackup = wifiDevices.filter { !BackupManager.hasExistingBackup(for: $0.id) }
        if devicesWithoutFullBackup.isEmpty {
            return ReadinessItem(
                title: "Wi-Fi Backup",
                detail: "Wi-Fi backup-capable devices are visible and have existing backup metadata for incremental runs.",
                status: .ready
            )
        }
        return ReadinessItem(
            title: "Wi-Fi Backup",
            detail: "At least one Wi-Fi device does not have complete backup metadata yet; the first run must be a full backup.",
            status: .warning,
            recoveryAction: "Run the first full backup over USB when practical, or explicitly confirm the longer first full Wi-Fi backup."
        )
    }

    private static func nextSteps(devices: [DeviceInfo], dependencies: [String: Bool]) -> String {
        if !hasBackupTooling(dependencies) {
            return "Install the required device tools, then re-run the readiness check."
        }
        if devices.isEmpty {
            return "Connect and trust a device, then choose a user-owned backup folder before starting backups or exports."
        }
        return "Start with a fresh backup, then use Messages, Photos, Files, or Diagnostics from the sidebar."
    }

    private static func nextStepStatus(devices: [DeviceInfo], dependencies: [String: Bool]) -> ReadinessStatus {
        if !hasBackupTooling(dependencies) { return .blocked }
        if devices.isEmpty { return .warning }
        return .ready
    }

    private static func hasBackupTooling(_ dependencies: [String: Bool]) -> Bool {
        dependencies["pymobiledevice3"] == true ||
            (dependencies["idevice_id"] == true &&
             dependencies["ideviceinfo"] == true &&
             dependencies["idevicebackup2"] == true)
    }
}
