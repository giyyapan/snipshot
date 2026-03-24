#!/bin/bash
set -e

# =============================================================================
# build.sh — Build Snipshot
#
# Usage:
#   ./build.sh              Dev build (self-signed, fast)
#   ./build.sh dev          Same as above
#   ./build.sh prod         Prod build (Developer ID + notarize + DMG)
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Snipshot.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

BUILD_MODE="${1:-dev}"

# --- Configuration per mode ---
KEYS_DIR="$PROJECT_DIR/keys"
API_KEY_ID="F34YUX6BRT"
API_ISSUER_ID="cee32055-ad0c-4658-aba5-e22215d14fef"
TEAM_ID="AN68AMD3JC"
API_KEY_FILE="$KEYS_DIR/AuthKey_${API_KEY_ID}.p8"
BUNDLE_ID="com.giyyapan.snipshot"

# --- Sparkle ---
VENDOR_DIR="$PROJECT_DIR/vendor"
SPARKLE_FRAMEWORK="$VENDOR_DIR/Sparkle.framework"
SPARKLE_VERSION="2.9.0"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [ "$BUILD_MODE" = "prod" ]; then
    SIGN_IDENTITY="Developer ID Application"
    SWIFT_OPT="-O"
    echo "=== Building Snipshot (PROD) ==="
else
    SIGN_IDENTITY="Snipshot Dev"
    SWIFT_OPT="-Onone"
    echo "=== Building Snipshot (DEV) ==="
fi

# =============================================================================
# Step 0: Ensure Sparkle.framework is available
# =============================================================================
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Downloading Sparkle ${SPARKLE_VERSION}..."
    mkdir -p "$VENDOR_DIR"
    curl -L -o "$VENDOR_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz" "$SPARKLE_URL"
    (cd "$VENDOR_DIR" && tar xf "Sparkle-${SPARKLE_VERSION}.tar.xz")
    echo "  Sparkle downloaded and extracted."
fi

# =============================================================================
# Step 1: Compile
# =============================================================================
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

echo "Compiling ($( [ "$BUILD_MODE" = "prod" ] && echo "optimized" || echo "debug" ))..."
swiftc \
    $SWIFT_OPT \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -F "$VENDOR_DIR" \
    -framework Cocoa \
    -framework Carbon \
    -framework VisionKit \
    -framework ServiceManagement \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$PROJECT_DIR/Snipshot/main.swift" \
    "$PROJECT_DIR/Snipshot/AppDelegate.swift" \
    "$PROJECT_DIR/Snipshot/UIComponents.swift" \
    "$PROJECT_DIR/Snipshot/OverlayWindow.swift" \
    "$PROJECT_DIR/Snipshot/OverlayPanels.swift" \
    "$PROJECT_DIR/Snipshot/OCRMode.swift" \
    "$PROJECT_DIR/Snipshot/PinWindow.swift" \
    "$PROJECT_DIR/Snipshot/SettingsWindow.swift" \
    "$PROJECT_DIR/Snipshot/OnboardingWindow.swift" \
    "$PROJECT_DIR/Snipshot/Annotation.swift" \
    -o "$MACOS/Snipshot"

# Copy resources
cp "$PROJECT_DIR/Snipshot/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_DIR/Snipshot/Snipshot.entitlements" "$RESOURCES/Snipshot.entitlements"
cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# =============================================================================
# Step 1.5: Embed Sparkle.framework
# =============================================================================
echo "Embedding Sparkle.framework..."
# Remove old copy if exists
rm -rf "$FRAMEWORKS/Sparkle.framework"
# Copy framework
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/"
# For non-sandboxed apps, XPCServices are not needed (saves ~2MB)
rm -rf "$FRAMEWORKS/Sparkle.framework/XPCServices"
rm -rf "$FRAMEWORKS/Sparkle.framework/Versions/B/XPCServices"

# =============================================================================
# Step 2: Code sign
# =============================================================================
echo "Signing with '$SIGN_IDENTITY'..."

if [ "$BUILD_MODE" = "prod" ]; then
    # Prod: find full Developer ID identity, sign with hardened runtime + timestamp
    FULL_IDENTITY=$(security find-identity -p codesigning -v \
        | grep "Developer ID Application" \
        | grep -v "CSSMERR_TP_NOT_TRUSTED" \
        | head -1 \
        | sed 's/.*"\(.*\)".*/\1/')

    if [ -z "$FULL_IDENTITY" ]; then
        echo ""
        echo "ERROR: No trusted Developer ID Application certificate found."
        echo "Run ./setup_signing.sh first to create one."
        exit 1
    fi

    echo "  Using: $FULL_IDENTITY"

    # Sign Sparkle components individually first (inside-out signing)
    echo "  Signing Sparkle components..."
    codesign --force --options runtime --timestamp \
        --sign "$FULL_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp \
        --sign "$FULL_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp \
        --sign "$FULL_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework"

    # Sign the main app bundle
    codesign --force --deep --options runtime --timestamp \
        --sign "$FULL_IDENTITY" \
        --entitlements "$PROJECT_DIR/Snipshot/Snipshot.entitlements" \
        "$APP_BUNDLE"
else
    # Dev: simple self-signed — sign Sparkle first, then the app
    codesign --force --sign "$SIGN_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework/Versions/B/Autoupdate"
    codesign --force --sign "$SIGN_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework/Versions/B/Updater.app"
    codesign --force --sign "$SIGN_IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "$PROJECT_DIR/Snipshot/Snipshot.entitlements" \
        "$APP_BUNDLE"
fi

echo "Signing complete."

# =============================================================================
# Dev mode: done here
# =============================================================================
if [ "$BUILD_MODE" != "prod" ]; then
    echo ""
    echo "=== Dev build complete: $APP_BUNDLE ==="
    echo "To run: open $APP_BUNDLE"
    exit 0
fi

# =============================================================================
# Step 3 (prod): Create DMG
# =============================================================================
echo ""
echo "Creating DMG..."

DMG_DIR="$BUILD_DIR/dmg_staging"
VERSION=$(defaults read "$CONTENTS/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_NAME="Snipshot-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create symlink to /Applications for drag-install
ln -s /Applications "$DMG_DIR/Applications"

# Build DMG
rm -f "$DMG_PATH"
hdiutil create -volname "Snipshot" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" \
    > /dev/null

rm -rf "$DMG_DIR"
echo "  Created: $DMG_PATH"

# =============================================================================
# Step 4 (prod): Notarize
# =============================================================================
echo ""
echo "Submitting for notarization..."
echo "  (This may take a few minutes)"

if [ ! -f "$API_KEY_FILE" ]; then
    echo "ERROR: API key file not found: $API_KEY_FILE"
    echo "Place your .p8 key at: $API_KEY_FILE"
    exit 1
fi

xcrun notarytool submit "$DMG_PATH" \
    --key "$API_KEY_FILE" \
    --key-id "$API_KEY_ID" \
    --issuer "$API_ISSUER_ID" \
    --wait

# =============================================================================
# Step 5 (prod): Staple
# =============================================================================
echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "=== Prod build complete! ==="
echo ""
echo "  DMG: $DMG_PATH"
echo "  Signed by: $FULL_IDENTITY"
echo "  Notarized & stapled: ✓"
echo ""
echo "  This DMG can be distributed to anyone."

# =============================================================================
# Step 6 (prod): Publish to GitHub Releases via release.sh
# =============================================================================
echo ""
echo "Publishing to GitHub Releases..."
bash "$PROJECT_DIR/release.sh" "$VERSION"
