#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/source-current}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCES=()
for path in "$SOURCE"/app/*.swift; do
  if [ "$(basename "$path")" != ReplyzenApp.swift ]; then SOURCES+=("$path"); fi
done
swiftc -DLOCALIZATION_TESTS -parse-as-library -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Security -framework ServiceManagement -framework Network -framework PDFKit \
  -framework Vision -framework NaturalLanguage -framework CoreText \
  "${SOURCES[@]}" "$ROOT/tests/WorkspaceUITests.swift" -o "$TMP/workspace-tests"
REPLYZEN_TEST_CATALOG="$SOURCE/app/Resources/Localization.json" "$TMP/workspace-tests" "$SOURCE/.ui-previews"
