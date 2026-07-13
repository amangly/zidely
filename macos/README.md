# zide macOS shell

The real shell: a native AppKit window whose terminal panes are GPU
libghostty surfaces.

```sh
./build.sh                 # builds GhosttyKit first if needed
open out/Zide.app          # auto-starts the daemon if it isn't running
```

Requirements: a full Xcode (Metal compiler + `xcodebuild
-create-xcframework`) for `scripts/build-ghosttykit.sh` only — the
Swift sources themselves build with Command Line Tools. See ZIDE.md's
gotchas before touching the toolchain: `DEVELOPER_DIR` must NOT be set
globally, since Zig 0.15.2 cannot link against macOS 26+ SDKs.

## How a pane renders

Panes live in the daemon, not the app. Each terminal surface runs
`zide attach <pane>`, which puts that connection into raw-passthrough
mode on the control socket — the tmux-client model. So the PTY, the
scrollback, and any agent driving it survive the app quitting, while
all rendering and input encoding are ghostty's.

Browser panes are WKWebViews; the app `host-register`s, so `zide eval`
works against them from the CLI while it runs.

## Shortcuts

⌘T new terminal · ⌘N new session · ⌘B new browser pane. Ghostty binds
some of these itself, so they are explicitly reserved for the shell
(see `TerminalSurfaceView.shellShortcuts`).
