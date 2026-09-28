#!/usr/bin/env bash
# Signs an app bundle. With packaging/signing-certificate.txt (the SHA-1 written by
# scripts/make-signing-cert.sh) and that certificate in a keychain on the search list, it signs with
# it: macOS ties folder-access grants to the designated requirement, which is then
# `identifier "dev.gitunia.app" and certificate leaf = H"<sha1>"` — the same for every build, so
# updates keep the grants. Otherwise ad-hoc, whose requirement is the build's own hash: every update
# re-prompts. REQUIRE_SIGNING=1 (release builds) turns "certificate file present but certificate
# missing" into an error instead of an ad-hoc fallback.
set -euo pipefail
APP="$1"
CERT_FILE="${SIGNING_CERT_FILE:-$(cd "$(dirname "$0")/.." && pwd)/packaging/signing-certificate.txt}"
CERT="$({ tr -d '[:space:]' < "$CERT_FILE"; } 2>/dev/null || true)"

if [[ -n "$CERT" ]] && security find-identity -p codesigning | grep -q "$CERT"; then
  codesign --force --deep --sign "$CERT" "$APP"
  # Guards against a secret holding a different certificate than the committed file.
  if ! codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$CERT\""; then
    echo "error: $APP's designated requirement doesn't name certificate $CERT" >&2
    exit 1
  fi
  echo "Signed $APP with certificate $CERT"
elif [[ -n "$CERT" && "${REQUIRE_SIGNING:-0}" == 1 ]]; then
  echo "error: $CERT_FILE names certificate $CERT, but it isn't in any keychain on the search list" >&2
  exit 1
else
  if [[ -n "$CERT" ]]; then
    echo "warning: signing certificate $CERT not found — signing ad-hoc (macOS will ask for folder access again after installing this build)" >&2
  fi
  codesign --force --deep --sign - "$APP"
fi
