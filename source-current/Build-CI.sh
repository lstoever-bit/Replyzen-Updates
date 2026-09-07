#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/app"
WORK="$ROOT/.build-ci"
APP="$WORK/Replyzen.app"
UPDATE_ZIP="$ROOT/Replyzen-update-1.30.zip"
UPDATE_JSON="$ROOT/update.json"
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos13.0"

rm -rf "$WORK" "$UPDATE_ZIP" "$UPDATE_JSON"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp -R "$SRC/Resources/." "$APP/Contents/Resources/"

ICONSET="$WORK/Replyzen.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
/usr/bin/sips -z 16 16 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$SRC/Resources/ReplyzenLogo.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$SRC/Resources/ReplyzenLogo.png" "$ICONSET/icon_512x512@2x.png"
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Replyzen.icns"

SOURCES=("$SRC"/*.swift)

"$SWIFTC" -O -parse-as-library -sdk "$SDK" -target "$TARGET" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices \
  -framework Security -framework ServiceManagement -framework Network \
  -framework PDFKit -framework Vision -framework NaturalLanguage \
  "${SOURCES[@]}" \
  -o "$APP/Contents/MacOS/Replyzen"

/usr/bin/xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPDATE_ZIP"

UPDATE_SHA="$(/usr/bin/shasum -a 256 "$UPDATE_ZIP" | /usr/bin/awk '{print $1}')"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

cat > "$UPDATE_JSON" <<EOF
{
  "version": "$APP_VERSION",
  "build": $APP_BUILD,
  "download_url": "Replyzen-update-1.30.zip",
  "sha256": "$UPDATE_SHA",
  "notes": "Replyzen 1.30: Reply verwendet immer Reply All. Optionaler Reminder in der Mail Ansicht mit Mo bis So und Uhrzeit 0:00 bis 24:00; bei Aktivierung wird automatisch z. B. wed12:00@fut.io in BCC gesetzt. Das macOS Menüleisten Icon wird aus dem Replyzen App Logo als transparente Template Maske erzeugt, damit kein weißes Quadrat mehr erscheint."
}
EOF
