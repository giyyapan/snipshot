#!/bin/bash
set -e

# =============================================================================
# setup_signing.sh — Create Developer ID Application certificate via
#                    App Store Connect API and import into Keychain.
#
# Prerequisites:
#   - macOS with Xcode command line tools
#   - Python 3 with PyJWT: pip3 install pyjwt cryptography
#   - App Store Connect API Key (.p8) at keys/AuthKey_<KEY_ID>.p8
#
# Usage:
#   ./setup_signing.sh          Create and import certificate
#   ./setup_signing.sh status   Check if Developer ID cert exists
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$PROJECT_DIR/keys"

# --- App Store Connect API credentials ---
API_KEY_ID="F34YUX6BRT"
API_ISSUER_ID="cee32055-ad0c-4658-aba5-e22215d14fef"
TEAM_ID="AN68AMD3JC"
API_KEY_FILE="$KEYS_DIR/AuthKey_${API_KEY_ID}.p8"

SIGN_IDENTITY_PREFIX="Developer ID Application"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Helper: check for Developer ID cert ---
check_developer_id_cert() {
    security find-identity -p codesigning -v 2>/dev/null \
        | grep "$SIGN_IDENTITY_PREFIX" \
        | grep -v "CSSMERR_TP_NOT_TRUSTED" \
        | head -1
}

# --- Status check ---
if [ "${1:-}" = "status" ]; then
    echo "=== Checking signing identities ==="
    echo ""
    echo "All codesigning identities:"
    security find-identity -p codesigning
    echo ""
    MATCH=$(check_developer_id_cert)
    if [ -n "$MATCH" ]; then
        echo "✓ Developer ID Application certificate found:"
        echo "  $MATCH"
    else
        echo "✗ No trusted Developer ID Application certificate found."
        echo "  Run ./setup_signing.sh to create one."
    fi
    exit 0
fi

# --- Preflight checks ---
echo "=== Setting up Developer ID Application certificate ==="
echo ""

# Check if cert already exists
EXISTING=$(check_developer_id_cert)
if [ -n "$EXISTING" ]; then
    echo "Developer ID Application certificate already exists:"
    echo "  $EXISTING"
    echo ""
    echo "To recreate, first revoke the existing certificate in"
    echo "App Store Connect or Xcode, then run this script again."
    exit 0
fi

# Check API key file
if [ ! -f "$API_KEY_FILE" ]; then
    echo "ERROR: API key file not found: $API_KEY_FILE"
    echo ""
    echo "Place your App Store Connect API key (.p8) at:"
    echo "  $API_KEY_FILE"
    exit 1
fi

# Check Python + PyJWT
if ! python3 -c "import jwt" 2>/dev/null; then
    echo "Installing PyJWT..."
    pip3 install pyjwt cryptography --quiet
fi

# --- Step 1: Generate CSR ---
echo "Step 1/4: Generating certificate signing request..."
CSR_KEY="$WORK_DIR/csr.key"
CSR_FILE="$WORK_DIR/csr.pem"

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$CSR_KEY" \
    -out "$CSR_FILE" \
    -subj "/CN=Snipshot Developer/O=$TEAM_ID" \
    2>/dev/null

CSR_CONTENT=$(cat "$CSR_FILE")

# --- Step 2: Generate JWT ---
echo "Step 2/4: Generating JWT for API authentication..."

JWT_TOKEN=$(python3 << PYEOF
import jwt, time, json

with open("$API_KEY_FILE", "r") as f:
    private_key = f.read()

now = int(time.time())
payload = {
    "iss": "$API_ISSUER_ID",
    "iat": now,
    "exp": now + 1200,  # 20 minutes
    "aud": "appstoreconnect-v1"
}
headers = {
    "alg": "ES256",
    "kid": "$API_KEY_ID",
    "typ": "JWT"
}

token = jwt.encode(payload, private_key, algorithm="ES256", headers=headers)
print(token)
PYEOF
)

# --- Step 3: Create certificate via API ---
echo "Step 3/4: Requesting Developer ID Application certificate from Apple..."

# Prepare request body
REQUEST_BODY=$(python3 << PYEOF
import json
csr = """$CSR_CONTENT"""
body = {
    "data": {
        "type": "certificates",
        "attributes": {
            "certificateType": "DEVELOPER_ID_APPLICATION",
            "csrContent": csr.strip()
        }
    }
}
print(json.dumps(body))
PYEOF
)

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.appstoreconnect.apple.com/v1/certificates" \
    -H "Authorization: Bearer $JWT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "201" ]; then
    echo "ERROR: Apple API returned HTTP $HTTP_CODE"
    echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE_BODY"
    exit 1
fi

echo "  Certificate created successfully!"

# --- Step 4: Extract and import certificate ---
echo "Step 4/4: Importing certificate into Keychain..."

# Extract certificate content (base64 DER)
CERT_CONTENT=$(echo "$RESPONSE_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['data']['attributes']['certificateContent'])
")

# Decode to DER
echo "$CERT_CONTENT" | base64 -d > "$WORK_DIR/developer_id.cer"

# Also download Apple intermediate certificates (required for chain)
echo "  Downloading Apple intermediate certificates..."
curl -sL "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer" \
    -o "$WORK_DIR/DeveloperIDG2CA.cer" 2>/dev/null || true

# Import intermediate cert if downloaded
if [ -f "$WORK_DIR/DeveloperIDG2CA.cer" ]; then
    security import "$WORK_DIR/DeveloperIDG2CA.cer" \
        -k ~/Library/Keychains/login.keychain-db \
        2>/dev/null || true
fi

# Create p12 from private key + certificate for Keychain import
openssl x509 -inform DER -in "$WORK_DIR/developer_id.cer" \
    -out "$WORK_DIR/developer_id.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
    -in "$WORK_DIR/developer_id.pem" \
    -inkey "$CSR_KEY" \
    -out "$WORK_DIR/developer_id.p12" \
    -password pass:snipshot \
    2>/dev/null

# Import to login keychain
security import "$WORK_DIR/developer_id.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P snipshot \
    -T /usr/bin/codesign

# Allow codesign to access without prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Verifying..."
security find-identity -p codesigning -v | grep "$SIGN_IDENTITY_PREFIX" || {
    echo ""
    echo "WARNING: Certificate imported but may need trust configuration."
    echo "  1. Open Keychain Access"
    echo "  2. Find the Developer ID Application certificate"
    echo "  3. It should be automatically trusted (Apple-issued)"
    echo ""
    echo "All identities:"
    security find-identity -p codesigning
}
echo ""
echo "You can now run: ./build.sh prod"
