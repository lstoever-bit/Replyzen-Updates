#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/app"
WORK="$ROOT/.build-ci"
APP="$WORK/Replyzen.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Info.plist")"
PACKAGE_NAME="Replyzen-update-${APP_VERSION%.0}.zip"
UPDATE_ZIP="$ROOT/$PACKAGE_NAME"
UPDATE_JSON="$ROOT/update.json"
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

rm -rf "$WORK"
rm -f "$UPDATE_ZIP" "$UPDATE_JSON"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp -R "$SRC/Resources/." "$APP/Contents/Resources/"

# Render each unique icon resolution once, then reuse it for Retina variants.
ICONSET="$WORK/Replyzen.iconset"
mkdir -p "$ICONSET" "$WORK/icon-sizes"
for pixels in 16 32 64 128 256 512; do
  /usr/bin/sips -z "$pixels" "$pixels" "$SRC/Resources/ReplyzenLogo.png" \
    --out "$WORK/icon-sizes/$pixels.png" >/dev/null
done
for points in 16 32 128 256 512; do
  cp "$WORK/icon-sizes/$points.png" "$ICONSET/icon_${points}x${points}.png"
  retina=$((points * 2))
  if [ "$retina" -eq 1024 ]; then
    cp "$SRC/Resources/ReplyzenLogo.png" "$ICONSET/icon_${points}x${points}@2x.png"
  else
    cp "$WORK/icon-sizes/$retina.png" "$ICONSET/icon_${points}x${points}@2x.png"
  fi
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Replyzen.icns"

SOURCES=("$SRC"/*.swift)
"$SWIFTC" -O -whole-module-optimization -parse-as-library -sdk "$SDK" -target "$TARGET" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Security -framework ServiceManagement -framework Network \
  -framework PDFKit -framework Vision -framework NaturalLanguage \
  "${SOURCES[@]}" -o "$APP/Contents/MacOS/Replyzen"

/usr/bin/xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATE_ZIP"

# JSON serialization keeps release-note text properly escaped.
python3 - "$ROOT" "$APP_VERSION" "$APP_BUILD" "$PACKAGE_NAME" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root, version, build, package = sys.argv[1:]
root = Path(root)
manifest = {
    "version": version,
    "build": int(build),
    "download_url": package,
    "sha256": hashlib.sha256((root / package).read_bytes()).hexdigest(),
    "notes": (root / "Release-notes.txt").read_text(encoding="utf-8").strip(),
}
(root / "update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
printf 'Built %s (build %s): %s\n' "$APP_VERSION" "$APP_BUILD" "$UPDATE_ZIP"
