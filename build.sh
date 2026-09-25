#!/bin/bash
# Builds Hushover.app into ./build (no Xcode needed, Command Line Tools suffice).
# Calls swiftc directly: a single module without dependencies doesn't need SwiftPM.
set -euo pipefail
cd "$(dirname "$0")"

# Caches stay inside the project (.build is git-ignored) instead of a shared, world-writable /tmp.
CACHE=".build"
APP="build/Hushover.app"
BIN="$APP/Contents/MacOS/Hushover"
SIGN_IDENTITY="${SIGN_IDENTITY:-Hushover Local Signing}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/hushover-signing.keychain-db}"

# With only the Command Line Tools installed, the macOS 27 SDK can't be used: its SwiftUI
# needs a macro plugin that ships with Xcode. Prefer the macOS 26 SDK when it's there.
if [[ -z "${SDK:-}" ]]; then
    CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
    if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$CLT_SDK" ]]; then
        SDK="$CLT_SDK"
    else
        SDK="$(xcrun --show-sdk-path 2>/dev/null)"
    fi
fi

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find Sources/Hushover -name '*.swift' -print0)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"

swiftc \
    -O \
    -parse-as-library \
    -swift-version 6 \
    -target "$(uname -m)-apple-macos15.0" \
    -sdk "$SDK" \
    -module-name Hushover \
    -module-cache-path "$CACHE/module-cache" \
    "${SOURCES[@]}" \
    -o "$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# A stable signing identity lets macOS remember permissions across builds (see Tools/create-signing-identity.sh).
# Its keychain stays locked except for the moment of signing. Ad-hoc signing works too,
# but then macOS asks for the permissions again after every build.
SIGN_ARGS=(--sign -)
if ! security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
    echo "Note: no signing identity \"$SIGN_IDENTITY\" in $SIGN_KEYCHAIN – signing ad hoc."
    echo "      Run ./Tools/create-signing-identity.sh once so macOS keeps Hushover's permissions across builds."
elif [[ ! -t 0 ]]; then
    echo "Note: no terminal to unlock the signing keychain – signing ad hoc."
else
    echo "Unlock the signing keychain:"
    security unlock-keychain "$SIGN_KEYCHAIN"
    # codesign only finds identities in keychains on the search list, so ours is added just for signing
    # and the original list is restored afterwards.
    SEARCH_LIST=()
    while IFS= read -r keychain; do
        SEARCH_LIST+=("$keychain")
    done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
    # Lock first, so the keychain is locked even if restoring the list fails. The ${…+…} form keeps
    # macOS' bash 3.2 from aborting on an empty array under `set -u`.
    trap 'security lock-keychain "$SIGN_KEYCHAIN"; security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}' EXIT
    security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} "$SIGN_KEYCHAIN"
    SIGN_ARGS=(--keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY")
fi

# Hardened runtime: blocks code injection (e.g. DYLD_INSERT_LIBRARIES), which would otherwise
# inherit Hushover's microphone and audio capture permissions.
codesign --force --options runtime --entitlements Resources/Hushover.entitlements "${SIGN_ARGS[@]}" "$APP"

echo "Done: $APP"
