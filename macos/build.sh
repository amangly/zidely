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
    -lc++ -lz

cp Info.plist "$APP/Contents/"
cp ../assets/macos/zide.icns "$APP/Contents/Resources/"
cp -R ../vendor/ghostty/zig-out/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R ../vendor/ghostty/zig-out/share/terminfo "$APP/Contents/Resources/terminfo"

echo "built $APP"
