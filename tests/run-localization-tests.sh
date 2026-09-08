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
# Reuse existing native UI checks in every language, without network access.
python3 - "$ROOT/tests/WorkspaceUITests.swift" "$TMP/LocalizedWorkspaceTests.swift" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
s=s.replace('        for dark in [false, true] {','        for language in InterfaceLanguage.allCases {\n        AppLocalization.shared.language = language\n        for dark in [false, true] {',1)
s=s.replace('        print("PASS: \\(count) native editor layouts', '        }\n        print("PASS: \\(count) native editor layouts',1)
s=s.replace('workspace-\\(dark', 'workspace-\\(language.rawValue)-\\(dark')
needle='                        precondition(textView.string == (preview ? state.reply : state.instruction))'
assert needle in s
s=s.replace(needle,needle+'\n                        let unchangedHTML = preview ? state.replyHTML : state.instructionHTML\n                        AppLocalization.shared.language = language == .spanish ? .english : .spanish\n                        RunLoop.main.run(until: Date().addingTimeInterval(0.03))\n                        precondition(textView.string == (preview ? state.reply : state.instruction))\n                        precondition((preview ? state.replyHTML : state.instructionHTML) == unchangedHTML)\n                        precondition(state.replyLanguage == .german)\n                        AppLocalization.shared.language = language')
Path(sys.argv[2]).write_text(s)
PY
SOURCES=()
for path in "$SOURCE"/app/*.swift; do
 if [ "$(basename "$path")" != ReplyzenApp.swift ]; then SOURCES+=("$path"); fi
done
swiftc -DLOCALIZATION_TESTS -parse-as-library -framework AppKit -framework SwiftUI -framework ApplicationServices \
 -framework Security -framework ServiceManagement -framework Network -framework PDFKit \
 -framework Vision -framework NaturalLanguage -framework CoreText \
 "${SOURCES[@]}" "$TMP/LocalizedWorkspaceTests.swift" -o "$TMP/workspace-tests"
"$TMP/workspace-tests" "$SOURCE/.ui-previews"
