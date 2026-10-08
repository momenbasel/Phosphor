from __future__ import annotations

import re
from pathlib import Path

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
SEMANTIC_KEY = re.compile(r"[a-z][A-Za-z]*(\.[A-Za-z]+)+")


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


def strings_entries(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in path.read_text().splitlines():
        match = ENTRY.match(line)
        if match and match.group(1) not in entries:
            entries[match.group(1)] = match.group(2)
    return entries


def test_localizable_strings_are_keyed_by_english_literals(root: Path) -> None:
    """Views localize with Text("Devices"), Label("Install IPA", ...) and
    LocalizedStringKey(section.label), so the English UI string is the key SwiftUI
    resolves against Bundle.main. Semantic keys such as "sidebar.devices" are never
    looked up by any Swift code; a German system stayed English because every file
    was keyed that way (issue #76). en.lproj keeps identity entries as the canonical
    key list."""
    resources = root / "Sources/Phosphor/Resources"
    english = strings_entries(resources / "en.lproj/Localizable.strings")
    assert english, "en.lproj must list the UI strings"
    for key, value in english.items():
        assert key == value, f"en.lproj must map each UI string to itself, got {key!r} = {value!r}"
    for lproj in sorted(resources.glob("*.lproj")):
        entries = strings_entries(lproj / "Localizable.strings")
        assert entries, f"{lproj.name} has no entries"
        semantic = [key for key in entries if SEMANTIC_KEY.fullmatch(key)]
        assert not semantic, f"{lproj.name} uses semantic keys that no view reads: {semantic[:5]}"
        for key, value in entries.items():
            assert value, f"{lproj.name} has an empty translation for {key!r}"


def test_lithuanian_is_declared_and_packaged(root: Path) -> None:
    info = read(root, "Resources/Info.plist")
    assert "<string>lt</string>" in info, "Info.plist must declare Lithuanian"
    strings = strings_entries(root / "Sources/Phosphor/Resources/lt.lproj/Localizable.strings")
    for key, value in {
        "Devices": "Įrenginiai",
        "Backups": "Atsarginės kopijos",
        "Welcome to Phosphor": "Sveiki atvykę į Phosphor",
    }.items():
        assert strings.get(key) == value, f"missing Lithuanian translation for {key}"


def test_german_core_labels_keep_their_umlauts(root: Path) -> None:
    strings = strings_entries(root / "Sources/Phosphor/Resources/de.lproj/Localizable.strings")
    for key, value in {
        "Devices": "Geräte",
        "Device": "Gerät",
        "Delete": "Löschen",
        "No Device Connected": "Kein Gerät verbunden",
        "Scan for Devices": "Nach Geräten suchen",
    }.items():
        assert strings.get(key) == value, f"incorrect German translation for {key}"
