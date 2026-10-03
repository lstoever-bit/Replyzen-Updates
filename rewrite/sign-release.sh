#!/bin/bash
# Release gate. No gatekeeper/quarantine bypass, no unsigned fallback.
set -euo pipefail
APP="${1:?Usage: sign-release.sh /path/to/app.app}"
: "${DEVELOPER_ID_APPLICATION:?Developer ID Application identity required}"
: "${NOTARY_PROFILE:?Notarytool keychain profile required}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null
codesign --force --options runtime --timestamp --entitlements "$ROOT/entitlements.plist" --sign "$DEVELOPER_ID_APPLICATION" "$APP"
codesign --verify --deep --strict "$APP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/submit.zip"
xcrun notarytool submit "$TMP/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$TMP/result.json"
python3 - "$TMP/result.json" <<'PY'
import json,sys
if json.load(open(sys.argv[1])).get('status') != 'Accepted':
    raise SystemExit('Notarization not accepted; release blocked')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
echo 'Signature, notarization, stapling and Gatekeeper assessment succeeded.'
