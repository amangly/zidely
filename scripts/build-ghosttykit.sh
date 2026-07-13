#!/bin/sh
# Builds GhosttyKit.xcframework from the pinned ghostty fork, for the
# macOS shell to link against. Output: vendor/ghostty/macos/GhosttyKit.xcframework
#
# The toolchain split matters (see ZIDE.md gotchas):
#   - zig compiles with the DEFAULT developer dir (Command Line Tools).
#     Zig 0.15.2 cannot link under the macOS 26+ SDKs a new Xcode
#     activates, so DEVELOPER_DIR must NOT be set globally.
#   - the Metal compiler only exists in full Xcode; the fork's
#     GHOSTTY_METAL_DEVELOPER_DIR routes just metal/metallib there.
#   - xcodebuild -create-xcframework also needs full Xcode; a PATH shim
#     routes only the bare `xcodebuild` ghostty invokes.
#
# XCODE_APP overrides the Xcode used (default: /Applications/Xcode-beta.app).
set -eu

# Must match build.zig.zon's ghostty pin (branch zide-v1.3.1).
PIN=7cda66a55ff1e812aa54577f5d12381f1943d475
XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"

cd "$(dirname "$0")/.."
mkdir -p vendor

if [ ! -d vendor/ghostty ]; then
    git clone https://github.com/amangly/ghostty.git vendor/ghostty
fi
git -C vendor/ghostty fetch -q origin zide-v1.3.1
git -C vendor/ghostty checkout -q "$PIN"

SHIM_DIR="$(pwd)/vendor/.xcshim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/xcodebuild" <<EOF
#!/bin/sh
exec env DEVELOPER_DIR="$XCODE_APP" /usr/bin/xcodebuild "\$@"
EOF
chmod +x "$SHIM_DIR/xcodebuild"

cd vendor/ghostty
GHOSTTY_METAL_DEVELOPER_DIR="$XCODE_APP" PATH="$SHIM_DIR:$PATH" \
    zig build -Demit-xcframework=true -Demit-macos-app=false \
    -Dxcframework-target=native -Dversion-string=1.3.1 "$@"

echo "built: vendor/ghostty/macos/GhosttyKit.xcframework"
