#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/source-current}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export REPLYZEN_TEST_CATALOG="$SOURCE/app/Resources/Localization.json"

python3 "$ROOT/tests/test_localization_catalog.py" "$SOURCE"

swiftc -DLOCALIZATION_TESTS -parse-as-library -framework AppKit -framework SwiftUI \
 "$SOURCE/app/LocalizationCore.swift" "$SOURCE/app/AppLocalization.swift" \
 "$ROOT/tests/LocalizationTests.swift" -o "$TMP/localization-tests"
"$TMP/localization-tests"

swiftc -parse-as-library -framework NaturalLanguage \
 "$SOURCE/app/MailLanguageDetector.swift" "$SOURCE/app/OutlookReplyControlMatcher.swift" \
 "$ROOT/tests/ReplyBehaviorTests.swift" -o "$TMP/reply-behavior-tests"
"$TMP/reply-behavior-tests"

# The complete UI, including the external WYSIWYG package, is compiled in the
# following SwiftPM release-build step. Keeping these tests dependency-free
# makes localization and language detection fast and deterministic.
