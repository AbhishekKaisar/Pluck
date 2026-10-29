#!/bin/bash
# Runs the unit tests. The command line tools keep swift-testing outside the default search
# paths, and the default SwiftPM build system fails without Xcode, hence the flags.
set -euo pipefail
cd "$(dirname "$0")"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test --build-system native \
  -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
