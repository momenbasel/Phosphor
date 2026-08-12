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


def parse_version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split(".") if part.isdigit())


def test_info_plist_version_is_never_behind_the_cask(root: Path) -> None:
    """The failure that hurts users is a shipped app reporting an OLDER version
    than the release it came from: the update checker then compares against the
    newest tag, decides an update exists, and hands the user the DMG they are
    already running, forever.

    Equality cannot be required, because a release legitimately passes through a
    window where it is not true. The plist has to be stamped before the app is
    built, but the cask can only be bumped after the DMG exists and its sha256 is
    known, so mid-release the plist is one version ahead by construction. Only
    "behind" is drift.
    """
    short_version, _ = plist_versions(root)
    cask = cask_version(root)
    plist_parts, cask_parts = parse_version(short_version), parse_version(cask)
    assert plist_parts, f"CFBundleShortVersionString {short_version!r} is not numeric"
    assert cask_parts, f"cask version {cask!r} is not numeric"
    assert plist_parts >= cask_parts, (
        f"Resources/Info.plist CFBundleShortVersionString is {short_version!r} but "
        f"Homebrew/phosphor.rb already ships {cask!r}. A shipped build that reports "
        "an older version than the published release tells every user an update is "
        "available and then hands them the build they are already running. Stamp "
        "the plist from the tag."
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
