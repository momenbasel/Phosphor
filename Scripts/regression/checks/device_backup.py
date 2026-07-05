from __future__ import annotations

import re
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def assert_not_contains(text: str, needle: str, message: str) -> None:
    assert needle not in text, message


def test_pymobiledevice_queries_usb_and_network_before_fallback(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, 'runAsync(["usbmux", "list", "--usb"]', "device discovery must explicitly query USB devices")
    assert_contains(src, 'runAsync(["usbmux", "list", "--network"]', "device discovery must explicitly query network devices")
    assert_contains(src, 'runAsync(["usbmux", "list"])', "device discovery should retain default usbmux fallback")
    assert_contains(src, 'entry["ConnectionType"] as? String', "usbmux JSON parser should inspect top-level ConnectionType")
    assert_contains(src, '(entry["Properties"] as? [String: Any])?["ConnectionType"] as? String', "usbmux JSON parser should inspect nested Properties.ConnectionType")


def test_bonjour_finder_visible_devices_are_discovery_hints(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, "struct BonjourDevice", "Bonjour-discovered devices should use a separate hint model")
    assert_contains(src, '"/usr/bin/dns-sd"', "Bonjour fallback should use macOS dns-sd directly")
    assert_contains(src, '"_apple-mobdev2._tcp"', "Bonjour fallback should browse Apple's MobileDevice service")
    assert_contains(src, "parseBonjourBrowseOutput", "Bonjour browse output should be parsed explicitly")
    assert_contains(src, "parseBonjourHost", "Bonjour resolve output should preserve the advertised host")
    assert_contains(src, "not the device UDID", "Bonjour identifiers must not be treated as backup-capable UDIDs")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "nearbyWirelessDevices", "DeviceManager should publish Finder-visible wireless hints")
    assert_contains(manager, "cachedBonjourDevices", "Bonjour discovery should be cached to avoid polling dns-sd constantly")
    assert_contains(manager, "connectedDevices = []", "Bonjour-only devices should not be mixed into backup-capable devices")

    view = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert_contains(view, "Finder-visible devices", "Empty device state should disclose devices Finder can see")
    assert_contains(view, "Nearby, Not Backup-Ready", "Finder-visible-only devices should have a distinct non-backup-ready state")
    assert_contains(view, "cannot open a usbmux connection", "UI should explain why Finder visibility is not enough")


def test_mobdev2_wireless_discovery_is_a_non_backup_hint(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, '["bonjour", "mobdev2", "--timeout", "3"]', "wireless discovery should query pymobiledevice3 mobdev2 with a bounded browse timeout")
    assert_contains(src, "parseMobdev2DeviceEntries", "mobdev2 JSON should be parsed into typed device entries")
    assert_contains(src, 'entry["UniqueDeviceID"] as? String', "mobdev2 discovery must use the real device UDID")
    assert_contains(src, 'discoveryMethod: "mobdev2"', "mobdev2 entries should preserve their discovery method")
    assert_contains(src, "mobdev2Devices.map", "mobdev2 metadata should feed Finder-visible nearby-device hints")
    assert_contains(src, "still a discovery hint", "mobdev2 devices should not be treated as backup-capable targets")
    assert_not_contains(src, 'args.append("--mobdev2")', "pymobiledevice3 backup must not invoke interactive mobdev2 in a non-TTY app")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "cachedBonjourDevices", "DeviceManager should show mobdev2/Finder-visible devices as nearby hints")
    assert_contains(manager, "connectedDevices = []", "mobdev2-only devices should not be mixed into backup-capable devices")

    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(backup, "preferNetwork: preferNetwork", "BackupManager should thread Wi-Fi preference into pymobiledevice3 backup")


def test_device_entry_merge_prefers_usb_without_dropping_network_only(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    merge = re.search(r"private static func mergeDeviceEntries\(_ entries: \[DeviceEntry\]\).*?\n    \}", src, re.S)
    assert merge is not None, "PyMobileDevice.mergeDeviceEntries should exist"
    body = merge.group(0)
    assert_contains(body, "orderedUdids", "merge should preserve stable discovery order")
    assert_contains(body, 'connectionType != "USB" || entry.connectionType == "USB"', "merge should prefer USB when both transports are visible")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "deviceInfoCache.removeAll()", "zero-device scans should clear stale device cache")
    assert_contains(manager, "networkDeviceCache = nil", "zero-device scans should clear stale network-device cache")


