#!/bin/bash
set -euo pipefail

# Phosphor Notarization Script
# Signs and notarizes the app for distribution

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/Phosphor.app"
DMG_PATH="$BUILD_DIR/Phosphor.dmg"
ENTITLEMENTS="$PROJECT_DIR/Resources/Phosphor.entitlements"

# Configuration - set these env vars or modify here
DEVELOPER_ID="${DEVELOPER_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}" # App-specific password from appleid.apple.com

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: App bundle not found. Run build.sh first."
    exit 1
fi

# Step 1: Code sign
echo "==> Code signing..."

if [ -z "$DEVELOPER_ID" ]; then
    # List available identities
    echo "Available signing identities:"
    security find-identity -v -p codesigning | head -20
    echo ""
    echo "Set DEVELOPER_ID env var to your 'Developer ID Application' identity."
    echo "Example: DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)' ./notarize.sh"

    # Ad-hoc sign for local testing
    echo ""
    echo "==> Ad-hoc signing for local use..."
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo "==> Ad-hoc signed. For distribution, use a Developer ID."
    exit 0
fi

codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE" || true

# Step 2: Create DMG for notarization
echo "==> Creating DMG..."
"$SCRIPT_DIR/create-dmg.sh"

# Step 3: Notarize
if [ -z "$APPLE_ID" ] || [ -z "$APP_PASSWORD" ] || [ -z "$TEAM_ID" ]; then
    echo "==> Skipping notarization (set APPLE_ID, APP_PASSWORD, TEAM_ID env vars)"
    echo "==> Signed DMG available at: $DMG_PATH"
    exit 0
fi

echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Notarization complete!"
echo "==> Distributable DMG: $DMG_PATH"
