#!/bin/bash
# Creates a stable self-signed code-signing identity for Murmur.
#
# WHY: ad-hoc signatures (`codesign -s -`) change on every rebuild, so macOS
# treats each build as a different app and quietly drops the Accessibility and
# Input Monitoring grants — the toggle still looks enabled, but the app is
# denied. Signing with a fixed identity keeps one identity across rebuilds, so
# you grant the permissions once and they stick.
#
# Run this ONCE:   ./setup-signing.sh
# Then rebuild:    ./build.sh --install
#
# macOS will ask for your password when the certificate is added to your login
# keychain. That prompt is expected — it's the keychain, not a network action.
set -euo pipefail

CERT_NAME="Murmur Self-Signed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Check for a *usable* identity, not merely a certificate. Importing the cert
# and marking it trusted are two separate steps, and the second one needs an
# interactive password — so a half-finished run leaves a cert that codesign
# cannot use. Testing only for the cert would then wrongly report success.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "==> '$CERT_NAME' is already set up and trusted for code signing."
  echo "    Nothing to do — ./build.sh --install will use it automatically."
  exit 0
fi

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "==> Found a '$CERT_NAME' certificate that is NOT trusted for code signing."
  echo "    (A previous run imported it but did not finish.) Removing it so this"
  echo "    run can start clean…"
  security delete-certificate -c "$CERT_NAME" >/dev/null 2>&1 \
    || { echo "!! Could not remove it. Open Keychain Access, delete '$CERT_NAME', and rerun."; exit 1; }
  echo "    removed."
fi

echo "==> Generating a self-signed code-signing certificate…"
cat > "$WORK/ext.cnf" <<'EXT'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3

[ dn ]
CN = Murmur Self-Signed

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EXT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/ext.cnf" 2>/dev/null

openssl pkcs12 -export -out "$WORK/id.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:murmur 2>/dev/null

echo "==> Importing into your login keychain (macOS will ask for your password)…"
security import "$WORK/id.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P murmur -T /usr/bin/codesign -A

echo "==> Marking it trusted for code signing…"
# -r trustRoot on the login keychain; this is what makes codesign accept it.
security add-trusted-cert \
  -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "==> Success. Identity available:"
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  echo
  echo "Next:"
  echo "  1. ./build.sh --install"
  echo "  2. Grant Accessibility + Input Monitoring to Murmur ONE more time"
  echo "  3. Future rebuilds keep those grants."
else
  echo "!! The identity was not registered for code signing."
  echo "   Murmur will keep working with ad-hoc signing; you'll just have to"
  echo "   re-grant permissions after each rebuild. To retry, open Keychain"
  echo "   Access, find '$CERT_NAME', and set 'Code Signing' to 'Always Trust'."
  exit 1
fi
