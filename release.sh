#!/bin/zsh
# Distributable build: a universal (Apple silicon + Intel) Keyseek.app, zipped for a GitHub release.
#
#   ./release.sh 1.0.0
#
# Optional environment:
#   DEVELOPER_ID    "Developer ID Application: Name (TEAMID)" - sign for distribution instead of ad-hoc.
#   NOTARY_PROFILE  a keychain profile saved with `xcrun notarytool store-credentials` - notarize and staple.
# Without them the app is ad-hoc signed: it runs, but macOS asks each user to approve it on first launch.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>, for example ./release.sh 1.0.0}
OUT=build/release
APP=$OUT/Keyseek.app
ZIP=$OUT/Keyseek-$VERSION.zip

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" ${=SWIFT_EXTRA:-} Sources/*.swift \
    -o "$OUT/Keyseek-$ARCH" -framework AppKit -framework Carbon
done
lipo -create "$OUT/Keyseek-arm64" "$OUT/Keyseek-x86_64" -output "$APP/Contents/MacOS/Keyseek"
rm "$OUT/Keyseek-arm64" "$OUT/Keyseek-x86_64"

cp Resources/*.txt "$APP/Contents/Resources/"
"$APP/Contents/MacOS/Keyseek" --make-icon "$APP/Contents/Resources/Keyseek.icns" 2>/dev/null

cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Built $ZIP"
shasum -a 256 "$ZIP"
