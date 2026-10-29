#!/bin/bash
# Builds build/MacDownloader.app (release, ad-hoc signed) and build/mdl (command line).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native 2>&1 | grep -v "has been deprecated" || true
BIN="$(swift build -c release --build-system native --show-bin-path 2>/dev/null | tail -1)"
test -x "$BIN/MacDownloader" || { echo "build failed"; exit 1; }

APP=build/MacDownloader.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacDownloader" "$APP/Contents/MacOS/MacDownloader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/mdl" build/mdl
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep -s - "$APP"
codesign --force -s - build/mdl
codesign --verify --deep "$APP"

# Register the URL scheme with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Built $PWD/$APP"
