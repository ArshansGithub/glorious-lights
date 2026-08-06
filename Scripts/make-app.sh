#!/bin/bash
#
# Builds "Glorious Lights.app" — a real, double-clickable macOS bundle around
# the SwiftPM executable.
#
#   Scripts/make-app.sh [--zip]
#
# Output: build/Glorious Lights.app  (and build/Glorious-Lights-<version>.zip
# with --zip, for attaching to a release).
#
# The signature is ad-hoc (`-s -`). There is no paid Developer ID certificate
# for this project, so the bundle is signed but not notarised, and Gatekeeper
# will refuse a plain double-click on first run — see the README for the
# right-click → Open dance. Ad-hoc signing is still worth doing: without any
# signature at all the binary is killed outright on Apple silicon.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

APP_NAME="Glorious Lights"
BUNDLE_ID="com.glorious-lights.app"
EXECUTABLE="GMMKLightsApp"
APP="$BUILD/$APP_NAME.app"

echo "==> Glorious Lights $VERSION"

echo "==> Building release binary"
swift build -c release --product "$EXECUTABLE"
BINARY="$(swift build -c release --product "$EXECUTABLE" --show-bin-path)/$EXECUTABLE"
[ -x "$BINARY" ] || { echo "no executable at $BINARY" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"

echo "==> Rendering the icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

# LSUIElement keeps the app out of the Dock and the app switcher: it lives in
# the menu bar and has no windows of its own until the tuner is opened.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Glorious Lights listens to the microphone only while the audio visualizer is running, to turn what it hears into a spectrum on your keyboard. Audio is analysed in memory and never recorded, saved or sent anywhere.</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Glorious Lights uses Bluetooth to find and control LED strip controllers, so their colour can follow the same look as your keyboard and mouse. It connects only to the strip you choose and sends only lighting commands.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Glorious Lights taps the system audio mix only while the audio visualizer is running, to turn what is playing into a spectrum on your keyboard. Audio is analysed in memory and never recorded, saved or sent anywhere.</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT licensed. https://github.com/ArshansGithub/glorious-lights</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

# --deep is deprecated for signing but harmless here and asked for explicitly;
# this bundle has no nested code for it to reach anyway.
# Signing identity. Ad-hoc ("-") signatures change with every build, and macOS
# ties privacy grants (Input Monitoring, audio capture) to the signature — so an
# ad-hoc rebuild silently invalidates permissions the user already granted, while
# still showing them as enabled in System Settings. A real certificate keeps the
# identity stable across rebuilds.
#
# Override with GL_SIGN_IDENTITY; otherwise prefer, in order: a Developer ID
# (the only one strangers' Macs accept without the Gatekeeper dance), any valid
# Apple Development certificate, then ad-hoc.
if [ -z "${GL_SIGN_IDENTITY:-}" ]; then
    GL_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | grep -v CSSMERR | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi
if [ -z "${GL_SIGN_IDENTITY:-}" ]; then
    GL_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' | grep -v CSSMERR | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi
GL_SIGN_IDENTITY="${GL_SIGN_IDENTITY:--}"
echo "==> Signing as: $GL_SIGN_IDENTITY"
codesign --force --deep --sign "$GL_SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> Bundle:"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

if [ "${1:-}" = "--zip" ]; then
	ZIP="$BUILD/Glorious-Lights-$VERSION.zip"
	rm -f "$ZIP"
	# ditto rather than `zip`: it preserves the resource forks and the code
	# signature, which a plain zip mangles.
	ditto -c -k --keepParent "$APP" "$ZIP"
	echo "==> Zip: $ZIP"
	shasum -a 256 "$ZIP" | sed 's/^/    /'
fi

echo "==> Done: $APP"
