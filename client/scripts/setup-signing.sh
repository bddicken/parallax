#!/usr/bin/env bash
# One-time setup: creates a self-signed "Parallax Local Signing" certificate
# in your login keychain and trusts it for code signing. build-app.sh then
# signs with it automatically.
#
# Why: without a real certificate the app is signed ad hoc, and macOS ties
# Camera/Microphone/Screen Recording grants to the exact binary, so every
# rebuild looks like a new app and permissions are asked for again. A stable
# certificate makes macOS recognize rebuilt copies as the same app.
#
# macOS will ask for your password to trust the certificate. To undo, delete
# "Parallax Local Signing" in Keychain Access.
set -euo pipefail

NAME="Parallax Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

allow_codesign() {
  # Without this, macOS asks "codesign wants to sign using key…" on every build.
  echo "Letting codesign use the key without asking each build (enter your login password)…"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KEYCHAIN" >/dev/null
}

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" is already set up."
  allow_codesign
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
       -out "$TMP/id.p12" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

allow_codesign
security find-identity -v -p codesigning | grep "$NAME"
echo "Done. Rebuild with scripts/build-app.sh, then grant Camera/Microphone/Screen Recording one last time."
