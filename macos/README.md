# Zide for macOS

The native macOS app — a Swift/AppKit shell that renders GPU
[libghostty](https://ghostty.org) terminal surfaces over the zide daemon, in a
cmux-style workspace. Panes live in the daemon, so they survive the app.

## Requirements

- Apple Silicon Mac (arm64)
- **Zig 0.15.2** exactly — pinned to match Ghostty v1.3.1, the terminal engine
- **Xcode** (full) for the first GhosttyKit build (Metal shaders + xcframework
  packaging). Command Line Tools are enough for everything after that.

## Build & run

```sh
zig build              # the Zig core (zide daemon + CLI) → zig-out/bin/zide
./macos/build.sh       # Zide.app  (builds GhosttyKit on first run)
open macos/out/Zide.app
```

The app auto-starts the daemon the first time it needs it (tmux-style). For a
chrome-only demo with fixtures instead of a live daemon:

```sh
ZIDE_UI_DEMO=1 open macos/out/Zide.app
```

## Install

`install.sh` produces a **self-contained** `Zide.app` — the `zide` daemon
binary and all resources (libghostty, terminfo) are bundled inside, so an
installed copy needs no dev tree and no `ZIDE_BIN`:

```sh
./macos/install.sh                        # → /Applications/Zide.app
PREFIX=~/Applications ./macos/install.sh  # install somewhere else
```

## Distribute (DMG)

```sh
./macos/make-dmg.sh                        # → macos/out/Zide-<version>.dmg
```

Recipients open the DMG and drag **Zide.app** onto **Applications**. The build
is ad-hoc signed, so a downloaded copy is quarantined by Gatekeeper — clear the
flag once after installing:

```sh
xattr -dr com.apple.quarantine /Applications/Zide.app
```

## Signing (optional)

Browser passkey / Touch ID sign-in only works when the app is signed with an
Apple Developer ID plus the web-browser entitlement. Pass an identity and the
build signs itself with [`zide.entitlements`](zide.entitlements):

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./macos/install.sh
```

For public distribution, also notarize the DMG — see the header of
[`make-dmg.sh`](make-dmg.sh).

## How a pane renders

Each terminal surface runs `zide attach <pane>`, which puts that connection
into raw-passthrough mode on the control socket — the tmux-client model. The
PTY, scrollback, and any agent driving it survive the app quitting, while all
rendering and input encoding are ghostty's. Browser panes are `WKWebView`s; the
app `host-register`s so `zide eval` works against them from the CLI.

## Shortcuts

⌘T new workspace · ⌘N new session · ⌘⇧B browser panel · ⌘D / ⌘⇧D split ·
⌘W close panel · ⌘⇧W close workspace · ⌘L address bar · ⌘B / ⌘⌥B sidebars ·
⌘P switcher · ⌘⇧P command palette · ⌘⇧R rename · ⌘⇧I notifications ·
⌘⇧U jump unread · ⌘⌥[ / ] focus pane · ⌃⌘[ / ] prev/next workspace ·
⌃⌘G group · ⌃⌘. collapse · ⌘+ / ⌘- / ⌘0 browser zoom · ⌘1–9 jump · j/k sidebar.

Ghostty binds some of these itself, so the shell reserves them explicitly (see
`TerminalSurfaceView.shellShortcuts`).

## Notes

- **Binary resolution:** the app looks for `zide` next to its own executable
  (bundled install), then the dev tree (`zig-out/bin/zide`), then `$ZIDE_BIN`,
  then `$PATH`.
- **Never set `DEVELOPER_DIR` globally** — Zig 0.15.2 can't link under the
  macOS 26+ SDKs a new Xcode activates. `scripts/build-ghosttykit.sh` scopes
  Xcode to just the Metal compile + xcframework step.
- The module map, conventions, and deeper build gotchas live in
  [../ZIDE.md](../ZIDE.md); environment setup in [../CONTRIBUTING.md](../CONTRIBUTING.md).
