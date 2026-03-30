# Developer Setup Guide

This guide walks through setting up a new development machine for building and signing Snipshot.

## Prerequisites

- macOS 14.0+ (Apple Silicon)
- Xcode Command Line Tools: `xcode-select --install`
- `gh` CLI (for publishing releases): `brew install gh`

## 1. Obtain Signing Credentials

Contact **@giyyapan** to get the following files, and place them in the `keys/` directory at the project root:

| File | Purpose |
|---|---|
| `Certificates.p12` | Developer ID Application certificate + private key (password-protected) |
| `AuthKey_F34YUX6BRT.p8` | App Store Connect API key (for notarization) |
| `sparkle_private_key.pem` | Sparkle EdDSA key (for signing auto-update feeds) |

Also ask @giyyapan for the `.p12` password. You will need it in the next step.

> **Important**: The `keys/` directory is gitignored. Never commit these files.

## 2. Import Certificate Chain

The Developer ID certificate requires a complete trust chain: **Apple Root CA → Developer ID Certification Authority (G2) → Developer ID Application**. macOS needs all three to be present and trusted.

### Step 1: Download Apple intermediate and root certificates

```bash
# Developer ID G2 intermediate certificate
curl -sO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer

# Apple Root CA
curl -sO https://www.apple.com/appleca/AppleIncRootCertificate.cer
```

### Step 2: Import the intermediate and root certificates into System keychain

```bash
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain ./AppleIncRootCertificate.cer

sudo security import ./DeveloperIDG2CA.cer \
    -k /Library/Keychains/System.keychain
```

### Step 3: Import the intermediate and root certificates into login keychain

This is necessary because the Developer ID Application certificate lives in the login keychain, and `codesign` needs to build the full chain from the same keychain search path.

```bash
# Export PEM from System keychain, then import to login keychain
security find-certificate -c "Developer ID Certification Authority" -p \
    /Library/Keychains/System.keychain > /tmp/devid_intermediate.pem
security import /tmp/devid_intermediate.pem -k ~/Library/Keychains/login.keychain-db

security find-certificate -c "Apple Root CA" -p \
    /Library/Keychains/System.keychain > /tmp/apple_root.pem
security import /tmp/apple_root.pem -k ~/Library/Keychains/login.keychain-db
```

### Step 4: Import the .p12 certificate with private key

```bash
security import keys/Certificates.p12 \
    -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign
```

You will be prompted for the `.p12` password (get it from @giyyapan). The `-T /usr/bin/codesign` flag grants codesign access to the private key.

### Step 5: Unlock the login keychain

If running from a terminal session (especially SSH or CI), you may need to unlock the keychain first:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

Enter your macOS login password when prompted.

## 3. Verify the Setup

Run the following to confirm everything is in place:

```bash
# Should show 1 valid identity
security find-identity -p codesigning -v

# Expected output:
#   1) XXXXXXXX "Developer ID Application: DI WU (AN68AMD3JC)"
#      1 valid identities found
```

If it shows `0 valid identities found`, the certificate chain is incomplete. Re-check steps 2 and 3.

## 4. Build

```bash
bash build.sh
open build/Snipshot.app
```

The build script will:
1. Download Sparkle.framework (first time only)
2. Compile all Swift source files with `swiftc`
3. Embed and sign Sparkle components (inside-out)
4. Sign the app bundle with Developer ID + hardened runtime

## 5. Iterate During Development

```bash
# Edit source files, then:
bash build.sh
pkill -f Snipshot; sleep 1; open build/Snipshot.app
```

## 6. Publish a Release

1. Update version in `Snipshot/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`) and `Snipshot/SettingsWindow.swift` (`kSnipshotVersion`).
2. Test locally: `bash build.sh`
3. Notarize and publish: `bash build.sh release`

This will compile, sign, create a DMG, notarize with Apple, staple the ticket, and publish to GitHub Releases with an updated `appcast.xml` for Sparkle auto-updates.

## Troubleshooting

### `errSecInternalComponent` during codesign

The login keychain is locked or the private key is not accessible. Fix:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

### `unable to build chain to self-signed root`

The certificate chain is incomplete. Verify all three certificates are present:

```bash
# Check Developer ID Application cert
security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -subject -issuer

# Check intermediate cert
security find-certificate -c "Developer ID Certification Authority" -p | openssl x509 -noout -subject -issuer

# Check root cert
security find-certificate -c "Apple Root CA" -p | openssl x509 -noout -subject -issuer
```

The chain should be: `Apple Root CA` → `Developer ID Certification Authority (G2)` → `Developer ID Application: DI WU (AN68AMD3JC)`.

If any certificate is missing, re-import it following Step 2 above.

### `0 valid identities found` but certificate is listed

The private key is missing or doesn't match the certificate. Re-import the `.p12` file (Step 4).

### `ERROR: No trusted Developer ID Application certificate found`

The build script's `security find-identity` check filters out untrusted certificates. This means either:
- The `.p12` was not imported (run Step 4)
- The keychain is locked (run `security unlock-keychain`)
- The certificate chain is broken (run the chain verification commands above)
