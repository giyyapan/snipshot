#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-pin-focus-fallback-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    "$PROJECT_DIR/Snipshot/PinFocusFallback.swift" \
    "$PROJECT_DIR/Tests/PinFocusFallbackTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
