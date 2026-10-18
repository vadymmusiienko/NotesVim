#!/bin/bash
# Creates a self-signed code signing identity in a dedicated keychain.
#
# macOS remembers the Accessibility permission per code signature. Ad-hoc signed builds get
# a new signature every time, so the permission silently stops working after each rebuild.
# Signing with a stable local identity keeps the permission across rebuilds.
set -euo pipefail

IDENTITY="NotesVim Local Signing"
KEYCHAIN="$HOME/Library/Keychains/notesvim-signing.keychain-db"
PASSWORD="notesvim"

if [[ -f "$KEYCHAIN" ]] && security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity already set up in $KEYCHAIN"
  exit 0
fi

WORK=$(mktemp -d)
trap 'command rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# The Keychain only imports PKCS#12 files using the older SHA1/3DES algorithms.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$WORK/identity.p12" -passout pass:"$PASSWORD" 2>/dev/null

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created signing identity \"$IDENTITY\" in $KEYCHAIN"
