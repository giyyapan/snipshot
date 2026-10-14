#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-safe-font-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

# Run under both optimization levels: the nil check must survive -O, which is
# what build.sh uses for the shipping app.
for OPT in -Onone -O; do
    swiftc \
        -swift-version 5 \
        "$OPT" \
        -target arm64-apple-macosx14.0 \
        -sdk "$(xcrun --show-sdk-path)" \
        -framework Cocoa \
        "$PROJECT_DIR/Snipshot/SafeFont.swift" \
        "$PROJECT_DIR/Tests/SafeFontTests.swift" \
        -o "$TEST_BINARY"
    echo "[$OPT]"
    "$TEST_BINARY"
done
