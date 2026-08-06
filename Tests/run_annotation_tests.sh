#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-annotation-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Cocoa \
    -framework Accelerate \
    "$PROJECT_DIR/Snipshot/Annotation.swift" \
    "$PROJECT_DIR/Snipshot/UIComponents.swift" \
    "$PROJECT_DIR/Tests/AnnotationTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
