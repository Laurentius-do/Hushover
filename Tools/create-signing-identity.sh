#!/bin/bash
# Creates a self-signed code signing identity "Hushover Local Signing" in its own keychain.
# Builds signed with it keep the same identity, so macOS remembers Hushover's permissions
# (microphone, system audio) across rebuilds. Only needed once per Mac.
#
# Why a separate, locked keychain: macOS grants permissions to "whatever is signed with this certificate
# as laurentius.Hushover". If the key sat in the always-unlocked login keychain, any program running
# as you could sign itself as Hushover and inherit those permissions. build.sh unlocks this keychain
# only for signing (it asks for the password) and locks it again right after.
set -euo pipefail

NAME="Hushover Local Signing"
KEYCHAIN="$HOME/Library/Keychains/hushover-signing.keychain-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() {
    security find-identity -p codesigning "$1" 2>/dev/null | grep -qF "\"$NAME\""
}

# Earlier versions of this script put the identity into the login keychain – remove it from there.
if has_identity "$LOGIN_KEYCHAIN"; then
    echo "Removing the old identity \"$NAME\" from the login keychain …"
    security delete-identity -c "$NAME" "$LOGIN_KEYCHAIN"
fi

if [[ -f "$KEYCHAIN" ]]; then
    if has_identity "$KEYCHAIN"; then
        echo "Signing keychain already exists: $KEYCHAIN"
        exit 0
    fi
    # Left over from an interrupted run: the keychain exists, but the identity never made it in.
    echo "Found an incomplete signing keychain – creating it again."
    security delete-keychain "$KEYCHAIN"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# macOS' own LibreSSL produces a PKCS#12 file the keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

echo "Choose a password for the signing keychain (every build will ask for it):"
security create-keychain "$KEYCHAIN"
# Lock automatically after 5 minutes and when the Mac sleeps, in case a build is interrupted.
security set-keychain-settings -l -u -t 300 "$KEYCHAIN"
# -T: codesign may use the private key once the keychain is unlocked.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
security lock-keychain "$KEYCHAIN"

echo "Created signing identity \"$NAME\" in $KEYCHAIN."
echo "On the first build macOS may ask whether codesign may use the key – choose \"Always Allow\"."
