#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-pin-drag-update-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    "$PROJECT_DIR/Snipshot/PinDragUpdateState.swift" \
    "$PROJECT_DIR/Tests/PinDragUpdateStateTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
