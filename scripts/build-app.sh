#!/usr/bin/env bash
# Builds dist/Gitunia.app from the Swift package (release), with icon and Info.plist, signed by scripts/sign-app.sh.
# UNIVERSAL=1 builds one binary for both Apple silicon and Intel (what the release workflow ships).
set -euo pipefail
cd "$(dirname "$0")/.."

# Same formula as release.yml: <VERSION file>.<commit count>, e.g. 0.2.143.
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION).$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
APP=dist/Gitunia.app
ICONSET=dist/Gitunia.iconset

if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Gitunia
else
  swift build -c release
  BIN=.build/release/Gitunia
fi

# Update-signing public key (scripts/sign-update.swift generate). Without it the build still
# works, but the app can't verify downloads and falls back to "open the release page".
UPDATE_PUBLIC_KEY="$(tr -d '[:space:]' < packaging/update-public-key.txt 2>/dev/null || true)"

rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Gitunia"

swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gitunia</string>
  <key>CFBundleDisplayName</key><string>Gitunia</string>
  <key>CFBundleIdentifier</key><string>dev.gitunia.app</string>
  <key>CFBundleExecutable</key><string>Gitunia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026</string>
  <key>GituniaUpdatePublicKey</key><string>${UPDATE_PUBLIC_KEY}</string>
</dict>
</plist>
PLIST

scripts/sign-app.sh "$APP"
echo "Built $APP (version $VERSION)"
