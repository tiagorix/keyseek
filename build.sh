#!/bin/zsh
# Development build: build/Keyseek.app for this Mac, with the Command Line Tools (no Xcode project needed).
# For a distributable build see release.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Keyseek.app

# Quit the running copy, and drop its Accessibility grant: the grant is tied to the old build's
# signature, so macOS shows it as enabled while refusing the new build. The next launch asks again.
pkill -x Keyseek 2>/dev/null || true
tccutil reset Accessibility com.tiago.keyseek >/dev/null 2>&1 || echo "note: could not reset the Accessibility grant"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 ${=SWIFT_EXTRA:-} Sources/*.swift -o "$APP/Contents/MacOS/Keyseek" \
  -framework AppKit -framework Carbon

cp Resources/*.txt "$APP/Contents/Resources/"

# The app draws its own icon and writes the .icns itself.
"$APP/Contents/MacOS/Keyseek" --make-icon "$APP/Contents/Resources/Keyseek.icns" 2>/dev/null \
  || echo "note: could not build the app icon"

cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signing changes identity on every build, which makes macOS forget the Accessibility grant.
# Set CODESIGN_IDENTITY to a certificate name from `security find-identity -v -p codesigning` to keep it.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
