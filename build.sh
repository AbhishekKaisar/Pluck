#!/bin/bash
# Builds build/Pluck.app (release, ad-hoc signed) and build/mdl (command line).
# Universal (Apple silicon and Intel) by default: each architecture is built on its own and joined
# with lipo, because the command line tools cannot build several architectures in one pass.
# ARCHS=arm64 ./build.sh builds for Apple silicon only, which is about twice as quick.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS=14.0
APP=build/Pluck.app
bins=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx$MIN_MACOS"
  swift build -c release --build-system native --triple "$triple" 2>&1 | grep -v "has been deprecated" || true
  bin="$(swift build -c release --build-system native --triple "$triple" --show-bin-path 2>/dev/null | tail -1)"
  test -x "$bin/Pluck" && test -x "$bin/mdl" || { echo "build failed for $arch"; exit 1; }
  bins+=("$bin")
done

rm -rf "$APP" build/mdl
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create $(for b in "${bins[@]}"; do echo "$b/Pluck"; done) -output "$APP/Contents/MacOS/Pluck"
lipo -create $(for b in "${bins[@]}"; do echo "$b/mdl"; done) -output build/mdl
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# In Resources, not MacOS: a script there is sealed by hash, so the signature survives any unzip tool.
cp Resources/pluck-host "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Drop local symbols: the app binary shrinks by more than half; no effect on speed.
strip -x "$APP/Contents/MacOS/Pluck" build/mdl

codesign --force --deep -s - "$APP"
codesign --force -s - build/mdl
codesign --verify --deep "$APP"

# Register the URL schemes with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/Pluck"))"
