#!/bin/bash
# Packs a built app into build/release: the DMG, the app zip, the extension zip, SHA256SUMS.txt
# and NOTES.md (docs/release-notes.md with the checksums added). Run ./build.sh first.
# Uploads nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
EXT_VERSION="$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["version"])')"
[ "$VERSION" = "$EXT_VERSION" ] || { echo "app $VERSION and extension $EXT_VERSION differ"; exit 1; }
APP=build/Pluck.app
OUT=build/release
test -d "$APP" || { echo "run ./build.sh first"; exit 1; }
codesign --verify --deep "$APP"

rm -rf "$OUT"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# DMG: the app next to an Applications shortcut, so it can be dragged straight across.
mkdir "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/Pluck.app"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname "Pluck $VERSION" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -ov "$OUT/Pluck-$VERSION.dmg"

ditto -c -k --keepParent "$APP" "$OUT/Pluck-$VERSION.zip"

# Extension: the folder as it is loaded unpacked, without macOS metadata.
ditto "extension" "$STAGE/Pluck-Extension"
find "$STAGE/Pluck-Extension" -name .DS_Store -delete
(cd "$STAGE" && zip -qrX "$OLDPWD/$OUT/Pluck-Extension-$VERSION.zip" Pluck-Extension)

(cd "$OUT" && shasum -a 256 "Pluck-$VERSION.dmg" "Pluck-$VERSION.zip" "Pluck-Extension-$VERSION.zip" > SHA256SUMS.txt)

{
  sed "s/{{VERSION}}/$VERSION/g" docs/release-notes.md
  echo
  echo '```'
  cat "$OUT/SHA256SUMS.txt"
  echo '```'
} > "$OUT/NOTES.md"

ls -l "$OUT"
cat "$OUT/SHA256SUMS.txt"
