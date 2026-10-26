#!/bin/sh
# Build and verify before replacing public artifacts. Credentials stay in Keychain.
set -eu
cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' release.json)"
NOTARIZED="$(node -p 'require("./release.json").notarized === true')"
OUT="../../public/downloads"
SUFFIX=""
if [ "$NOTARIZED" = true ]; then
  if [ -z "${SIGN_IDENTITY:-}" ] || [ -z "${NOTARY_PROFILE:-}" ] || [ "$SIGN_IDENTITY" = - ]; then
    echo "This release requires SIGN_IDENTITY (Developer ID Application) and NOTARY_PROFILE (existing Keychain profile)." >&2
    exit 1
  fi
  SUFFIX="-notarized"
fi
ZIP="DerpMeter-${VERSION}-beta-macOS${SUFFIX}.zip"
UNIVERSAL=1 ./scripts/bundle.sh
if [ "$NOTARIZED" = true ]; then
  SUBMISSION="$(mktemp -d "${TMPDIR:-/tmp}/derpmeter-notary.XXXXXX")"
  trap 'rm -rf "$SUBMISSION"' EXIT HUP INT TERM
  ditto -c -k --sequesterRsrc --keepParent build/DerpMeter.app "$SUBMISSION/app.zip"
  xcrun notarytool submit "$SUBMISSION/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/DerpMeter.app
  xcrun stapler validate build/DerpMeter.app
  spctl --assess --type execute --verbose=2 build/DerpMeter.app
fi
codesign --verify --deep --strict build/DerpMeter.app
ditto -c -k --sequesterRsrc --keepParent build/DerpMeter.app "build/$ZIP"
rm -f "$OUT"/DerpMeter-*-macOS.zip "$OUT"/DerpMeter-*-macOS-notarized.zip
cp "build/$ZIP" "$OUT/$ZIP"
echo "Packed public/downloads/$ZIP ($(du -h "$OUT/$ZIP" | cut -f1))"
