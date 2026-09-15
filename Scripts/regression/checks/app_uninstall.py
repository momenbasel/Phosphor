from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_bulk_uninstall_selects_only_user_apps_and_keeps_failed_selection(root: Path) -> None:
    """Issue #79: system apps cannot enter a removal batch; failed app IDs remain
    selected so the user can retry only those failures."""
    view = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/AppViewModel.swift")

    assert "@State private var selectedAppIDs: Set<String> = []" in view
    assert "app.appType == .user" in view, "only user apps may be selectable for removal"
    assert "Uninstall Selected" in view, "the device-app list needs a bulk removal action"
    assert "confirmationDialog" in view, "bulk removal needs an explicit destructive confirmation"
    assert "selectedAppIDs.subtract(successfulIDs)" in view, (
        "only successfully removed IDs may leave the selection; failures must remain for retry"
    )
    assert "selectedAppIDs.formIntersection" in view, (
        "selection must not retain IDs that disappear after a same-device refresh"
    )
    assert "func uninstall(bundleIds: [String], udid: String) async -> Set<String>" in view_model
    assert "app.appType == .user" in view_model, "the view model must reject system-app removal too"
    assert "activeInstalledDeviceID" in view_model, "uninstall completion must be scoped to the loaded device"
    assert "guard activeInstalledDeviceID == udid" in view_model, (
        "switching devices must prevent stale uninstall results from mutating the new device list"
    )
    prepare_signature = "func prepareForInstalledDevice(_ udid: String?, isDeviceTabActive: Bool)"
    assert prepare_signature in view_model, "device identity changes must be scoped to the visible app source"
    prepare_body = view_model.split(prepare_signature, 1)[1].split(
        "func loadInstalledApps", 1
    )[0]
    assert "guard activeInstalledDeviceID != udid else { return }" in prepare_body, (
        "same-device refresh must not blank a valid installed-app list"
    )
    assert "installedApps = []" in prepare_body, (
        "switching between non-nil devices must clear stale rows before destructive actions are available"
    )
    assert "if isDeviceTabActive && udid == nil" in prepare_body, (
        "device disconnects must stop only the visible device-list spinner, not an active backup-app load"
    )
    assert "appVM.prepareForInstalledDevice(newDeviceID, isDeviceTabActive: activeTab == .device)" in view
    assert "@Published private(set) var isUninstalling = false" in view_model
    assert "guard !isUninstalling" in view_model, "overlapping destructive uninstall tasks must be rejected"
    assert "appVM.isUninstalling" in view, "bulk uninstall controls must stay disabled while removal is active"
    assert "@Published private(set) var isUninstalling" in view_model, (
        "one shared operation gate must prevent overlapping row and bulk uninstalls"
    )
    assert "guard !isUninstalling else" in view_model
    assert ".disabled(appVM.isUninstalling)" in view, "all uninstall affordances must honor the gate"


def test_uninstall_removes_successes_locally_without_reloading_the_list(root: Path) -> None:
    """Issue #79: local row removal preserves the current List scroll position."""
    view_model = read(root, "Sources/Phosphor/ViewModels/AppViewModel.swift")

    assert "installedApps.removeAll { $0.id == bundleId }" in view_model
    assert "installedApps.removeAll { successfulIDs.contains($0.id) }" in view_model

    uninstall_body = view_model.split("func uninstall(bundleId: String, udid: String) async", 1)[1].split(
        "func uninstall(bundleIds: [String], udid: String) async -> Set<String>", 1
    )[0]
    bulk_body = view_model.split("func uninstall(bundleIds: [String], udid: String) async -> Set<String>", 1)[1].split(
        "func extractAppData", 1
    )[0]
    assert "loadInstalledApps" not in uninstall_body, "single removal must not reload and jump the list"
    assert "loadInstalledApps" not in bulk_body, "bulk removal must not reload and jump the list"
