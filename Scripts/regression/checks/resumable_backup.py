from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_manager_has_resume_and_sanitization_helpers(root: Path) -> None:
    src = (
        read(root, "Sources/Phosphor/Services/BackupManager.swift")
        + "\n"
        + read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    )
    assert_contains(src, "case resumeBackup", "RecoveryAction must support resumeBackup")
    assert_contains(src, "func resumeIncompleteBackup", "BackupManager must implement resumeIncompleteBackup")
    assert_contains(src, "static func incompleteBackupHasPayloadData", "BackupManager must detect payload data in incomplete backups")
    assert_contains(src, "static func sanitizeIncompleteBackup", "BackupManager must provide metadata and WAL sanitization")
    assert_contains(src, "sqlite3_wal_checkpoint_v2", "Sanitization must checkpoint SQLite WAL frames before resumption")
    assert_contains(src, "PropertyListSerialization.propertyList", "Sanitization must validate plist stubs")


def test_backup_view_model_and_ui_support_resumable_backups(root: Path) -> None:
    vm_src = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    list_src = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert_contains(vm_src, "func resumeBackup(udid: String", "BackupViewModel must expose resumeBackup")
    assert_contains(vm_src, "func resumeBackup(for issue:", "BackupViewModel must handle resumeBackup recovery actions")
    assert_contains(vm_src, "isResume: true", "Resume requests must set isResume flag")
    assert_contains(vm_src, "manager.resumeIncompleteBackup", "Worker must invoke resumeIncompleteBackup when isResume is true")

    assert_contains(list_src, "case .resumeBackup:", "BackupListView must handle resumeBackup recovery action")
    assert_contains(list_src, '"Resume Backup"', "BackupListView must show Resume Backup title")
    assert_contains(list_src, "secondaryActionTitle: issue.recoveryAction == .resumeBackup ? \"Delete & Start Fresh\" : nil", "BackupIssueSheet must offer Delete & Start Fresh as secondary action")


def test_readiness_center_supports_resumable_backups(root: Path) -> None:
    service_src = read(root, "Sources/Phosphor/Services/ReadinessService.swift")
    view_src = read(root, "Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift")

    assert_contains(service_src, "case resumeBackup", "ReadinessOperation must support resumeBackup")
    assert_contains(service_src, "Incomplete Backup (Resumable)", "ReadinessService must title resumable backups distinctively")
    assert_contains(service_src, "BackupManager.incompleteBackupHasPayloadData", "ReadinessService must verify payload presence for resumability")
    assert_contains(service_src, "if BackupManager.isAuxiliaryBackupDirectoryName(childName) { continue }", "ReadinessService must ignore guard and quarantine directories")
    assert_contains(service_src, "if BackupManager.activeProcessRunning(for: udid)", "ReadinessService must skip active in-flight backups")

    assert_contains(view_src, 'Label("Resume Backup", systemImage: "play.circle.fill")', "ReadinessCenterView must offer Resume Backup button")
    assert_contains(view_src, "case .resumeBackup", "ReadinessCenterView must handle resumeBackup recovery operation")
    assert_contains(view_src, "backupVM.resumeBackup", "ReadinessCenterView must call backupVM.resumeBackup")
    assert_contains(view_src, "!backupVM.isBackupActive(for: udid)", "ReadinessCenterView must hide recovery items for actively running backups")


def test_upstream_feedback_invariants(root: Path) -> None:
    tracker = read(root, "Sources/Phosphor/Utilities/FinalizationProgressTracker.swift")
    assert "593_000" not in tracker, "FinalizationProgressTracker must not hardcode test-device file counts"
    assert "remBuckets * 3" not in tracker, "FinalizationProgressTracker must compute verification ETA from observed bucket rate"

    shell = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    assert "500_000_000" not in shell, "cancelAndWait must not force-kill after 0.5s"
    assert_contains(shell, "Date().addingTimeInterval(streamTerminationGrace)", "cancelAndWait must give cooperative tools up to streamTerminationGrace before SIGKILL")

    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert 'lower.contains("pin")' not in manager and 'lower.contains("pin")' not in vm, "passcode prompt detection must not match 'Skipping' via bare 'pin' substring"


