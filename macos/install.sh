#!/bin/sh
# Build Zide and install it into /Applications as a self-contained app.
# Everything the app needs (the `zide` daemon binary, libghostty
# resources, terminfo) is bundled — no dev tree or ZIDE_BIN required
# afterward.
#
# Usage:
#   macos/install.sh                 # build + install to /Applications
#   PREFIX=~/Applications macos/install.sh   # install elsewhere
#   CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" macos/install.sh
set -eu
cd "$(dirname "$0")/.."

DEST="${PREFIX:-/Applications}"
APP="$DEST/Zide.app"

echo "==> Building the zide core (zig build)"
zig build

echo "==> Building Zide.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}" ./macos/build.sh

echo "==> Stopping any running Zide + daemon"
./zig-out/bin/zide shutdown 2>/dev/null || true
# Only the installed copy — never a dev instance running from the repo.
pkill -f "$APP/Contents/MacOS/zide-shell" 2>/dev/null || true
sleep 1

echo "==> Installing to $APP"
mkdir -p "$DEST"
rm -rf "$APP"
cp -R macos/out/Zide.app "$APP"

echo ""
echo "Installed $APP"
echo "Launch it from Spotlight/Launchpad, or:  open \"$APP\""
