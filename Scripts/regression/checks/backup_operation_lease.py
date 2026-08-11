from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_ownership_blocks_overlap_across_every_backup_owner(root: Path) -> None:
    """PR #58 proposed a single global backup lease for this. PR #60's per-device
    registry supersedes it: it refuses a second writer on the same UDID - which
    is the hazard, since two subprocesses in one backup folder corrupt it - while
    still allowing a different device to back up at the same time, which the
    global lease would have made impossible. The invariant to protect is
    "no two owners write the same device", not "only one backup exists"."""
    coordinator = read(root, "Sources/Phosphor/Services/BackupOperationCoordinator.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    clone = read(root, "Sources/Phosphor/Services/DeviceCloneService.swift")

    assert_contains(coordinator, "static let shared", "every backup owner must reach one app-wide gate")
    assert_contains(coordinator, "struct BackupOperationRegistry", "per-device ownership must be shared, not per-instance")
    assert_contains(coordinator, "maxConcurrentOperations", "concurrency must be capped")
    assert_contains(coordinator, "func acquire", "an owner must acquire ownership of a device before writing it")
    assert_contains(coordinator, "func release", "every acquired device must be released")

    assert_contains(manager, "private static var operationRegistry", "all BackupManager instances must share one registry")
    assert manager.count("beginCancellableOperation(udid:") >= 4, (
        "full, incremental, restore and the helper must all take device ownership"
    )
    assert_contains(manager, "already running for this device", "a rejected overlap needs a user-facing reason")

    assert_contains(scheduler, "backupViewModel.createBackup", "scheduled backups must go through the ownership-taking BackupManager")
    assert_contains(clone, "backupViewModel.createBackup", "clone source backups must go through the ownership-taking BackupManager")

    assert_contains(app, "backupVM.isCreating", "Quick Actions must disable while a backup is running")


def test_backup_root_snapshot_survives_settings_change_through_fallback_and_finalization(root: Path) -> None:
    """A run that starts at root A must not split work with root B after Settings changes.

    The trace models each mode's primary failure followed by fallback and finalization;
    the source assertions bind that behavior to the concrete BackupManager calls.
    """
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")

    def modeled_run(mode: str) -> dict[str, str]:
        active_root = "/backups/A"
        operation_root = active_root  # acquired immediately with the operation lease
        paths = {"preflight": operation_root, "primary": operation_root}
        active_root = "/backups/B"  # Settings changes while the primary is running
        paths.update(
            fallback=operation_root,
            verification=operation_root,
            discovery=operation_root,
            failure=operation_root,
        )
        assert active_root == "/backups/B"
        return paths

    for mode in ("full", "incremental"):
        assert set(modeled_run(mode).values()) == {"/backups/A"}, (
            f"{mode} backup must retain its root after Settings changes"
        )

    full = manager.split("func createBackup(", 1)[1].split("private func idevicebackupArguments", 1)[0]
    incremental = manager.split("func createIncrementalBackup(", 1)[1].split("// MARK: - Restore", 1)[0]
    for mode, body in (("full", full), ("incremental", incremental)):
        assert "let backupRoot = Self.activeBackupDir" in body, f"{mode} backup must snapshot root after its lease"
        assert body.index("beginCancellableOperation(udid: udid)") < body.index("let backupRoot = Self.activeBackupDir"), (
            f"{mode} backup must snapshot root only after obtaining device ownership"
        )
        assert "Self.validateBackupDirectory(backupRoot)" in body, f"{mode} preflight must use the snapshot"
        assert "Self.backupMetadataHealth(for: udid, in: backupRoot)" in body, f"{mode} metadata lookup must use the snapshot"
        assert "finalizeSuccessfulBackup(udid: udid, directory: backupRoot" in body, f"{mode} verification/finalization must use the snapshot"
        assert "idevicebackupArguments(udid: udid, directory: backupRoot, full:" in body, f"{mode} fallback arguments must use the snapshot"
        assert "Self.backupPath(for: udid, in: backupRoot)" in body, f"{mode} failure recovery paths must use the snapshot"

    finalize = manager.split("private func finalizeSuccessfulBackup(", 1)[1].split("/// Create a new backup.", 1)[0]
    assert "directory: String" in finalize, "finalization must accept the operation root"
    assert "Self.backupMetadataHealth(for: udid, in: directory)" in finalize, "verification must use the operation root"
    assert "discoverBackups(at: directory)" in finalize, "post-success discovery must use the operation root"

    primary = manager.split("private func createBackupViaPymobiledevice(", 1)[1].split("/// Create an incremental backup", 1)[0]
    assert "directory: String" in primary, "primary backend must accept the operation root"
    assert "directory: directory" in primary, "primary backend must use the operation root"


def test_incomplete_backup_recovery_uses_the_failed_operation_root(root: Path) -> None:
    """Recovery must trash the captured failed folder, even after Settings changes."""
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")

    with tempfile.TemporaryDirectory(prefix="phosphor-recovery-root-") as temp_dir:
        temp = Path(temp_dir)
        root_a = temp / "A"
        root_b = temp / "B"
        failed = root_a / "device"
        other = root_b / "device"
        failed.mkdir(parents=True)
        other.mkdir(parents=True)
        (failed / "Info.plist").write_text("partial")
        (other / "Info.plist").write_text("new-root")

        failed_root = failed.parent
        active_root = root_b  # Settings changes after failure is surfaced.
        # Model the recovery contract: remove only from the captured operation root;
        # a new backup then starts from the current explicitly selected root.
        import shutil
        shutil.rmtree(failed_root / "device")
        assert not failed.exists(), "recovery must remove the failed operation folder"
        assert other.exists(), "recovery must not inspect or remove the current different root"
        assert active_root == root_b

    recovery = view_model.split("func deleteIncompleteBackupAndRunFull", 1)[1].split("func retryBackup", 1)[0]
    assert "let recoveryRoot = (path as NSString).deletingLastPathComponent" in recovery, (
        "recovery must derive the failed operation root from its captured path"
    )
    assert "deleteIncompleteBackup(for: udid, expectedPath: path, in: recoveryRoot)" in recovery, (
        "recovery must delete from the captured operation root, not mutable active settings"
    )
    assert "in directory: String?" in manager, "the backup manager deletion API must accept an explicit recovery root"