def test_backup_health_state_metadata_guard_and_quarantine(root: Path) -> None:
    model = read(root, "Sources/Phosphor/Models/BackupInfo.swift")
    resumable = read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    list_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")

    assert_contains(model, "enum HealthState", "BackupInfo must define deterministic HealthState (.complete, .paused, .broken)")
    assert_contains(model, "static func computeHealthState", "BackupInfo must compute healthState from manifest, payload buckets, and SnapshotState")
    assert_contains(resumable, r'".\(udid)-phosphor-guard-bkp"', "Metadata rollback guard must use .<UDID>-phosphor-guard-bkp")
    assert_contains(resumable, '"-phosphor-quarantine-bkp-"', "Sanitization quarantine must use <UDID>-phosphor-quarantine-bkp-<timestamp>")
    assert_contains(resumable, '"-phosphor-broken-bkp-"', "Broken backup repair quarantine must use <UDID>-phosphor-broken-bkp-<timestamp>")
    assert_contains(manager, r'"\(udid)-phosphor-bkp-\(timestamp)"', "Archived full backups must use <UDID>-phosphor-bkp-<timestamp>")
    assert_contains(model, "var isArchivedSnapshot: Bool", "BackupInfo must distinguish archived snapshots from the active UDID slot")
    assert_contains(list_view, 'StatusChip(text: "Archived"', "Archived snapshots must display an Archived status chip")
    assert_contains(resumable, "static func stageMetadataGuard", "BackupManager must stage metadata guard before running backup tools")
    assert_contains(resumable, "static func restoreMetadataGuardIfNeeded", "BackupManager must restore clobbered metadata when backup aborts")
    assert_contains(resumable, "static func quarantineBrokenBackup", "BackupManager must quarantine broken backup folders non-destructively")
    assert_contains(manager, "if isAuxiliaryBackupDirectoryName(item) { continue }", "discoverBackups must ignore guard and quarantine directories")
    assert_contains(list_view, 'StatusChip(text: "Complete"', "Complete backups must display Complete health badge")
    assert_contains(list_view, 'StatusChip(text: "Paused"', "Paused backups must display Paused health badge")
    assert_contains(list_view, 'StatusChip(text: "Broken"', "Broken backups must display Broken health badge")
    assert_contains(list_view, 'return "Backing Up"', "Active backups must display Backing Up chip instead of static health badges")
    assert_contains(list_view, "backupVM.backups.contains { !$0.isArchivedSnapshot && $0.udid == udid }", "hasBackupRow must ignore archived snapshots so active backups are not suppressed")
    assert_contains(resumable, "static func latestBackupDiskActivityDate", "BackupManager must track disk modification timestamps during active backups")
    assert_contains(list_view, 'Button("Repair", action: onRepair)', "Broken backups must offer a Repair action")
    assert_contains(list_view, ".disabled(!isDeviceConnected)", "Resume and Repair actions must be disabled when the device is disconnected")
    assert_contains(manager, "static func unarchiveBackup", "BackupManager must implement non-destructive unarchiveBackup")
    assert_contains(list_view, '"Unarchive Backup?"', "BackupListView must show confirmation alert before unarchiving")
    assert_contains(list_view, 'Label("Unarchive", systemImage: "arrow.uturn.backward.circle")', "BackupRow must offer Unarchive button for archived snapshots")