def test_wifi_schedules_use_network_discovery_and_network_backup_flag(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    assert_contains(scheduler, "pyEntries.filter { $0.connectionType != \"USB\" }", "Wi-Fi-only schedules should filter out USB pymobiledevice entries")
    assert_contains(scheduler, "PyMobileDevice.listNetworkDevices()", "Wi-Fi-only schedules should probe network devices explicitly")
    assert_contains(scheduler, 'let fallbackArgs = schedule.wifiOnly ? ["-n"] : ["-l"]', "Wi-Fi-only fallback should use idevice_id -n")
    assert_contains(scheduler, "createIncrementalBackup(udid: udid, preferNetwork: preferNetwork)", "scheduled incremental backups should preserve network preference")
    assert_contains(scheduler, "createBackup(udid: udid, preferNetwork: preferNetwork)", "scheduled full backups should preserve network preference")
    assert_contains(scheduler, "schedule.incrementalOnly && BackupManager.hasExistingBackup(for: udid)", "Scheduled incremental mode should run the required first full backup when metadata is missing")
    assert_contains(scheduler, "running required first full backup", "Scheduled first-full fallback should be logged clearly")
    assert_contains(scheduler, "able to notice a schedule that is enabled after launch", "App-level scheduler should keep monitoring so schedules enabled after launch can run")
    assert_contains(scheduler, "if schedule.nextRunDate == nil { updateNextRunDate() }", "Scheduler should initialize next run when a separate UI instance enables the schedule")
    assert_contains(scheduler, "func runNow() async {\n        guard !isRunningScheduledBackup else { return }\n        isRunningScheduledBackup = true", "Run Now should set the running guard before async device discovery")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "Wi-Fi only (skip if Wi-Fi is not available)", "Wi-Fi-only schedule copy should not say USB is required")
    assert_contains(view, "Incremental when possible (faster)", "Schedule copy should not promise incremental-only behavior when first run may be full")
    assert_contains(view, "first scheduled run will create the required full backup", "Schedule UI should explain first-run behavior for incremental mode")
    assert_not_contains(view, "scheduler.startMonitoring()", "Schedule sheets should not start duplicate schedulers separate from the app-level monitor")
    assert_contains(view, ".onChange(of: scheduler.schedule.preferredHour)", "Schedule sheet should refresh next-run timing when preferred time changes")

    settings = read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")
    assert_contains(settings, "Wi-Fi only (skip if Wi-Fi is not available)", "Settings schedule copy should match the safer schedule sheet copy")
    assert_contains(settings, "Incremental when possible (faster)", "Settings should not promise incremental-only behavior when first run may be full")
    assert_contains(settings, ".onChange(of: scheduler.schedule.preferredHour)", "Settings should refresh next-run timing when preferred time changes")


def test_incremental_backups_require_existing_metadata(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "hasExistingBackup(for udid", "BackupManager should expose an existing-backup metadata preflight")
    assert_contains(manager, "backupMetadataHealth(for udid", "BackupManager should distinguish complete, missing, and incomplete backup metadata")
    assert_contains(manager, "if Self.looksLikeBackupFolder(dir)", "Single-backup discovery should exclude Info.plist-only incomplete folders")
    assert_contains(manager, "guard Self.looksLikeBackupFolder(fullPath) else { continue }", "Backup discovery should exclude incomplete child backup folders")
    assert_contains(manager, "looksLikeBackupFolder(deviceDirectory) ? .complete : .incomplete", "Existing-backup preflight should require Info.plist and Manifest metadata")
    assert_contains(manager, "isNonEmptyFile(info)", "Completeness must require non-empty metadata; zero-length Info.plist stubs are an interrupted backup, not a complete one")
    assert_contains(manager, "Backup needs a full backup first", "Incremental backup should fail before backend calls when metadata is missing")
    assert_contains(manager, "Run a full backup first; future Wi-Fi backups can be incremental", "Missing metadata error should be actionable")
    assert_contains(manager, "deleteIncompleteBackup(for udid", "Recovery flow should be able to remove interrupted partial backup folders")
    assert_contains(manager, "expectedPath", "Incomplete-backup recovery should validate the exact failed path before moving anything")
    assert_contains(manager, "incompleteBackupHasKnownMarkers", "Incomplete-backup recovery should require recognizable iOS backup markers before moving a folder")
    assert_contains(manager, "trashItem", "Incomplete-backup recovery should move folders to Trash instead of permanently deleting them")
    assert_not_contains(manager, "removeItem(atPath: path)", "Incomplete-backup recovery should not permanently delete backup folders")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "shouldOfferIncremental(for: device)", "Backup UI should only offer incremental when a backup exists for the selected device")
    assert_contains(view, "BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains", "Backup UI should require complete metadata before offering incremental")
    assert_contains(view, "First Wi-Fi Backup (Full)", "First Wi-Fi backup action should be full, not incremental")
    assert_contains(view, "Create Full Wi-Fi Backup", "Empty Wi-Fi backup state should default to a full backup")
    assert_contains(view, "First backup must be full", "Backup UI should explicitly explain first-backup state")
    assert_contains(view, "USB is recommended for the first backup", "Backup UI should recommend USB for first full backups")


