from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_backup_profile_models_and_regex_generation(root: Path) -> None:
    profile_src = read(root, "Sources/Phosphor/Models/BackupProfile.swift")
    config_src = read(root, "Sources/Phosphor/Models/DeviceBackupConfiguration.swift")
    target_src = read(root, "Sources/Phosphor/Models/AppBackupTarget.swift")

    assert_contains(profile_src, "enum BackupProfileType", "BackupProfileType enum must be defined")
    assert_contains(profile_src, "case bareMinimal", "BackupProfileType must have bareMinimal case")
    assert_contains(profile_src, "case communicationAndIdentity", "BackupProfileType must have communicationAndIdentity case")
    assert_contains(profile_src, "case essentialPhotos", "BackupProfileType must have essentialPhotos case")
    assert_contains(profile_src, "func preservationRegex", "BackupProfileType must generate preservation domain regex")
    assert_contains(
        profile_src,
        r"(?!AppDomain(-(\(excludedPattern))|Group-.*(\(excludedPattern)))",
        "preservationRegex must parenthesize excludedPattern so multi-app exclusions prefix '-' to every bundle ID",
    )

    assert_contains(config_src, "struct DeviceBackupConfiguration", "DeviceBackupConfiguration model must exist")
    assert_contains(config_src, "func save(for udid: String)", "DeviceBackupConfiguration must support saving per UDID")
    assert_contains(config_src, "static func load(for udid: String)", "DeviceBackupConfiguration must support loading per UDID")
    assert_contains(config_src, "static func inferFromExistingBackup", "DeviceBackupConfiguration must infer profile portably from Manifest.db")
    assert_contains(config_src, "func isCompatibleForIncremental", "DeviceBackupConfiguration must validate incremental compatibility")

    assert_contains(target_src, "struct AppBackupTarget", "AppBackupTarget struct must exist")
    assert_contains(target_src, "dynamicDiskBytes", "AppBackupTarget must track dynamic data bytes")


def test_backup_engine_supports_domain_filtering_and_patching(root: Path) -> None:
    pmd_src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    bm_src = read(root, "Sources/Phosphor/Services/BackupManager.swift")

    assert_contains(pmd_src, "onlyRegex: [String]?", "PyMobileDevice.backup must accept onlyRegex")
    assert_contains(pmd_src, "patchManifest: Bool", "PyMobileDevice.backup must accept patchManifest")
    assert_contains(pmd_src, '"--only-regex"', "PyMobileDevice.backup must pass --only-regex flag")
    assert_contains(pmd_src, '"--patch-manifest"', "PyMobileDevice.backup must pass --patch-manifest flag")

    assert_contains(bm_src, "configuration: DeviceBackupConfiguration?", "BackupManager must accept configuration")
    assert_contains(bm_src, "config.profileType.preservationRegex", "BackupManager must extract domain preservation regex")
    assert_contains(bm_src, "static func cloneBackupSnapshot", "BackupManager must support APFS CoW pre-incremental snapshots")
    assert_contains(bm_src, "Darwin.clonefile", "BackupManager must use APFS clonefile(2) for zero-extra-space snapshots")


def test_app_exclusion_sheet_and_profile_selector_views_exist(root: Path) -> None:
    sheet_src = read(root, "Sources/Phosphor/Views/Backup/AppExclusionSheet.swift")
    selector_src = read(root, "Sources/Phosphor/Views/Backup/BackupProfileSelectorView.swift")
    preflight_src = read(root, "Sources/Phosphor/Views/Backup/BackupPreflightSheet.swift")
    content_src = read(root, "Sources/Phosphor/Views/ContentView.swift")
    overview_src = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")

    assert_contains(sheet_src, "struct AppExclusionView: View", "AppExclusionView must exist")
    assert_contains(sheet_src, "Profile Details & Custom Inclusions", "AppExclusionSheet must have proper title")
    assert_contains(sheet_src, "listInstalledAppsWithSizes", "AppExclusionSheet must query apps with sizes")
    assert_contains(sheet_src, "appsTabContent", "AppExclusionSheet must provide application inclusion list")

    assert_contains(selector_src, "struct BackupProfileSelectorView: View", "BackupProfileSelectorView must exist")
    assert_contains(selector_src, "Backup Profile", "BackupProfileSelectorView must show profile title")
    assert_contains(selector_src, "contentSummary", "BackupProfileSelectorView must inspect transparent content summary")

    assert_contains(preflight_src, "BackupProfileSelectorView", "BackupPreflightSheet must embed BackupProfileSelectorView")
    assert_contains(preflight_src, "AppExclusion", "BackupPreflightSheet must embed AppExclusion view")
    assert_contains(preflight_src, '"Backup Mode"', "BackupPreflightSheet must let the user switch between Full and Incremental when an existing backup exists")
    assert_contains(preflight_src, ".task(id: backupDirectory)", "BackupPreflightSheet must check existing backup asynchronously off main thread")
    assert_contains(content_src, "BackupPreflightSheet", "ContentView must present BackupPreflightSheet at root level")
    assert_contains(content_src, ".sheet(item: $preflightDevice)", "ContentView must use item-bound sheet to prevent empty initial preflight frame")
    assert_contains(overview_src, "onShowPreflight", "DeviceOverviewView must trigger preflight via callback")
    assert_contains(overview_src, "if let onShowPreflight {\n            onShowPreflight(device)", "DeviceOverviewView.startBackup must route normal backups through onShowPreflight")
