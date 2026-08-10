#!/bin/bash
# Local release: build, sign, notarize, staple, tag, publish, bump cask.
# Reads ASC API key from ~/.appstoreconnect/private_keys/.
# Usage: bash Scripts/release-local.sh v1.0.6

set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    echo "Usage: $0 vX.Y.Z"
    exit 1
fi
VERSION="${TAG#v}"

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Moamen Basel (H3WXHVTP97)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
REPO="${REPO:-momenbasel/Phosphor}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP=".build/Phosphor.app"
DMG=".build/Phosphor.dmg"
ENTITLEMENTS="Resources/Phosphor.entitlements"
PLIST="Resources/Info.plist"

# Stamp the bundle version from the tag before building. Nothing else in the
# pipeline writes Info.plist, so on every previous release this was a manual
# step that could be forgotten. Since the built-in update checker compares the
# shipped CFBundleShortVersionString against the newest GitHub tag, a stale
# plist is no longer cosmetic: it tells every user of the new build that an
# update is available and hands them the DMG they are already running.
echo "==> Stamping $PLIST to $VERSION"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$PLIST"
echo "    CFBundleShortVersionString=$VERSION CFBundleVersion=$((CURRENT_BUILD + 1))"
if ! git diff --quiet "$PLIST"; then
    git add "$PLIST"
    git commit -m "release: stamp bundle version $VERSION"
fi

echo "==> Building release (universal arm64 + x86_64)"
rm -rf .build
# Ship a universal binary so the app runs on both Apple Silicon and Intel Macs
# (issue #44). Scripts/build.sh honors PHOSPHOR_UNIVERSAL for the bundled binary.
export PHOSPHOR_UNIVERSAL=1
swift build -c release --arch arm64 --arch x86_64
bash Scripts/build.sh

echo "==> Verifying universal binary slices"
BINARY="$APP/Contents/MacOS/Phosphor"
if ! lipo -archs "$BINARY" | grep -q "x86_64" || ! lipo -archs "$BINARY" | grep -q "arm64"; then
    echo "ERROR: $BINARY is not universal (arch: $(lipo -archs "$BINARY")). Aborting release."
    exit 1
fi
echo "    slices: $(lipo -archs "$BINARY")"

echo "==> Signing app"
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    --sign "$DEVELOPER_ID" "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Creating DMG"
bash Scripts/create-dmg.sh

echo "==> Signing DMG"
codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"

echo "==> Submitting to Apple notary (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Verifying"
spctl -a -vv -t install "$DMG"
xcrun stapler validate "$DMG"

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "==> SHA256: $SHA"

# Publish the tag and the DMG in ONE step. The previous order pushed the tag
# first, which starts the CI release job; release-guard then asks whether the
# tag already has Phosphor.dmg attached, sees nothing (the upload had not
# happened yet) and lets CI build and notarize a competing DMG. Whichever
# upload lands last wins, while the cask is bumped from the LOCAL sha - which
# is exactly how issue #21 shipped casks pointing at a DMG that no longer
# existed. `gh release create` creates the tag, the release and the asset
# together, so by the time the tag event reaches CI the guard already sees a
# published DMG and stands down.
echo "==> Publishing $TAG with the DMG attached"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "    release $TAG already exists - uploading DMG"
    gh release upload "$TAG" --repo "$REPO" "$DMG" --clobber
else
    git push origin "$(git rev-parse --abbrev-ref HEAD)"
    gh release create "$TAG" --repo "$REPO" "$DMG" \
        --title "$TAG" --generate-notes --target "$(git rev-parse HEAD)"
fi

echo "==> Verifying the PUBLISHED asset matches what we built"
PUBLISHED_SHA="$(gh release download "$TAG" --repo "$REPO" --pattern 'Phosphor.dmg' \
    --output - | shasum -a 256 | awk '{print $1}')"
if [[ "$PUBLISHED_SHA" != "$SHA" ]]; then
    echo "ERROR: published DMG sha ($PUBLISHED_SHA) != built sha ($SHA)."
    echo "       Refusing to bump the casks - they would point at a DMG nobody has."
    exit 1
fi
echo "    published sha matches: $SHA"

echo "==> Bumping in-repo Homebrew cask"
CASK="Homebrew/phosphor.rb"
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$CASK"

if ! git diff --quiet "$CASK"; then
    git add "$CASK"
    git commit -m "homebrew: bump cask to $TAG"
    # main can have moved while the notary was running (a merged PR, or CI's own
    # cask commit). Rebase before pushing so the bump never fails with
    # "fetch first" and leave the release half-published.
    git fetch origin main
    git rebase origin/main
    git push origin HEAD:main
fi

# Keep the external tap (`brew install --cask momenbasel/phosphor/phosphor`) in
# lockstep with the in-repo cask. Historically these drifted (issue #21: the tap
# still pointed at an old SHA after a release), so sync it from the SAME SHA here
# instead of by hand.
echo "==> Syncing external Homebrew tap"
TAP_REPO="${TAP_REPO:-momenbasel/homebrew-phosphor}"
TAP_CASK_PATH="Casks/phosphor.rb"
TAP_TMP="$(mktemp -d)"
if git clone --depth 1 "https://github.com/${TAP_REPO}.git" "$TAP_TMP" >/dev/null 2>&1; then
    TAP_CASK="$TAP_TMP/$TAP_CASK_PATH"
    if [ -f "$TAP_CASK" ]; then
        /usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$TAP_CASK"
        /usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$TAP_CASK"
        if ! git -C "$TAP_TMP" diff --quiet; then
            git -C "$TAP_TMP" add "$TAP_CASK_PATH"
            git -C "$TAP_TMP" commit -m "phosphor: bump cask to $TAG (same DMG SHA as in-repo cask)"
            git -C "$TAP_TMP" push origin HEAD
            echo "    external tap synced to ${VERSION} / ${SHA}"
        else
            echo "    external tap already at ${VERSION} / ${SHA}"
        fi
    else
        echo "    WARNING: $TAP_CASK_PATH missing in $TAP_REPO - sync it manually"
    fi
else
    echo "    WARNING: could not clone $TAP_REPO - external tap NOT updated (fix manually to avoid SHA drift)"
fi
rm -rf "$TAP_TMP"

echo
echo "Released $TAG."
echo "  DMG: $DMG"
echo "  SHA: $SHA"
echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