def test_backup_failures_have_recovery_actions_and_collapsed_details(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "struct BackupFailure", "Backup failures should be structured for user-facing recovery UI")
    assert_contains(manager, "RecoveryAction", "Backup failures should carry recommended recovery actions")
    assert_contains(manager, "lastBackupFailure", "BackupManager should publish structured backup failures")
    assert_contains(manager, "technicalDetails", "Raw backend details should be separated from the short user-facing message")

    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "backupIssue", "BackupViewModel should surface structured backup issues separately from success alerts")
    assert_contains(vm, "retryLastBackup", "BackupViewModel should support recommended retry action")
    assert_contains(vm, "deleteIncompleteBackupAndRunFull", "BackupViewModel should implement incomplete-backup recovery")
    assert_contains(vm, "runFullBackup(for issue", "Recovery actions should use the failed issue context, not the currently selected device")
    assert_contains(vm, "expectedPath: path", "Recovery deletion should use the exact path from the failed issue")
    assert_contains(vm, "private func clearBrowserState()", "BackupViewModel should clear stale browser state before opening another backup")
    assert_contains(vm, "selectedBackup = nil", "Failed backup browser opens should not leave stale selected backup state visible")
    assert_contains(vm, "browserDomains = []", "Failed backup browser opens should not leave stale domains visible")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "BackupIssueSheet", "Backup failures should use a sheet instead of dumping raw tracebacks in an alert")
    assert_contains(view, "handleBackupIssueAction(_ issue", "Backup recovery actions should receive the full failed issue context")
    assert_contains(view, "Move Incomplete Backup to Trash?", "Destructive incomplete-backup recovery should require explicit confirmation")
    assert_contains(view, "incompleteBackupTrashConfirmationMessage", "Incomplete-backup confirmation should show the exact path before moving it")
    assert_contains(view, "pendingIncompleteBackupIssue = issue\n            backupVM.backupIssue = nil\n            showIncompleteBackupTrashConfirm = true", "Incomplete-backup confirmation should dismiss the issue sheet before presenting the destructive confirmation")
    assert_contains(view, "DisclosureGroup(\"Technical details\"", "Technical details should be collapsed by default")
    assert_contains(view, "Delete Incomplete Backup & Run Full", "Incomplete backup failures should offer a recovery action")
    assert_contains(view, "Open Backup Settings", "Permission/folder failures should offer a settings action")

    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    assert_contains(app, "preferNetwork: device.connectionType == .wifi", "Backup menu command should preserve Wi-Fi network preference")
    assert_contains(app, "confirmFirstFullWiFiBackup", "Backup menu command should use the same first full Wi-Fi safety confirmation")
    assert_contains(app, "device.connectionType == .wifi && !BackupManager.hasExistingBackup", "Wi-Fi menu backups without metadata should be confirmed before starting")


