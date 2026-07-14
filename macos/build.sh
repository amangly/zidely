#!/bin/sh
# Builds Zide.app: the real macOS shell. Swift sources compile with
# whatever toolchain `swiftc` resolves to (Command Line Tools is fine);
# GhosttyKit.xcframework must exist first (scripts/build-ghosttykit.sh,
# which needs a full Xcode for Metal + xcframework packaging only).
set -eu
cd "$(dirname "$0")"

XC=../vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64
if [ ! -d "$XC" ]; then
    echo "GhosttyKit not built yet; running scripts/build-ghosttykit.sh" >&2
    ../scripts/build-ghosttykit.sh
fi

APP=out/Zide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -o "$APP/Contents/MacOS/zide-shell" \
    Sources/*.swift \
    -I "$XC/Headers" \
    "$XC/libghostty-fat.a" \
    -framework AppKit \
    -framework WebKit \
    -framework Metal \
    -framework MetalKit \
    -framework CoreText \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework IOSurface \
    -framework QuartzCore \
    -framework Carbon \
    -framework UniformTypeIdentifiers \
    -framework UserNotifications \
    -framework Security \
    -lc++ -lz -lsqlite3

cp Info.plist "$APP/Contents/"
cp ../assets/macos/zide.icns "$APP/Contents/Resources/"
cp -R ../vendor/ghostty/zig-out/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R ../vendor/ghostty/zig-out/share/terminfo "$APP/Contents/Resources/terminfo"

# Passkey/Touch-ID sign-in in the browser needs the web-browser
# public-key-credential entitlement, which only takes effect when the
# app is signed with a real Apple Team ID + granted provisioning
# profile. Set CODESIGN_IDENTITY (e.g. "Developer ID Application: You
# (TEAMID)") to sign with the entitlements; otherwise the app is
# ad-hoc signed and passkeys stay unavailable (everything else works).
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime \
        --entitlements zide.entitlements \
        --sign "$CODESIGN_IDENTITY" "$APP"
    echo "signed $APP with $CODESIGN_IDENTITY (entitlements applied)"
fi

echo "built $APP"
