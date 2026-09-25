#!/bin/bash
# Compiles the pure logic (no audio, no UI) together with Tests/ and runs it.
set -euo pipefail
cd "$(dirname "$0")"

CACHE=".build"
mkdir -p "$CACHE"
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path 2>/dev/null)"

swiftc \
    -swift-version 6 \
    -target "$(uname -m)-apple-macos15.0" \
    -sdk "$SDK" \
    -module-cache-path "$CACHE/module-cache" \
    Sources/Hushover/Localization/Strings.swift \
    Sources/Hushover/Audio/Levels.swift \
    Sources/Hushover/Audio/ChannelMapping.swift \
    Sources/Hushover/Engine/Backoff.swift \
    Sources/Hushover/Engine/RuleEvaluator.swift \
    Sources/Hushover/Engine/Settings.swift \
    Sources/Hushover/Engine/TapManager.swift \
    Tests/main.swift \
    -o "$CACHE/tests"

"$CACHE/tests"
