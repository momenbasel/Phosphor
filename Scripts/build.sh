#!/bin/bash
set -euo pipefail

# Phosphor Build Script
# Builds the Swift package and creates a proper macOS .app bundle

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="Phosphor"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
RELEASE_DIR="$BUILD_DIR/release"

echo "==> Building Phosphor..."

cd "$PROJECT_DIR"

# Build release binary
swift build -c release 2>&1

BINARY_PATH=$(swift build -c release --show-bin-path)/${APP_NAME}

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "==> Creating app bundle..."

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy icon if exists
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copy entitlements for reference
cp "$PROJECT_DIR/Resources/Phosphor.entitlements" "$APP_BUNDLE/Contents/Resources/"

# Copy SPM resource bundle (localization strings)
RESOURCE_BUNDLE="$BINARY_PATH/../Phosphor_Phosphor.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "==> Copied localization resource bundle"
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> App bundle created at: $APP_BUNDLE"
echo "==> Binary size: $(du -sh "$APP_BUNDLE/Contents/MacOS/${APP_NAME}" | cut -f1)"
echo "==> Bundle size: $(du -sh "$APP_BUNDLE" | cut -f1)"

# Verify bundle structure
echo "==> Bundle contents:"
find "$APP_BUNDLE" -type f | sort | while read -r f; do
    echo "    $(echo "$f" | sed "s|$APP_BUNDLE/||")"
done

echo ""
echo "==> Build complete! Run with: open $APP_BUNDLE"