def test_backup_creation_surfaces_determinate_progress_bar(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "@Published var progressFraction: Double?", "BackupViewModel should publish a determinate backup progress fraction")
    assert_contains(vm, "progressFraction = nil", "BackupViewModel should reset to indeterminate progress for each new backup")
    assert_contains(vm, "updateBackupProgress(text)", "BackupViewModel should parse backend progress updates instead of only storing raw text")
    assert_contains(vm, "PyMobileDevice.parseProgress(from: trimmed)", "BackupViewModel should reuse the shared backup progress parser")
    assert_contains(vm, "min(max(pct, 0), 1)", "Backup progress should be clamped to SwiftUI's 0...1 progress range")

    view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "ProgressView(value: fraction, total: 1.0)", "Backup UI should render a determinate progress bar when the backend reports a percentage")
    assert_contains(view, "backupVM.progressFraction == nil", "Backup UI should keep an indeterminate spinner before percentage output is available")
    assert_contains(view, "accessibilityLabel(\"Backup progress\")", "Backup progress bar should have an accessibility label")
    assert_contains(view, "monospacedDigit()", "The visible percent label should not jitter while progress changes")

    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "onProgress(progressText)", "pymobiledevice3 stderr progress should be forwarded to the view model, not only stored internally")
    assert_contains(manager, "idevicebackupStderr.append(error)", "Fallback stderr should still be retained for failures after progress parsing")


def test_backup_completion_is_verified_and_fallback_process_is_tracked(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "finalizeSuccessfulBackup", "Successful backup commands should verify complete metadata before reporting success")
    assert_contains(manager, "Backup Metadata Incomplete", "Incomplete post-backup metadata should surface a structured failure")
    assert_contains(manager, "activeProcess = Shell.runStreaming", "Fallback idevicebackup2 backup/restore processes should be tracked for cancellation")
    assert_contains(manager, "self.activeProcess = nil", "Streaming fallback completion should clear activeProcess")


def test_message_readiness_not_masked_by_manifest_selection_failure(root: Path) -> None:
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    readiness_branch = view.index("messageVM.chats.isEmpty && messageVM.backupReadiness != .unknown")
    no_selection_branch = view.index("title: \"No Backup Selected\"")
    assert readiness_branch < no_selection_branch, "Messages view should show specific readiness errors before generic no-selection copy"