def test_retry_preserves_resume_and_notifies_passcode(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    pmd = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    list_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    tm_view = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")

    assert_contains(vm, "isResume: request.isResume", "retryBackup must forward isResume so retrying a failed resume does not trigger Incomplete Backup Found")
    assert_contains(vm, "func notifyUserDevicePasscodeRequired", "BackupViewModel must notify the user when device passcode/unlock is required")
    assert_contains(vm, "UNUserNotificationCenter.current()", "BackupViewModel must post a macOS user notification when awaiting passcode")
    assert_contains(vm, "NSApp.requestUserAttention(.informationalRequest)", "BackupViewModel must bounce the Dock icon when awaiting passcode")
    assert_contains(vm, 'lower.contains("passcode prompt dismissed")', "BackupViewModel must immediately clear passcode banner when NP_LOCAL_AUTH_DISMISSED is emitted")
    assert_contains(vm, "let awaitingPasscode = !passcodeDismissed", "BackupViewModel must not treat 'Device passcode prompt dismissed' as a passcode request")
    assert_contains(pmd, '"-v", "--no-color", "backup2", "backup"', "PyMobileDevice.backup must enable verbose notification logs so passcode dismissal is surfaced immediately")
    assert_contains(list_view, "Action Required on iPhone: Unlock your device and enter your passcode to continue the backup...", "BackupRow must display an inline passcode banner when awaiting passcode")
    assert_contains(list_view, "details != issue.recoveryPath", "BackupIssueSheet must hide Technical details when details only repeat recoveryPath")
    assert_contains(tm_view, ".disabled(backup.healthState != .complete)", "BackupTimeMachineView must disable Restore This Backup for incomplete snapshots")


def test_secondary_surfaces_and_data_tabs_sync_with_resumable_and_archived_backups(root: Path) -> None:
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    clone = read(root, "Sources/Phosphor/Services/DeviceCloneService.swift")
    comparison = read(root, "Sources/Phosphor/Views/Backup/BackupComparisonView.swift")
    tm = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")
    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    info = read(root, "Sources/Phosphor/Models/BackupInfo.swift")
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    messages = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    whatsapp = read(root, "Sources/Phosphor/Views/WhatsApp/WhatsAppView.swift")
    photos = read(root, "Sources/Phosphor/Views/Photos/PhotoBrowserView.swift")
    apps = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")
    search = read(root, "Sources/Phosphor/Views/Search/UnifiedSearchView.swift")
    browser = read(root, "Sources/Phosphor/Views/Backup/BackupBrowserView.swift")

    assert_contains(app, "private func hasResumableBackup(for device: DeviceInfo) -> Bool", "Menu bar must detect resumable paused backups")
    assert_contains(app, "await backupVM.resumeBackup(", "Menu bar Cmd+B must resume a paused backup instead of triggering Incomplete Backup Found")
    assert_contains(scheduler, "if isResumable {", "BackupScheduler must resume paused backups on disk")
    assert_contains(scheduler, "DeviceBackupConfiguration.load(for: udid)", "BackupScheduler must respect saved backup profile and app exclusions")
    assert_contains(clone, "isResume: shouldResume", "DeviceCloneService must resume paused source backups")
    assert_contains(clone, "$0.udid == sourceUDID && $0.healthState == .complete", "DeviceCloneService must only restore from a complete source backup")
    assert_contains(comparison, ".filter { $0.healthState == .complete }", "BackupComparisonView must only compare complete snapshots")
    assert_contains(tm, "$0.udid == backup.udid && $0.healthState == .complete", "BackupTimeMachineView must require 2 complete snapshots to enable Compare Backups")
    assert_contains(manifest, 'let snapshotPath = "\\(backupRoot)/Snapshot/\\(prefix)/\\(id)"', "FileEntry.diskPath must fall back to Snapshot/<prefix>/<id> for paused backups")
    assert_contains(manifest, 'appendingPathComponent("Snapshot/Manifest.db")', "BackupManifest.init must fall back to Snapshot/Manifest.db for paused backups")
    assert_contains(info, "var pickerStatusSuffix: String", "BackupInfo must expose pickerStatusSuffix for Archived and Paused states")
    assert_contains(vm, "var browsableBackups: [BackupInfo]", "BackupViewModel must filter out .broken backups for browsing")
    assert_contains(vm, "var preferredBrowsableBackup: BackupInfo?", "BackupViewModel must prefer .complete backups over .paused for default selection")

    for view_src, name in [
        (messages, "MessageListView"),
        (whatsapp, "WhatsAppView"),
        (apps, "AppManagerView"),
        (search, "UnifiedSearchView"),
        (browser, "BackupBrowserView"),
    ]:
        assert_contains(view_src, "browsableBackups", f"{name} must list browsableBackups")
        assert_contains(view_src, "pickerStatusSuffix", f"{name} must show pickerStatusSuffix in backup selector")

    for view_src, name in [
        (messages, "MessageListView"),
        (whatsapp, "WhatsAppView"),
        (photos, "PhotoBrowserView"),
        (apps, "AppManagerView"),
        (search, "UnifiedSearchView"),
    ]:
        assert_contains(view_src, "preferredBrowsableBackup", f"{name} must auto-select preferredBrowsableBackup")

    list_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    overview = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert_contains(vm, "@Published private(set) var isLoadingBackups = true", "BackupViewModel must start with isLoadingBackups = true until the backup directory is scanned")
    assert_contains(vm, "await ensureBackupsLoaded()", "createBackup must await ensureBackupsLoaded() before starting any backup")
    assert_contains(list_view, '"Scanning Backup Location…"', "BackupListView must show a scanning state instead of No Backups Found while loading")
    assert_contains(list_view, ".disabled(backupVM.isLoadingBackups)", "BackupListView must disable New Backup while scanning the backup directory")
    assert_contains(overview, ".disabled(backupVM.isLoadingBackups)", "DeviceOverviewView must disable the Backup quick action while scanning the backup directory")
    assert_contains(app, "backupVM.isLoadingBackups", "PhosphorApp menu bar must disable Backup Now while scanning the backup directory")


def test_self_contained_per_backup_progress_and_coherent_eta(root: Path) -> None:
    pmd = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    dm = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    resumable = read(root, "Sources/Phosphor/Services/BackupManager+Resumable.swift")
    vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")

    assert_contains(pmd, 'static func diskUsage(udid: String? = nil)', "PyMobileDevice must query com.apple.disk_usage domain")
    assert_contains(dm, "cachedDiskInfo(udid: udid", "DeviceManager must populate disk capacity from com.apple.disk_usage when missing from lockdown info")
    assert_contains(resumable, "static func fetchTargetDeviceUsedBytes(for udid: String)", "BackupManager must independently resolve target device used bytes")
    assert "200_000_000_000" not in vm, "BackupViewModel must not divide by a hardcoded 200 GB fallback cap"
    assert "priorBackupSize" not in vm, "Each backup must calculate its baseline independently without relying on other backups"
    assert_contains(vm, "static func computeCoherentETA(", "BackupViewModel must compute coherent ETA from active session transfer velocity")
    assert_contains(vm, "static func recordTransferSample(", "BackupViewModel must record active transfer fraction samples after initial manifest diffing")
    assert_contains(vm, "var consolidatedETADescription: String?", "BackupActivity must expose consolidatedETADescription with duration and finish clock/date")
    assert_contains(vm, "sizeResolutionTasksByPath", "BackupViewModel must resolve backup sizes independently per path without blocking or cancelling across rows")

    ext = read(root, "Sources/Phosphor/Utilities/Extensions.swift")
    info = read(root, "Sources/Phosphor/Models/BackupInfo.swift")
    list_view = read(root, "Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(ext, "func contextualClockString(", "Date must format contextual start/finish clock strings with Tomorrow/date awareness")
    assert_contains(ext, "fts_open(", "FileManager.directorySize must use fast POSIX fts_open traversal")
    assert_contains(ext, "static func fastDirectoryEntryCount(", "FileManager must use getattrlist(ATTR_DIR_ENTRYCOUNT) for APFS directory entry counts")
    assert_contains(ext, "if totalBucketFiles > 15_000, !bucketPaths.isEmpty {", "FileManager.directorySize must use stratified 16-bucket sampling for large backups (>15k files)")
    assert_contains(info, "var statusTimestampDescription: String", "BackupInfo must provide explicit state-prefixed timestamp descriptions")
    assert_contains(vm, "var currentTick: Date", "BackupActivity must mutate currentTick every second so SwiftUI re-renders elapsed time and pause counters")
    assert_contains(vm, "var activeTimelineDescription: String", "BackupActivity must expose activeTimelineDescription with start date and elapsed time")
    assert_contains(vm, "var transferAnchorSample:", "BackupActivity must retain transferAnchorSample so ETA never blanks out between integer ticks")
    assert_contains(vm, "var lastComputedEtaSeconds:", "BackupActivity must retain lastComputedEtaSeconds for smooth countdown between ticks")
    assert_contains(list_view, "activity.activeTimelineDescription", "BackupRow must render activeTimelineDescription when active")
    assert_contains(list_view, "backup.statusTimestampDescription", "BackupRow must render explicit state-prefixed timestamps when idle and Started time when active")
    assert_contains(list_view, '"· Calculating ETA…"', "BackupRow must show Calculating ETA… while initial transfer velocity is being measured")
    assert_contains(vm, "guard !isTransitioning, tickCount % 5 == 1 else { continue }", "Liveness monitor must republish 1s UI ticks before any disk I/O and skip disk scans while pausing")
    assert_contains(vm, "let shouldSampleDomain = (tickCount % 30 == 1)", "Liveness monitor must throttle SQLite Manifest.db domain sampling so it does not contend with backup disk writes")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    shell = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    assert_contains(manager, "patchManifest: full && (onlyRegex != nil && !onlyRegex!.isEmpty)", "patchManifest must only be enabled on full backups because pymobiledevice3 forces full=True when patch_manifest=True")
    assert_contains(shell, "proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, rusagePtr)", "Shell.ManagedProcess must query kernel ri_diskio_byteswritten via proc_pid_rusage")
    assert_contains(manager, "var activeProcessBytesWritten: UInt64", "BackupManager must expose activeProcessBytesWritten from ManagedProcess")
    assert_contains(vm, "var sessionBytesWritten: UInt64", "BackupActivity must track sessionBytesWritten from kernel I/O accounting")
    assert_contains(vm, "private static func computeKernelByteSpeed(", "BackupViewModel must compute live transfer speed from kernel byte write samples")








