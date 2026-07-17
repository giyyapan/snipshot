#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-pin-recovery-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    "$PROJECT_DIR/Snipshot/PinRecoveryState.swift" \
    "$PROJECT_DIR/Tests/PinRecoveryStateTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
