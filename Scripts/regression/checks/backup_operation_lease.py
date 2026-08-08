from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_operation_lease_blocks_scheduled_clone_and_rapid_menu_overlap(root: Path) -> None:
    coordinator = read(root, "Sources/Phosphor/Services/BackupOperationCoordinator.swift")
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    clone = read(root, "Sources/Phosphor/Services/DeviceCloneService.swift")

    assert_contains(coordinator, "static let shared", "every backup owner must use one app-wide coordinator")
    assert_contains(coordinator, "@Published private(set) var activeKind", "menu state must observe an active backup operation")
    assert_contains(coordinator, "var isRunning: Bool", "the coordinator must expose whether a lease is active")
    assert_contains(coordinator, "func acquire", "a backup must acquire a lease before starting")
    assert_contains(coordinator, "func release", "every acquired backup lease must be released")

    assert manager.count("BackupOperationCoordinator.shared.acquire") >= 2, (
        "full and incremental BackupManager paths must acquire the shared lease"
    )
    assert manager.count("BackupOperationCoordinator.shared.release") >= 2, (
        "full and incremental BackupManager paths must release the shared lease"
    )
    assert_contains(manager, "Another backup is already running", "a rejected overlap needs a user-facing reason")

    assert_contains(scheduler, "manager.create", "scheduled backups must continue through the lease-owning BackupManager")
    assert_contains(clone, "backupManager.createBackup", "clone source backups must continue through the lease-owning BackupManager")

    assert_contains(app, "@StateObject private var backupOperations = BackupOperationCoordinator.shared", "Quick Actions must observe the shared lease")
    assert_contains(app, "backupOperations.isRunning", "Quick Actions must disable while any owner holds the lease")
    assert_contains(app, "!backupOperations.isRunning", "rapid duplicate activation must be rejected before dispatch")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        probe = tmp_path / "BackupOperationLeaseProbe.swift"
        executable = tmp_path / "backup-operation-lease-probe"
        probe.write_text(
            """
import Foundation

@main
struct BackupOperationLeaseProbe {
    static func main() async {
        let passed = await MainActor.run {
            let coordinator = BackupOperationCoordinator.shared
            guard let first = coordinator.acquire(), coordinator.isRunning else { return false }
            guard coordinator.acquire() == nil else { return false }
            coordinator.release(first)
            guard !coordinator.isRunning, let second = coordinator.acquire() else { return false }
            coordinator.release(second)
            return !coordinator.isRunning
        }
        guard passed else { fatalError("backup operation lease failed") }
    }
}
"""
        )
        compile = subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                str(root / "Sources/Phosphor/Services/BackupOperationCoordinator.swift"),
                str(probe),
                "-o",
                str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile.returncode == 0, compile.stderr
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        assert run.returncode == 0, run.stderr
