from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_readiness_service_contract(root: Path) -> None:
    path = root / "Sources/Phosphor/Services/ReadinessService.swift"
    assert path.exists(), "ReadinessService.swift should centralize readiness checks"
    src = path.read_text()
    for token in [
        "enum ReadinessStatus",
        "enum ReadinessOperation",
        "struct ReadinessItem",
        "struct ReadinessReport",
        "enum ReadinessService",
        "static func evaluate",
        "static func dependencyStatus",
        "Task.detached",
        "BackupManager.validateBackupDirectory(path, createIfMissing: false)",
        "diagnosticMarkdown",
        "redactedValue(item.detail)",
        "idevicebackup2",
    ]:
        assert token in src, f"ReadinessService missing {token}"


def test_readiness_diagnostics_are_redacted_and_side_effect_free(root: Path) -> None:
    readiness = read(root, "Sources/Phosphor/Services/ReadinessService.swift")
    backup_manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "redactedValue(item.detail)" in readiness, "diagnostic detail text must be redacted before export"
    assert "redactedValue(recoveryAction)" in readiness, "diagnostic recovery text must be redacted before export"
    assert "redactedValue(technicalDetail)" in readiness, "diagnostic technical detail must be redacted before export"
    assert "[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}" in readiness, "modern UDID-like values should be redacted"
    assert "[A-Fa-f0-9]{40}" in readiness, "legacy 40-char UDIDs should be redacted"
    assert "createIfMissing: Bool = true" in backup_manager, "backup validation should let callers opt out of creation"
    assert "BackupManager.validateBackupDirectory(path, createIfMissing: false)" in readiness, "readiness checks should inspect without creating folders"


def test_readiness_tool_classification_requires_backup_backend(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/ReadinessService.swift")
    assert "hasLibimobiledeviceBackup" in src, "libimobiledevice readiness should be backup-specific"
    assert "dependencies[\"idevicebackup2\"] == true" in src, "libimobiledevice backup readiness requires idevicebackup2"
    assert "hasBackupTooling" in src, "next-step status should use the same backup-tool readiness as Tool Readiness"


def test_dependency_checks_are_not_wrapped_in_global_dispatch(root: Path) -> None:
    for rel in [
        "Sources/Phosphor/Services/DeviceManager.swift",
        "Sources/Phosphor/Views/ContentView.swift",
        "Sources/Phosphor/Views/Onboarding/OnboardingView.swift",
        "Sources/Phosphor/Views/Settings/SettingsView.swift",
    ]:
        src = read(root, rel)
        assert "DispatchQueue.global().async" not in src, f"{rel} still uses global dispatch for readiness/dependencies"
        assert "Shell.checkDependencies()" not in src, f"{rel} still calls Shell.checkDependencies directly"
    assert "ReadinessService.dependencyStatus" in read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert "ReadinessService.dependencyStatus" in read(root, "Sources/Phosphor/Views/ContentView.swift")
    assert "ReadinessService.dependencyStatus" in read(root, "Sources/Phosphor/Views/Onboarding/OnboardingView.swift")
    assert "ReadinessService.dependencyStatus" in read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")


def test_readiness_center_visible_in_navigation(root: Path) -> None:
    sidebar = read(root, "Sources/Phosphor/Views/SidebarView.swift")
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    view_path = root / "Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift"
    assert view_path.exists(), "ReadinessCenterView should exist"
    view_src = view_path.read_text()
    assert "case readiness" in sidebar, "SidebarSection should include readiness"
    assert "sidebarRow(.readiness)" in sidebar, "Readiness should be visible in the sidebar"
    assert "ReadinessCenterView" in content, "ContentView should route to the readiness center"
    for phrase in [
        "Tool Readiness",
        "Backup Folder",
        "Device Visibility",
        "Wi-Fi Backup",
        "Safe Operations",
        "Diagnostic Report",
        "Next Steps",
        "Backup Recovery",
    ]:
        assert phrase in view_src, f"Readiness center missing user-facing section: {phrase}"


def test_readiness_center_incomplete_backup_recovery_action(root: Path) -> None:
    service = read(root, "Sources/Phosphor/Services/ReadinessService.swift")
    view = read(root, "Sources/Phosphor/Views/Readiness/ReadinessCenterView.swift")
    assert "enum ReadinessOperation" in service, "readiness rows should carry confirmable recovery operations"
    assert "incompleteBackupItems" in service, "readiness should detect incomplete backup folders"
    assert "BackupManager.incompleteBackupHasKnownMarkers" in service, "incomplete detection should only flag recognizable iOS backup folders"
    assert "deleteIncompleteBackupAndRunFull" in service, "incomplete backup rows should offer a recovery operation"
    assert "pendingRecovery" in view, "readiness recovery should require a confirmation alert"
    assert "Move Incomplete Backup to Trash" in view, "readiness center should expose the cleanup action"
    assert "BackupManager.deleteIncompleteBackup" in view, "cleanup should use the guarded BackupManager trash flow"
    assert "let recoveryRoot = (path as NSString).deletingLastPathComponent" in view, "readiness recovery must derive the root from its captured incomplete path"
    assert "deleteIncompleteBackup(for: udid, expectedPath: path, in: recoveryRoot)" in view, "readiness recovery must not re-read the mutable backup root"
    assert "device.connectionType == .usb" in view, "readiness should auto-start full backup only on USB"
