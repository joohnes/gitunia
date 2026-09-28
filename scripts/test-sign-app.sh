#!/usr/bin/env bash
# Runnable check for scripts/sign-app.sh against dummy bundles, in a throwaway keychain that is put on
# the user search list only for the duration and then removed (the original list is restored on exit).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
ORIG_KEYCHAINS=()
while IFS= read -r k; do ORIG_KEYCHAINS+=("$(echo "$k" | tr -d ' "')"); done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"
  security delete-keychain "$TMP/test.keychain-db" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

make_bundle() {
  mkdir -p "$1/Contents/MacOS"
  cp /usr/bin/true "$1/Contents/MacOS/Gitunia"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.gitunia.app</string><key>CFBundleExecutable</key><string>Gitunia</string></dict></plist>' > "$1/Contents/Info.plist"
}
fail() { echo "FAIL: $*"; exit 1; }

# A throwaway "Gitunia Self-Signed" certificate in its own keychain.
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:pw 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout pass:pw
KC="$TMP/test.keychain-db"
security create-keychain -p kp "$KC"
security unlock-keychain -p kp "$KC"
security import "$TMP/cert.p12" -k "$KC" -P pw -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k kp "$KC" >/dev/null
security list-keychains -d user -s "$KC" "${ORIG_KEYCHAINS[@]}"
SHA="$(openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"

# 1. No certificate file: ad-hoc, even with REQUIRE_SIGNING (nothing set up yet).
make_bundle "$TMP/a.app"
SIGNING_CERT_FILE="$TMP/none.txt" REQUIRE_SIGNING=1 "$ROOT/scripts/sign-app.sh" "$TMP/a.app" || fail "no cert file should sign ad-hoc"
codesign -d -r- "$TMP/a.app" 2>&1 | grep -q "cdhash" || fail "expected ad-hoc DR"

# 2. Certificate file + certificate in keychain: pinned DR.
echo "$SHA" > "$TMP/cert.txt"
make_bundle "$TMP/b.app"
SIGNING_CERT_FILE="$TMP/cert.txt" REQUIRE_SIGNING=1 "$ROOT/scripts/sign-app.sh" "$TMP/b.app" || fail "should sign with certificate"
codesign -d -r- "$TMP/b.app" 2>&1 | grep -qi "certificate leaf = H\"$SHA\"" || fail "DR does not name the certificate"

# 3. Review focus 3: a certificate file naming a certificate that isn't available fails when required.
echo "0000000000000000000000000000000000000000" > "$TMP/wrong.txt"
make_bundle "$TMP/c.app"
if SIGNING_CERT_FILE="$TMP/wrong.txt" REQUIRE_SIGNING=1 "$ROOT/scripts/sign-app.sh" "$TMP/c.app" 2>/dev/null; then
  fail "missing certificate must fail when REQUIRE_SIGNING=1"
fi

# 4. Review focus 4: the same, without REQUIRE_SIGNING (PR builds): ad-hoc with a warning.
make_bundle "$TMP/d.app"
SIGNING_CERT_FILE="$TMP/wrong.txt" "$ROOT/scripts/sign-app.sh" "$TMP/d.app" 2>"$TMP/warn.txt" || fail "PR build must not fail"
grep -q "warning" "$TMP/warn.txt" || fail "expected a warning on stderr"
codesign -d -r- "$TMP/d.app" 2>&1 | grep -q "cdhash" || fail "expected ad-hoc DR"

echo "sign-app.sh: all checks passed"
