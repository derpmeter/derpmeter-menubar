#!/bin/sh
# Build DerpMeter.app. Ad-hoc signed by default (local use only).
# For distribution: SIGN_IDENTITY="Developer ID Application: …" ./scripts/bundle.sh
# then notarize (see README). Never commit certificates or credentials.
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' release.json)}"
APP="build/DerpMeter.app"
# UNIVERSAL=1 builds one binary for Apple Silicon and Intel (downloads).
if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --product DerpMeterCompanion --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/DerpMeterCompanion"
else
  swift build -c release --product DerpMeterCompanion
  BIN=".build/release/DerpMeterCompanion"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Resources/. "$APP/Contents/Resources/"
ICONSET="build/DerpMeter.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/DerpMeter.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/DerpMeter.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/DerpMeter.icns"
cp "$BIN" "$APP/Contents/MacOS/DerpMeterCompanion"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.derpmeter.companion</string>
  <key>CFBundleName</key><string>DerpMeter</string>
  <key>CFBundleDisplayName</key><string>DerpMeter</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleIconFile</key><string>DerpMeter</string>
  <key>CFBundleExecutable</key><string>DerpMeterCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with ${SIGN_IDENTITY:-ad-hoc identity})"
