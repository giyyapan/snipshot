#!/bin/bash
set -e

# Ensure Homebrew binaries are in PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# =============================================================================
# release.sh — Publish a Snipshot update via GitHub Releases + Sparkle
#
# Usage:
#   ./release.sh                 Auto-detect version from Info.plist
#   ./release.sh 0.3.0           Specify version explicitly
#
# Prerequisites:
#   1. Run ./build.sh prod first (creates the notarized DMG)
#   2. gh CLI installed and authenticated (brew install gh && gh auth login)
#   3. Sparkle private key at keys/sparkle_private_key.pem
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
VENDOR_DIR="$PROJECT_DIR/vendor"
KEYS_DIR="$PROJECT_DIR/keys"
SPARKLE_PRIVATE_KEY="$KEYS_DIR/sparkle_private_key.pem"
SIGN_UPDATE="$VENDOR_DIR/bin/sign_update"
GITHUB_REPO="giyyapan/snipshot"

# --- Determine version ---
if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$(defaults read "$BUILD_DIR/Snipshot.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
fi

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not determine version. Run ./build.sh prod first, or pass version as argument."
    exit 1
fi

DMG_NAME="Snipshot-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TAG="v${VERSION}"
APPCAST_PATH="$BUILD_DIR/appcast.xml"

echo "=== Publishing Snipshot ${VERSION} ==="
echo ""

# --- Validate prerequisites ---
if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG not found: $DMG_PATH"
    echo "Run ./build.sh prod first."
    exit 1
fi

if [ ! -f "$SPARKLE_PRIVATE_KEY" ]; then
    echo "ERROR: Sparkle private key not found: $SPARKLE_PRIVATE_KEY"
    echo "Run: ./vendor/bin/generate_keys -x keys/sparkle_private_key.pem"
    exit 1
fi

if ! command -v gh &> /dev/null; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if [ ! -f "$SIGN_UPDATE" ]; then
    echo "ERROR: sign_update not found: $SIGN_UPDATE"
    echo "Run ./build.sh first to download Sparkle."
    exit 1
fi

# =============================================================================
# Step 1: Sign DMG with Sparkle EdDSA key
# =============================================================================
echo "Signing DMG with Sparkle EdDSA key..."
SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" --ed-key-file "$SPARKLE_PRIVATE_KEY" 2>&1)
echo "  Signature: $SIGNATURE"

# Parse signature components: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
FILE_LENGTH=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | sed 's/length="//;s/"//')

if [ -z "$ED_SIGNATURE" ]; then
    echo "ERROR: Failed to get EdDSA signature from sign_update."
    echo "Raw output: $SIGNATURE"
    exit 1
fi

echo "  EdDSA signature: $ED_SIGNATURE"
echo "  File length: $FILE_LENGTH"

# =============================================================================
# Step 2: Get build number from Info.plist
# =============================================================================
BUILD_NUMBER=$(defaults read "$BUILD_DIR/Snipshot.app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

# =============================================================================
# Step 3: Create or update GitHub Release
# =============================================================================
echo ""
echo "Creating GitHub Release ${TAG}..."

# The download URL for the DMG once uploaded to the release
DMG_DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_NAME}"

# Check if release already exists
if gh release view "$TAG" -R "$GITHUB_REPO" &>/dev/null; then
    echo "  Release ${TAG} already exists, updating..."
    gh release upload "$TAG" "$DMG_PATH" --clobber -R "$GITHUB_REPO"
else
    echo "  Creating new release ${TAG}..."
    gh release create "$TAG" \
        --title "Snipshot ${VERSION}" \
        --notes "Snipshot ${VERSION}" \
        --repo "$GITHUB_REPO" \
        "$DMG_PATH"
fi

echo "  DMG uploaded to: $DMG_DOWNLOAD_URL"

# =============================================================================
# Step 4: Generate appcast.xml
# =============================================================================
echo ""
echo "Generating appcast.xml..."

PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

# Check if an existing appcast exists in the repo (download from latest release)
EXISTING_APPCAST=""
if gh release view latest -R "$GITHUB_REPO" &>/dev/null; then
    gh release download latest -R "$GITHUB_REPO" -p "appcast.xml" -D "$BUILD_DIR/tmp_appcast" --clobber 2>/dev/null || true
    if [ -f "$BUILD_DIR/tmp_appcast/appcast.xml" ]; then
        EXISTING_APPCAST="$BUILD_DIR/tmp_appcast/appcast.xml"
    fi
fi

# Build the new item XML
NEW_ITEM=$(cat <<ITEM_EOF
        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure url="${DMG_DOWNLOAD_URL}" length="${FILE_LENGTH}" type="application/octet-stream" sparkle:edSignature="${ED_SIGNATURE}" />
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        </item>
ITEM_EOF
)

if [ -n "$EXISTING_APPCAST" ] && grep -q "<channel>" "$EXISTING_APPCAST"; then
    # Insert new item at the top of the channel (after <language> line)
    # First, remove any existing item with the same version
    TEMP_APPCAST="$BUILD_DIR/tmp_appcast_edit.xml"
    python3 -c "
import re, sys

with open('$EXISTING_APPCAST', 'r') as f:
    content = f.read()

# Remove existing item for this version if present
pattern = r'\\s*<item>.*?<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>.*?</item>'
content = re.sub(pattern, '', content, flags=re.DOTALL)

# Insert new item after <language>en</language> or after <channel>
new_item = '''
${NEW_ITEM}'''

if '<language>' in content:
    content = re.sub(r'(</language>)', r'\\1' + new_item, content, count=1)
elif '<channel>' in content:
    content = re.sub(r'(<channel>)', r'\\1' + new_item, content, count=1)

with open('$APPCAST_PATH', 'w') as f:
    f.write(content)
"
    rm -rf "$BUILD_DIR/tmp_appcast"
else
    # Create fresh appcast
    cat > "$APPCAST_PATH" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Snipshot Changelog</title>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
${NEW_ITEM}
    </channel>
</rss>
APPCAST_EOF
fi

echo "  Generated: $APPCAST_PATH"
cat "$APPCAST_PATH"

# =============================================================================
# Step 5: Upload appcast.xml to the SAME release (tagged release)
# =============================================================================
echo ""
echo "Uploading appcast.xml to release ${TAG}..."
gh release upload "$TAG" "$APPCAST_PATH" --clobber -R "$GITHUB_REPO"

# Also upload to a "latest" release so the app can always find the appcast
# Check if "latest" release exists
if gh release view latest -R "$GITHUB_REPO" &>/dev/null; then
    echo "Updating 'latest' release with new appcast.xml..."
    gh release upload latest "$APPCAST_PATH" --clobber -R "$GITHUB_REPO"
else
    echo "Creating 'latest' release for appcast.xml..."
    gh release create latest \
        --title "Latest Update Feed" \
        --notes "This release hosts the Sparkle appcast.xml. Do not delete." \
        --repo "$GITHUB_REPO" \
        "$APPCAST_PATH"
fi

echo ""
echo "=== Release ${VERSION} published! ==="
echo ""
echo "  GitHub Release: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "  DMG URL:        ${DMG_DOWNLOAD_URL}"
echo "  Appcast URL:    https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
echo ""
echo "  Users with Snipshot installed will be notified of this update automatically."
