#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/source-current}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library -framework AppKit -framework SwiftUI \
  "$SOURCE/app/FloatingPanelController.swift" \
  "$SOURCE/app/OutlookToolbarButtonController.swift" \
  "$ROOT/tests/WindowPositionTestDoubles.swift" \
  "$ROOT/tests/WindowPositionBehaviorTests.swift" -o "$TMP/window-position-tests"
"$TMP/window-position-tests"
