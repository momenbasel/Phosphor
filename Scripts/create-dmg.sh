#!/bin/bash
set -euo pipefail

# Create a distributable DMG for Phosphor

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/Phosphor.app"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/Phosphor.dmg"
VOLUME_NAME="Phosphor"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: App bundle not found. Run build.sh first."
    exit 1
fi

echo "==> Creating DMG..."

# Clean staging
rm -rf "$DMG_STAGING"
rm -f "$DMG_PATH"

# Create staging directory
mkdir -p "$DMG_STAGING"

# Copy app
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Create Applications symlink
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean staging
rm -rf "$DMG_STAGING"

echo "==> DMG created: $DMG_PATH"
echo "==> Size: $(du -sh "$DMG_PATH" | cut -f1)"
