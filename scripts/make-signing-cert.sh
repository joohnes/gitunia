#!/usr/bin/env bash
# One-time setup (run by hand, once): creates the self-signed "Gitunia Self-Signed" code-signing
# certificate, imports it into your login keychain, writes its SHA-1 to
# packaging/signing-certificate.txt (commit that file), and prints the two GitHub secrets.
# Refuses to run again while that file exists: a new certificate means every user's macOS forgets
# Gitunia's folder access once more, and the in-app updater refuses builds from another certificate.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=packaging/signing-certificate.txt
if [[ -e "$OUT" ]]; then
  echo "$OUT already exists — the certificate was created before. Delete the file only to rotate it on purpose." >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Gitunia Self-Signed
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
PASS="$(openssl rand -base64 24)"
# -legacy: `security import` can't read OpenSSL 3's default PKCS#12 encryption; macOS's LibreSSL has no such flag.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
SHA="$(openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
echo "$SHA" > "$OUT"
echo
echo "Wrote $OUT ($SHA) — commit it."
echo "Add these as GitHub → Settings → Secrets and variables → Actions, then clear this terminal:"
echo
echo "SIGNING_CERT_PASSWORD:"
echo "$PASS"
echo
echo "SIGNING_CERT_P12:"
base64 -i "$TMP/cert.p12"
