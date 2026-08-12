from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_menu_bar_has_safe_one_click_backup_and_navigation_actions(root: Path) -> None:
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")

    assert_contains(
        app,
        "@State private var selectedSection: SidebarSection? = .devices",
        "menu commands need shared navigation state",
    )
    assert_contains(
        app,
        "ContentView(selectedSection: $selectedSection)",
        "the root view must receive app-owned navigation for menu commands",
    )
    assert_contains(app, 'CommandMenu("Quick Actions")', "the menu bar needs a dedicated one-click action menu")
    assert_contains(app, 'Button("Backup Now")', "the menu bar needs a clearly named immediate backup action")
    assert_contains(app, "startBackupNow()", "Backup Now must share the guarded backup action")
    assert_contains(app, "!backupVM.isCreating", "Backup Now must not start a concurrent backup")
    assert_contains(app, 'Button("Open Backup Folder")', "the menu bar should reveal the active backup destination")
    assert_contains(app, "NSWorkspace.shared.open", "opening the backup folder must use the standard Finder action")
    assert_contains(app, "BackupManager.activeBackupDir", "opening the backup folder must use the configured destination")

    for label, section in [
        ("Show Backups", ".backups"),
        ("Show Messages", ".messages"),
        ("Show Photos", ".photos"),
        ("Show Files", ".files"),
    ]:
        assert_contains(app, f'Button("{label}")', f"Quick Actions should include {label}")
        assert_contains(app, f"selectedSection = {section}", f"{label} should navigate directly to {section}")

    assert_contains(
        content,
        "@Binding var selectedSection: SidebarSection?",
        "ContentView must observe the shared menu navigation selection",
    )
