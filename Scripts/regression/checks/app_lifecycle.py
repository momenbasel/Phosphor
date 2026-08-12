from __future__ import annotations

import re
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_phosphor_quits_after_last_window_closes(root: Path) -> None:
    src = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    assert "applicationShouldTerminateAfterLastWindowClosed" in src, "Phosphor needs an explicit last-window policy"
    assert "BackgroundExecutionController.shared.keepsRunningAfterLastWindowClosed" in src, (
        "enabled scheduled work must keep Phosphor alive after its last window closes"
    )
    assert "ApplicationTerminationCoordinator.shared.hasActiveOperations" in src, (
        "an active backup or restore must keep Phosphor alive until it finishes"
    )


def test_background_execution_has_reachable_reopen_and_idle_exit_policy(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/BackgroundExecutionController.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")

    assert "NSStatusBar.system.statusItem" in src, "windowless background mode needs a visible status item"
    assert "Open Phosphor" in src and "Quit Phosphor" in src, "background mode needs reachable reopen and quit actions"
    assert "func showMainWindow()" in src, "the status item and Dock reopen path need a shared window opener"
    assert "terminateWhenIdleIfWindowless" in src, "manual-backup keep-alive must exit after work ends when no schedule is enabled"
    assert "applicationShouldHandleReopen" in app and "showMainWindow()" in app, "Dock reopen must restore a window"
    assert app.index("scheduler.startMonitoring()") < app.index("Task.sleep(for: .milliseconds(750))"), (
        "scheduled keep-alive must be registered before delayed foreground discovery"
    )
    assert "setScheduledWorkEnabled(schedules.contains(where: \\.enabled))" in scheduler, (
        "the lifecycle owner must follow the persisted multi-schedule state"
    )


def test_application_quit_defers_until_managed_backup_processes_are_reaped(root: Path) -> None:
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    coordinator = read(root, "Sources/Phosphor/Services/ApplicationTerminationCoordinator.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    shell = read(root, "Sources/Phosphor/Utilities/Shell.swift")

    assert "func applicationShouldTerminate" in app, "normal Quit must pass through a termination drain"
    assert "ApplicationTerminationCoordinator.shared.applicationShouldTerminate()" in app
    assert ".terminateLater" in coordinator and "reply(toApplicationShouldTerminate: true)" in coordinator, (
        "AppKit termination must be deferred until managed work is drained"
    )
    assert "register(self)" in manager and "unregister(self)" in manager, (
        "every BackupManager operation owner must participate in process-wide termination"
    )
    assert "cancelForApplicationTermination" in manager, "quit must cancel every active manager"
    assert "await Shell.terminateAndWait" in manager, "quit must wait for process-tree cleanup, not fire-and-forget"
    assert "cancellationDrainTasks[activeOperationID] = Task" in manager, (
        "normal Cancel must retain the operation lease while process descendants drain"
    )
    assert manager.count("await self.awaitCancellationDrain(operationID)") >= 5, (
        "streaming completion must not release backup/restore ownership before cancellation drain finishes"
    )
    assert manager.count("guard !operationWasCancelled(operationID) else") >= 6, (
        "every async backup/restore launch boundary must reject a quit cancellation before spawning a child"
    )
    assert "static func terminateAndWait" in shell, "Shell must expose awaited process-group termination"


def test_phosphor_preserves_reopen_window_recovery(root: Path) -> None:
    src = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    reopen = re.search(
        r"func\s+applicationShouldHandleReopen\(_ sender: NSApplication,\s*hasVisibleWindows flag: Bool\)\s*->\s*Bool\s*\{(?P<body>.*?)\n    \}",
        src,
        re.S,
    )
    assert reopen is not None, "Dock/app reopen should recreate a missing window"
    assert "if !flag" not in reopen.group("body"), (
        "Dock reopen must also activate/front an existing visible window"
    )
    assert (
        "ensureWindowSoon()" in reopen.group("body")
        or "BackgroundExecutionController.shared.showMainWindow()" in reopen.group("body")
    ), "reopen recovery should call the no-window guard or shared background window opener"
    assert "CommandGroup(replacing: .newItem)" not in src, "do not remove SwiftUI's standard New Window command"

def test_apps_screen_can_reach_backup_extraction_without_leaving_it(root: Path) -> None:
    """Issue #46: Extract Data existed only on the In Backup tab, and that tab
    stayed empty until a backup was selected from the Backups section. Nothing in
    the UI said so, so the feature read as missing."""
    view = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")

    assert "private var backupPicker: some View" in view, "the Apps header needs its own backup picker"
    assert "backupVM.openBackupBrowser(backup)" in view, "picking a backup from Apps must go through the shared browser opener"
    assert "Choose Backup Folder..." in view, "the picker must offer an arbitrary folder, for backups made outside Phosphor"
    assert "if let latest = backupVM.backups.first" in view, "opening Apps should land on the newest backup instead of an empty screen"

    # Without this the list goes stale when the selection changes elsewhere, and
    # Extract Data silently no-ops after the destination panel closes.
    assert ".onChange(of: backupVM.selectedBackup?.path)" in view, "the app list must follow the selected backup"

    assert "actionLabel: \"Use Latest Backup\"" in view, "the no-selection empty state needs a real action, not just instructions"
    assert "Go to In Backup" in view, "the On Device tab must explain where extraction lives"
    assert "LoadingOverlay(message: \"Reading apps from backup...\")" in view, "reading a large backup must show progress, not an empty state"

    view_model = read(root, "Sources/Phosphor/ViewModels/AppViewModel.swift")
    assert "func loadBackupApps(backupPath: String) async" in view_model, "reading a backup's apps must not block the main actor"

    manager = read(root, "Sources/Phosphor/Services/AppManager.swift")
    assert "private nonisolated static func readBackupApps" in manager, "the stat-heavy manifest walk must run off the main actor"
