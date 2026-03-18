#!/bin/bash
set -e

CERT_NAME="Snipshot Dev"
WORK_DIR=$(mktemp -d)

echo "=== Creating self-signed code signing certificate: '$CERT_NAME' ==="

# Check if cert already exists
if security find-identity -p codesigning 2>&1 | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists. Skipping creation."
    echo ""
    echo "To verify: security find-identity -p codesigning"
    exit 0
fi

cd "$WORK_DIR"

# Generate key and certificate
echo "Generating key and certificate..."
openssl req -x509 -newkey rsa:2048 -days 3650 \
    -keyout dev.key -out dev.crt -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

# Convert to p12 (macOS import format)
# -legacy flag required for macOS Keychain compatibility
echo "Converting to p12..."
openssl pkcs12 -export -legacy \
    -in dev.crt -inkey dev.key \
    -out dev.p12 -password pass:dev \
    2>/dev/null

# Import to login keychain
echo "Importing to login keychain..."
security import dev.p12 -k ~/Library/Keychains/login.keychain-db \
    -P dev -T /usr/bin/codesign

# Cleanup temp files
rm -rf "$WORK_DIR"

echo ""
echo "=== Certificate imported! ==="
echo ""
echo "IMPORTANT: You must now trust the certificate for code signing:"
echo "  1. Open Keychain Access (Cmd+Space, type 'Keychain Access')"
echo "  2. Search for '$CERT_NAME'"
echo "  3. Double-click the certificate"
echo "  4. Expand 'Trust'"
echo "  5. Set 'Code Signing' to 'Always Trust'"
echo "  6. Close and enter your password"
echo ""
echo "After trusting, verify with:"
echo "  security find-identity -p codesigning"
