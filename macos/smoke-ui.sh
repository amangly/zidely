#!/bin/sh
# Smoke-check the cmux-look macOS chrome builds and key types/menus exist.
set -eu
cd "$(dirname "$0")"

./build.sh

bin=out/Zide.app/Contents/MacOS/zide-shell
test -x "$bin"

strings "$bin" | grep -q 'RightSidebarView'
strings "$bin" | grep -q 'WorkspaceSwitcherView'
strings "$bin" | grep -q 'NotificationPanelView'
strings "$bin" | grep -q 'CommandPaletteView'
strings "$bin" | grep -q 'Toggle Right Sidebar'
strings "$bin" | grep -q 'Go to Workspace'
strings "$bin" | grep -q 'Command Palette'
strings "$bin" | grep -q 'Collapse Focused Group'
strings "$bin" | grep -q 'showPalette'
strings "$bin" | grep -q 'closeSurface'
# Swift -O may not keep IPC cmd literals as plain C strings; check symbols.
nm "$bin" | grep -q 'applyPaneMeta'
nm "$bin" | grep -q 'refreshPaneMeta'
nm "$bin" | grep -q 'browserURLForPane'

echo "smoke ok: $bin"
