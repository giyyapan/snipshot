#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-secure-input-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    "$PROJECT_DIR/Sources/SecureInputCore/SecureInputStatus.swift" \
    "$PROJECT_DIR/Tests/SecureInputStatusTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