def test_idevicebackup2_network_argument_order_is_before_backup_subcommand(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    match = re.search(r"private func idevicebackupArguments\(.*?\) -> \[String\] \{(?P<body>.*?)\n    \}", manager, re.S)
    assert match is not None, "idevicebackupArguments should centralize fallback argument order"
    body = match.group("body")
    assert_contains(body, 'var args = ["-u", udid]', "idevicebackup2 should start with the target UDID")
    assert body.index('if preferNetwork { args.append("-n") }') < body.index('args.append("backup")'), "idevicebackup2 -n must come before backup subcommand"
    assert body.index('args.append("backup")') < body.index('if full { args.append("--full") }'), "backup subcommand should come before --full"


def test_phosphor_archive_import_uses_active_dir_and_rejects_unsafe_archives(root: Path) -> None:
    archiver = read(root, "Sources/Phosphor/Services/BackupArchiver.swift")
    assert_contains(archiver, "MainActor.run { BackupManager.activeBackupDir }", "Archive import should use Phosphor's active backup directory, not Apple's protected MobileSync default")
    assert_contains(archiver, "archiveEntryIsSafe", "Archive import should validate tar entries before extraction")
    assert_contains(archiver, "guard !entry.hasPrefix(\"/\")", "Archive import should reject absolute tar paths")
    assert_contains(archiver, "!components.contains(\"..\")", "Archive import should reject parent-directory traversal entries")
    assert_contains(archiver, "topLevelEntries(in: entries).intersection(existingDirs)", "Archive import should not overwrite an existing backup directory")
    assert_contains(archiver, "normalizedEntryPath", "Archive import must normalize leading ./ so overwrite detection is not bypassable")
    assert_contains(archiver, 'subtracting(["."])', "Top-level entry set must drop the current-directory token so ./ entries map to their real directory")
    assert_contains(archiver, "isNonEmptyFile(info)", "Archive import completeness must require a non-empty Info.plist, not just its presence")
    assert_contains(archiver, "looksLikeBackupFolder(itemPath)", "Archive import should only report complete backup folders as imported")
    assert_contains(archiver, "moveImportedEntriesToTrash", "Failed archive imports should clean up newly extracted entries")
    assert_contains(archiver, "archive did not contain a complete iOS backup", "Invalid safe archives should fail with a clear reason")


def test_sidebar_device_rows_select_the_clicked_device(root: Path) -> None:
    sidebar = read(root, "Sources/Phosphor/Views/SidebarView.swift")
    assert_contains(sidebar, "sidebarButton(.devices, onSelect: { deviceVM.selectDevice(device) })", "Each sidebar device row should select its own device, not the first device")
    assert_not_contains(sidebar, "selectDevice(first)", "Generic device sidebar action must not always select the first device")


def test_backup_selection_and_browser_navigation_stay_in_sync(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "reconcileSelectedBackupAfterReload", "Reloading backups should reconcile stale selected backup state")
    assert_contains(vm, "backups.contains(where: { $0.id == selectedBackup.id && $0.path == selectedBackup.path })", "Selected backup should remain valid only if the same backup path is still present")
    assert_contains(vm, "@discardableResult\n    func openBackupBrowser(_ backup: BackupInfo) -> Bool", "Opening a backup should report success so views can navigate only after manifest load")

    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    assert_contains(content, "BackupListView(onBrowseBackup: { selectedSection = .backupBrowser })", "Backup list Browse should navigate to Backup Browser after a successful open")
    assert_contains(content, "BackupTimeMachineView(onBrowseBackup: { selectedSection = .backupBrowser })", "Time Machine Browse should navigate to Backup Browser after a successful open")

    browser = read(root, "Sources/Phosphor/Views/Backup/BackupBrowserView.swift")
    assert_contains(browser, ".onChange(of: backupVM.selectedBackup?.id)", "Backup browser should clear local selections when the selected backup changes")
    assert_contains(browser, "selectedFiles.removeAll()", "Backup browser should drop selected file state when backup/domain changes")


def test_file_browser_delete_requires_confirmation_and_blocks_directories(root: Path) -> None:
    view = read(root, "Sources/Phosphor/Views/Files/FileBrowserView.swift")
    assert_contains(view, "pendingDeleteFile", "File browser delete should stage a pending file before confirmation")
    assert_contains(view, ".alert(\"Delete File?\"", "File browser delete should require a confirmation alert")
    assert_contains(view, "if !entry.isDirectory", "File browser should not expose directory deletion in the context menu")
    assert_not_contains(view, "Task { try? await fileManager.deleteFile(entry) }", "File browser context menu must not delete immediately")

    manager = read(root, "Sources/Phosphor/Services/FileTransferManager.swift")
    assert_contains(manager, "guard !entry.isDirectory", "FileTransferManager should reject directory deletion at the service layer")
    assert_contains(manager, "Directory deletion is not supported", "Directory deletion rejection should be explicit")


def test_backup_extract_preserves_domain_relative_paths(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(manager, "private func extractionDestination(for entry", "Backup extraction should centralize safe destination path construction")
    assert_contains(manager, "appendingPathComponent(safeDomain)", "Backup extraction should group files by domain to avoid basename collisions")
    assert_contains(manager, "entry.relativePath", "Backup extraction should preserve manifest relative paths instead of flattening to fileName")
    assert_contains(manager, 'safeDomain == "." || safeDomain == ".."', "Selective extraction must neutralize traversal domains so a crafted manifest row cannot escape the destination")
    assert_contains(manager, "Refusing to extract", "Selective extraction should refuse to write outside the destination folder")
    assert_not_contains(manager, "appendingPathComponent(entry.fileName)\n            do {", "Backup extraction should not flatten every selected file to destination/fileName")


def test_live_photo_exports_use_path_based_names(root: Path) -> None:
    live = read(root, "Sources/Phosphor/Services/LiveDeviceBrowser.swift")
    assert_contains(live, "private func uniqueLocalName(for photo", "Live photo export should centralize duplicate-safe local naming")
    assert_contains(live, "photo.path", "Live photo export naming should use the full device path, not only the basename")
    assert_contains(live, "replacingOccurrences(of: \"/\", with: \"_\")", "Live photo export should preserve DCIM folder identity in local filenames")
    assert_contains(live, "appendingPathComponent(uniqueLocalName(for: photo))", "Live photo temp cache and export should use duplicate-safe names")
