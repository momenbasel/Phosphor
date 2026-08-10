"""Keep the shipped bundle version tied to the released version.

Nothing in the pipeline used to write Resources/Info.plist, so its version was
maintained by hand and drifted from the tag whenever someone forgot. That was
cosmetic until the built-in update checker started comparing the shipped
CFBundleShortVersionString against the newest GitHub tag: a stale plist now
tells every user of the new build that an update is available and then hands
them the DMG they are already running, and the state never converges.

CI bumps Homebrew/phosphor.rb from the tag on every release, so pinning the
plist to the cask makes any drift fail on main immediately after a release.
"""
from __future__ import annotations

import plistlib
import re
from pathlib import Path


def cask_version(root: Path) -> str:
    cask = (root / "Homebrew/phosphor.rb").read_text()
    match = re.search(r'^\s*version\s+"([^"]+)"', cask, re.MULTILINE)
    assert match, "Homebrew/phosphor.rb has no version stanza"
    return match.group(1)


def plist_versions(root: Path) -> tuple[str, str]:
    with (root / "Resources/Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    return plist["CFBundleShortVersionString"], plist["CFBundleVersion"]


def test_info_plist_version_matches_cask(root: Path) -> None:
    short_version, _ = plist_versions(root)
    expected = cask_version(root)
    assert short_version == expected, (
        f"Resources/Info.plist CFBundleShortVersionString is {short_version!r} but "
        f"Homebrew/phosphor.rb ships {expected!r}. The update checker compares the "
        "shipped version against the newest GitHub tag, so a stale plist nags every "
        "user forever. Stamp the plist from the tag."
    )


def test_bundle_version_is_an_increasing_integer(root: Path) -> None:
    _, bundle_version = plist_versions(root)
    assert bundle_version.isdigit(), (
        f"CFBundleVersion must be a plain integer for notarization, got {bundle_version!r}"
    )


def test_release_script_stamps_the_bundle_version(root: Path) -> None:
    script = (root / "Scripts/release-local.sh").read_text()
    assert "Set :CFBundleShortVersionString" in script, (
        "Scripts/release-local.sh must stamp CFBundleShortVersionString from the tag "
        "instead of relying on someone remembering to bump it"
    )


def test_ci_release_job_stamps_the_bundle_version(root: Path) -> None:
    workflow = (root / ".github/workflows/build.yml").read_text()
    assert "Stamp bundle version from tag" in workflow, (
        "the CI release job must stamp Info.plist from the tag; a tag pushed on its "
        "own is a full release path that never touches the plist otherwise"
    )


def test_release_publishes_tag_and_dmg_together(root: Path) -> None:
    """Pushing the tag before uploading the DMG starts the CI release job while
    release-guard still sees no attached asset, so CI notarizes a competing DMG
    and races the local upload. The cask is bumped from the local sha, so the
    loser's sha is what users get told to download - the issue #21 failure."""
    script = (root / "Scripts/release-local.sh").read_text()
    assert "gh release create" in script, "the release must be published from the script"
    tag_push = script.find('git push origin "$TAG"')
    assert tag_push == -1, (
        "release-local.sh must not push the bare tag before attaching the DMG; use "
        "`gh release create <tag> <dmg> --target` so the tag and the asset land together"
    )


def test_release_verifies_published_sha_before_bumping_casks(root: Path) -> None:
    script = (root / "Scripts/release-local.sh").read_text()
    assert "PUBLISHED_SHA" in script, (
        "release-local.sh must re-download the published asset and compare its sha "
        "against the built DMG before rewriting either cask"
    )


def test_cask_uses_supported_depends_on_macos_syntax(root: Path) -> None:
    """`depends_on macos: ">= :sonoma"` is the string comparison form, which
    Homebrew marks odeprecated (Library/Homebrew/requirements/macos_requirement.rb
    parse()). A bare symbol already defaults to the ">=" comparator, so
    `depends_on macos: :sonoma` means the same thing and is the replacement
    Homebrew itself names."""
    cask = (root / "Homebrew/phosphor.rb").read_text()
    assert 'depends_on macos: ">=' not in cask, (
        "use `depends_on macos: :sonoma`; the string comparison form is deprecated "
        "and a bare symbol already defaults to >="
    )
    assert "depends_on macos:" in cask, "the cask must still declare a minimum macOS"
