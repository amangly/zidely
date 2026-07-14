#!/bin/sh
# Build a distributable drag-to-Applications DMG of Zide.app.
# Produces macos/out/Zide-<version>.dmg.
#
# Note: for a DMG others can open without Gatekeeper warnings, sign with
# a Developer ID and notarize:
#   CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" macos/make-dmg.sh
#   xcrun notarytool submit macos/out/Zide-<v>.dmg --keychain-profile <p> --wait
#   xcrun stapler staple macos/out/Zide-<v>.dmg
set -eu
cd "$(dirname "$0")/.."

echo "==> Building the zide core (zig build)"
zig build
echo "==> Building Zide.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}" ./macos/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" macos/Info.plist 2>/dev/null || echo "0.0.0")
DMG="macos/out/Zide-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R macos/out/Zide.app "$STAGE/Zide.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "==> Creating $DMG"
hdiutil create \
    -volname "Zide $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo ""
echo "built $DMG"
echo "Users drag Zide.app onto the Applications shortcut to install."
