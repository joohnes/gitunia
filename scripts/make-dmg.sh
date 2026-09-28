#!/usr/bin/env bash
# Builds the app (scripts/build-app.sh) and packs it into a compressed DMG with an /Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

# Same formula as release.yml: <VERSION file>.<commit count>, e.g. 0.2.143.
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION).$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
export VERSION
scripts/build-app.sh

STAGE=dist/dmg-root
DMG="dist/Gitunia-${VERSION}.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R dist/Gitunia.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Gitunia" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
