#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-ai-provider-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT
swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Security \
    "$PROJECT_DIR/Snipshot/AIProvider.swift" \
    "$PROJECT_DIR/Tests/AIProviderTests.swift" \
    -o "$TEST_BINARY"
"$TEST_BINARY"
