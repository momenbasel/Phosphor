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

if [ -x "$PROJECT_DIR/Scripts/regression/run.py" ]; then
    echo "==> Running regression checks..."
    "$PROJECT_DIR/Scripts/regression/run.py"
fi

# Build release binary. Set PHOSPHOR_UNIVERSAL=1 to produce a universal
# arm64 + x86_64 binary so the app also runs on Intel Macs (issue #44). The
# default host-arch build stays fast for local/CI compile checks.
ARCH_FLAGS=""
if [ "${PHOSPHOR_UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
    echo "==> Universal build (arm64 + x86_64)"
fi

# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS 2>&1

# shellcheck disable=SC2086
BINARY_PATH=$(swift build -c release $ARCH_FLAGS --show-bin-path)/${APP_NAME}

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

# SwiftUI's implicit LocalizedStringKey lookup uses Bundle.main. Copy the
# .lproj directories into the app's main resources so runtime-created labels
# and literal Text("...") values both resolve localized strings.
for localization in "$PROJECT_DIR/Sources/Phosphor/Resources"/*.lproj; do
    if [ -d "$localization" ]; then
        cp -R "$localization" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# Copy SPM resource bundle (localization strings)
# dirname, not "$BINARY_PATH/..": the latter traverses '..' through the binary
# file itself (ENOTDIR), so the -d test always failed and the localization
# bundle was silently never copied into the app.
RESOURCE_BUNDLE="$(dirname "$BINARY_PATH")/Phosphor_Phosphor.bundle"
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
