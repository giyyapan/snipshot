#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BINARY="$(mktemp -t snipshot-stitching-tests)"
ANALYSIS_TEST_BINARY="$(mktemp -t snipshot-stitching-analysis-tests)"
trap 'rm -f "$TEST_BINARY" "$ANALYSIS_TEST_BINARY"' EXIT

swiftc \
    -swift-version 5 \
    "$PROJECT_DIR/Snipshot/StitchingDecision.swift" \
    "$PROJECT_DIR/Tests/StitchingDecisionTests.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"

swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Cocoa \
    -framework Vision \
    "$PROJECT_DIR/Snipshot/StitchingDecision.swift" \
    "$PROJECT_DIR/Snipshot/StitchingManager.swift" \
    "$PROJECT_DIR/Tests/StitchingCompileSupport.swift" \
    "$PROJECT_DIR/Tests/StitchingImageAnalysisTests.swift" \
    -o "$ANALYSIS_TEST_BINARY"

"$ANALYSIS_TEST_BINARY"
