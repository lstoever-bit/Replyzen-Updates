#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p evidence
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library rewrite/Core/NativeMail.swift rewrite/Tests/NativeMailTests.swift -o "$TMP/core"
"$TMP/core" | tee evidence/core-tests.txt
swiftc -parse-as-library -framework AppKit rewrite/Core/NativeMail.swift rewrite/Mac/NativeOutlookBridge.swift rewrite/Tests/NativeBridgeTests.swift -o "$TMP/bridge"
"$TMP/bridge" | tee evidence/bridge-tests.txt
APP="$(find "$RUNNER_TEMP/outlook-expanded" -name 'Microsoft Outlook.app' -type d -print -quit)"
test -n "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
osacompile -o "$TMP/Outlook.scpt" rewrite/Scripts/Outlook.applescript
echo 'PASS: static native script compiled against official Outlook dictionary (not an authenticated mailbox test)' | tee evidence/script-compile.txt
python3 rewrite/assemble.py
swift build --package-path .native-build -c release --arch arm64 --product Replyzen > evidence/macos-build.txt 2>&1
BIN="$(swift build --package-path .native-build -c release --arch arm64 --show-bin-path)"
BUNDLE="$TMP/ReplyZen Native Preview.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/Replyzen" "$BUNDLE/Contents/MacOS/Replyzen"
cp .native-build/app/Info.plist "$BUNDLE/Contents/Info.plist"
cp -R .native-build/app/Resources/. "$BUNDLE/Contents/Resources/"
# Ad-hoc signature is ONLY for CI integrity. It is NOT a user release.
codesign --force --sign - --options runtime --entitlements rewrite/entitlements.plist "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
security find-identity -v -p codesigning > "$TMP/identities"
if grep -q 'Developer ID Application:' "$TMP/identities"; then
  echo 'Developer ID identity available; release still requires notarization and live acceptance.' > evidence/release-gate.txt
else
  echo 'BLOCKED: no Developer ID Application identity on this runner. No distributable app published.' > evidence/release-gate.txt
fi
python3 - <<'PY'
from pathlib import Path
import json
s=Path('.native-build/app/AppDelegate.swift').read_text()
p=s[s.index('    private func insertReply()'):s.index('    private func copyMailToPasteboard(')]
assert 'NativeMailTransaction' in p
assert not any(x in p for x in ['sendCommand','focusCompose','activeSnapshot','OutlookReplyInsertion'])
script=Path('rewrite/Scripts/Outlook.applescript').read_text()
assert 'do shell script' not in script
assert not any(line.strip().startswith('send ') for line in script.splitlines())
assert 'set content of d to item 8 of args' in script
assert 'checkedSource(args)' in script
assert 'NSAppleEventsUsageDescription' in Path('.native-build/app/Info.plist').read_text()
Path('evidence/acceptance.json').write_text(json.dumps({'native_core':'implemented','legacy_focus_transport':'not compiled in preview','actual_outlook_dictionary':'script compiled','live_authenticated_outlook_test':False,'notarized':False,'production_updated':False},indent=2))
PY
echo 'PASS: full preview application compiled and integrity-checked; production unchanged.' | tee evidence/build-summary.txt
