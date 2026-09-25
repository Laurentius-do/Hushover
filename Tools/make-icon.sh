#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE=".build"
mkdir -p "$CACHE"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path 2>/dev/null)"

swiftc -O -sdk "$SDK" -module-cache-path "$CACHE/module-cache" Tools/make-icon.swift -o "$CACHE/make-icon"
"$CACHE/make-icon" Resources/AppIcon.icns Resources/AppIcon-preview.png
echo "Done: Resources/AppIcon.icns"
