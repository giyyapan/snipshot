#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Snipshot.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "=== Building Snipshot ==="

# Create directories (preserve existing .app bundle to keep TCC permissions)
mkdir -p "$MACOS" "$RESOURCES"

# Compile Swift sources (overwrites binary in-place)
echo "Compiling..."
swiftc \
    -Onone \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Cocoa \
    -framework Carbon \
    -framework VisionKit \
    "$PROJECT_DIR/Snipshot/main.swift" \
    "$PROJECT_DIR/Snipshot/AppDelegate.swift" \
    "$PROJECT_DIR/Snipshot/UIComponents.swift" \
    "$PROJECT_DIR/Snipshot/OverlayWindow.swift" \
    "$PROJECT_DIR/Snipshot/OverlayPanels.swift" \
    "$PROJECT_DIR/Snipshot/OCRMode.swift" \
    "$PROJECT_DIR/Snipshot/PinWindow.swift" \
    "$PROJECT_DIR/Snipshot/Annotation.swift" \
    -o "$MACOS/Snipshot"

# Copy Info.plist and entitlements
cp "$PROJECT_DIR/Snipshot/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_DIR/Snipshot/Snipshot.entitlements" "$RESOURCES/Snipshot.entitlements"

# Sign with self-signed "Snipshot Dev" certificate for stable identity across rebuilds
# (Run setup_cert.sh first if certificate doesn't exist)
SIGN_IDENTITY="Snipshot Dev"
echo "Signing with '$SIGN_IDENTITY'..."
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Snipshot/Snipshot.entitlements" "$APP_BUNDLE"

echo "=== Build complete: $APP_BUNDLE ==="
echo ""
echo "To run: open $APP_BUNDLE"
echo "Or:     $MACOS/Snipshot"
