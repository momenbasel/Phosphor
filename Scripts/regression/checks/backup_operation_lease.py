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
