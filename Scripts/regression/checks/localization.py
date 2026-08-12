from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_simplified_chinese_is_declared_and_packaged(root: Path) -> None:
    info = read(root, "Resources/Info.plist")
    build = read(root, "Scripts/build.sh")

    assert "<key>CFBundleLocalizations</key>" in info, "Info.plist must declare supported localizations"
    assert "<string>zh-Hans</string>" in info, "Info.plist must declare Simplified Chinese"
    assert 'Sources/Phosphor/Resources"/*.lproj' in build, "build script must copy root localization bundles"
    assert (root / "Sources/Phosphor/Resources/zh-Hans.lproj/Localizable.strings").exists()


def test_runtime_labels_use_localized_string_keys(root: Path) -> None:
    files = [
        "Sources/Phosphor/Views/SidebarView.swift",
        "Sources/Phosphor/Views/Components/EmptyStateView.swift",
        "Sources/Phosphor/Utilities/Theme.swift",
        "Sources/Phosphor/Views/Apps/AppManagerView.swift",
        "Sources/Phosphor/Views/Backup/BackupListView.swift",
        "Sources/Phosphor/Views/Clone/DeviceCloneView.swift",
        "Sources/Phosphor/Views/Diagnostics/DiagnosticsView.swift",
        "Sources/Phosphor/Views/Health/HealthView.swift",
        "Sources/Phosphor/Views/Messages/MessageListView.swift",
        "Sources/Phosphor/Views/Music/MusicView.swift",
        "Sources/Phosphor/Views/Photos/PhotoBrowserView.swift",
        "Sources/Phosphor/Views/Safari/SafariView.swift",
        "Sources/Phosphor/Views/Settings/SettingsView.swift",
        "Sources/Phosphor/Views/Watch/AppleWatchView.swift",
    ]

    for rel in files:
        assert "LocalizedStringKey(" in read(root, rel), f"missing LocalizedStringKey conversion in {rel}"


def test_empty_state_subtitle_never_format_reinterprets_runtime_messages(root: Path) -> None:
    """EmptyStateView subtitles carry resolved error text (e.g. WhatsAppView,
    AppleWatchView pass `subtitle: error`). LocalizedStringKey would mangle a
    resolved message containing % tokens, so the lookup must be explicit and
    the result rendered verbatim."""
    src = read(root, "Sources/Phosphor/Views/Components/EmptyStateView.swift")
    assert "LocalizedStringKey(subtitle)" not in src, (
        "EmptyStateView.subtitle must not pass runtime messages through LocalizedStringKey"
    )
    assert 'Text(verbatim: Bundle.main.localizedString(forKey: subtitle, value: subtitle, table: nil))' in src, (
        "EmptyStateView.subtitle must translate known keys and pass resolved messages through verbatim"
    )


def test_simplified_chinese_has_core_runtime_labels(root: Path) -> None:
    strings = read(root, "Sources/Phosphor/Resources/zh-Hans.lproj/Localizable.strings")
    for key, value in {
        "Device": "设备",
        "Readiness": "准备检查",
        "Backup Browser": "备份浏览器",
        "Battery Health": "电池健康",
        "Screen Capture": "屏幕录制",
    }.items():
        assert f'"{key}" = "{value}";' in strings, f"missing Simplified Chinese translation for {key}"
