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


def test_lithuanian_is_declared_packaged_and_complete(root: Path) -> None:
    info = read(root, "Resources/Info.plist")
    build = read(root, "Scripts/build.sh")
    english = read(root, "Sources/Phosphor/Resources/en.lproj/Localizable.strings")
    lithuanian_path = root / "Sources/Phosphor/Resources/lt.lproj/Localizable.strings"

    assert "<string>lt</string>" in info, "Info.plist must declare Lithuanian"
    assert 'Sources/Phosphor/Resources"/*.lproj' in build, "build script must package Lithuanian"
    assert lithuanian_path.exists(), "Lithuanian Localizable.strings must be present"

    def entries(source: str) -> dict[str, str]:
        return {
            line.split('"', 2)[1]: line.rsplit('"', 2)[1]
            for line in source.splitlines()
            if line.lstrip().startswith('"') and '" =' in line
        }

    english_entries = entries(english)
    lithuanian_entries = entries(lithuanian_path.read_text())
    missing = english_entries.keys() - lithuanian_entries.keys()
    assert not missing, f"Lithuanian is missing English keys: {sorted(missing)}"

    for semantic_key, english_label in english_entries.items():
        translated_label = lithuanian_entries[semantic_key]
        assert lithuanian_entries.get(english_label) == translated_label, (
            f"Lithuanian runtime alias missing for {english_label!r}"
        )


def test_german_existing_translations_have_runtime_aliases(root: Path) -> None:
    english = read(root, "Sources/Phosphor/Resources/en.lproj/Localizable.strings")
    german = read(root, "Sources/Phosphor/Resources/de.lproj/Localizable.strings")

    def entries(source: str) -> dict[str, str]:
        return {
            line.split('"', 2)[1]: line.rsplit('"', 2)[1]
            for line in source.splitlines()
            if line.lstrip().startswith('"') and '" =' in line
        }

    english_entries = entries(english)
    german_entries = entries(german)
    semantic_keys = english_entries.keys() & german_entries.keys()
    assert semantic_keys, "German must contain semantic translations"

    for key, value in {
        "sidebar.devices": "Geräte",
        "group.device": "Gerät",
        "action.delete": "Löschen",
        "device.noDeviceConnected": "Kein Gerät verbunden",
        "device.scanForDevices": "Nach Geräten suchen",
        "welcome.subtitle": "Verbinden Sie ein iOS-Gerät oder wählen Sie einen Bereich in der Seitenleiste.",
    }.items():
        assert german_entries.get(key) == value, f"incorrect German translation for {key}"

    for semantic_key in semantic_keys:
        english_label = english_entries[semantic_key]
        translated_label = german_entries[semantic_key]
        assert german_entries.get(english_label) == translated_label, (
            f"German runtime alias missing for {english_label!r}"
        )
