from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_manager_has_resume_and_sanitization_helpers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/BackupManager.swift")
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

    assert_contains(view_src, 'Label("Resume Backup", systemImage: "play.circle.fill")', "ReadinessCenterView must offer Resume Backup button")
    assert_contains(view_src, "case .resumeBackup", "ReadinessCenterView must handle resumeBackup recovery operation")
    assert_contains(view_src, "backupVM.resumeBackup", "ReadinessCenterView must call backupVM.resumeBackup")
