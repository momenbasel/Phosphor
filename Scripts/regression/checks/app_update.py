from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_update_release_parsing_and_version_comparison_are_behavioral(root: Path) -> None:
    service = root / "Sources/Phosphor/Services/UpdateService.swift"
    assert service.exists(), "UpdateService.swift should provide the release-checking behavior"

    probe = r'''
import Foundation

enum AppVersion {
    static let current = "1.3.0"
}

@main
struct UpdateProbe {
    static func main() throws {
        precondition(UpdateService.isVersion("1.3.1", newerThan: "1.3.0"))
        precondition(UpdateService.isVersion("v2.0.0", newerThan: "1.99.99"))
        precondition(UpdateService.isVersion("1.10.0", newerThan: "1.9.9"))
        precondition(!UpdateService.isVersion("1.3.0", newerThan: "1.3.0"))
        precondition(!UpdateService.isVersion("1.2.9", newerThan: "1.3.0"))
        precondition(!UpdateService.isVersion("nightly", newerThan: "1.3.0"))

        let payload = #"{"tag_name":"v1.4.0","name":"Phosphor 1.4.0","html_url":"https://github.com/momenbasel/Phosphor/releases/tag/v1.4.0","body":"Release notes","draft":false,"prerelease":false,"assets":[{"name":"Phosphor.dmg","browser_download_url":"https://github.com/momenbasel/Phosphor/releases/download/v1.4.0/Phosphor.dmg"}]}"#.data(using: .utf8)!
        let release = try UpdateService.decodeRelease(from: payload)
        precondition(release.version == "1.4.0")
        precondition(release.downloadURL.absoluteString.hasSuffix("/Phosphor.dmg"))
        precondition(release.releaseNotesURL.absoluteString.hasSuffix("/v1.4.0"))

        let nullableMetadataPayload = #"{"tag_name":"v1.4.1","name":null,"html_url":"https://github.com/momenbasel/Phosphor/releases/tag/v1.4.1","body":null,"draft":false,"prerelease":false,"assets":[]}"#.data(using: .utf8)!
        let nullableMetadataRelease = try UpdateService.decodeRelease(from: nullableMetadataPayload)
        precondition(nullableMetadataRelease.version == "1.4.1")
        precondition(nullableMetadataRelease.downloadURL == nullableMetadataRelease.releaseNotesURL)

        let unsafeAssetPayload = #"{"tag_name":"v1.4.2","html_url":"https://github.com/momenbasel/Phosphor/releases/tag/v1.4.2","draft":false,"prerelease":false,"assets":[{"name":"Phosphor.dmg","browser_download_url":"x-phosphor-test://attacker/payload"}]}"#.data(using: .utf8)!
        let unsafeAssetRelease = try UpdateService.decodeRelease(from: unsafeAssetPayload)
        precondition(unsafeAssetRelease.downloadURL == unsafeAssetRelease.releaseNotesURL)

        let unsafeNotesPayload = #"{"tag_name":"v1.4.3","html_url":"file:///etc/passwd","draft":false,"prerelease":false,"assets":[]}"#.data(using: .utf8)!
        do {
            _ = try UpdateService.decodeRelease(from: unsafeNotesPayload)
            preconditionFailure("non-HTTPS release notes URL should be rejected")
        } catch UpdateServiceError.invalidRelease {
            // Expected.
        }
        print("PASS")
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "update-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(service), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS"


def test_update_checker_validates_github_response_and_uses_current_bundle_version(root: Path) -> None:
    service = read(root, "Sources/Phosphor/Services/UpdateService.swift")
    assert "https://api.github.com/repos/momenbasel/Phosphor/releases/latest" in service
    assert 'request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")' in service
    assert 'request.setValue("Phosphor/\\(currentVersion)", forHTTPHeaderField: "User-Agent")' in service
    assert "200..<300" in service, "GitHub HTTP failures must not be decoded as successful releases"
    assert "AppVersion.current" in service, "update checks should compare against the running bundle version"


def test_update_checker_is_available_from_the_app_menu_and_about_settings(root: Path) -> None:
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    settings = read(root, "Sources/Phosphor/Views/Settings/SettingsView.swift")
    controller = read(root, "Sources/Phosphor/ViewModels/UpdateViewModel.swift")

    assert 'CommandGroup(after: .appInfo)' in app
    assert 'Button("Check for Updates…")' in app
    assert ".disabled(updateController.isChecking)" in app
    assert ".environmentObject(updateController)" in app
    assert 'Button("Check for Updates")' in settings
    assert "updateController.isChecking" in settings
    assert 'alert.addButton(withTitle: "Download Update")' in controller
    assert 'alert.addButton(withTitle: "Release Notes")' in controller
    assert "NSWorkspace.shared.open(release.downloadURL)" in controller
