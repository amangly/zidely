# zide macOS shell

Native AppKit chrome styled like cmux (vertical workspace tabs, metadata
rows, attention rings, splits, switcher, command palette). Terminal panes
are GPU libghostty surfaces when live-wired.

**Chrome status:** core cmux IA is in place. Pane chrome matches cmux
look (slim icon tabs, header actions, in-pane browser bar, electric
focus ring). Live wiring for sidebar metadata (`panes-meta`) and browser
omnibar is connected. Remaining gaps: real daemon PTY splits, OSC
notification ingest, right-sidebar content.

```sh
./build.sh                 # builds GhosttyKit first if needed
open out/Zide.app          # auto-starts the daemon if it isn't running

# Chrome-only demo (fixtures, no socket-driven sidebar):
ZIDE_UI_DEMO=1 open out/Zide.app
```

Requirements: a full Xcode (Metal compiler + `xcodebuild
-create-xcframework`) for `scripts/build-ghosttykit.sh` only — the
Swift sources themselves build with Command Line Tools. See ZIDE.md's
gotchas before touching the toolchain: `DEVELOPER_DIR` must NOT be set
globally, since Zig 0.15.2 cannot link against macOS 26+ SDKs.

## UI map

| Piece | Role |
|---|---|
| `ShellTheme` | Colors, fonts, spacing (readable density) |
| `ShellViewModel` | Workspaces / layout / notifications / collapse; `.demo()` or live `applyLive` |
| `SidebarView` + `WorkspaceRowView` | Vertical tabs, collapsible groups (+), pin/rename menu, status chips, unread badges |
| `WorkspaceHostView` | Surface tabs, draggable splits, browser omnibar, attention ring |
| `NotificationPanelView` | ⌘⇧I notification list (demo + local unread) |
| `RightSidebarView` | ⌘⌥B stub right sidebar (files/agent/notes) |
| `WorkspaceSwitcherView` | ⌘P go-to-workspace filter list |
| `CommandPaletteView` | ⌘⇧P action runner |
| `ShellController` | Glue: menus, review bar, socket ↔ view model |

Live mode attaches real panes into panel slots and refreshes
cwd/branch/ports via `panes-meta`. Demo mode shows fixtures and disables
create/review commands. Browser omnibar shows the live WKWebView URL.

### Chrome shortcuts (cmux-inspired)

⌘B / ⌘⌥B sidebars · ⌘P switcher · ⌘⇧P command palette · ⌘⇧R rename ·
⌘⇧W close workspace · ⌘W close surface · ⌘⇧T reopen surface · ⌘⇧[ / ]
surfaces · ⌘⌥[ / ] focus panes · j/k sidebar · ⌃⌘G group · ⌃⌘. collapse ·
⌘D / ⌘⇧D splits · ⌃⌘T surface · ⌘⇧I / ⌘⇧U notifications · ⌘1–9 jump.

Verify: `./macos/smoke-ui.sh` then `ZIDE_UI_DEMO=1 open macos/out/Zide.app`.

## How a pane renders

Panes live in the daemon, not the app. Each terminal surface runs
`zide attach <pane>`, which puts that connection into raw-passthrough
mode on the control socket — the tmux-client model. So the PTY, the
scrollback, and any agent driving it survive the app quitting, while
all rendering and input encoding are ghostty's.

Browser panes are WKWebViews; the app `host-register`s, so `zide eval`
works against them from the CLI while it runs.

## Shortcuts

⌘T new terminal · ⌘N new session · ⌘⇧B new browser · ⌘K new agent
task · ⌘B toggle sidebar · ⌘D / ⌘⇧D split · ⌃⌘T surface tab ·
⌘⇧I notifications · ⌘⇧U jump unread · ⌃⌘[ / ⌃⌘] prev/next · ⌘1–⌘9
jump. Ghostty binds some of these itself, so they are explicitly
reserved for the shell (see `TerminalSurfaceView.shellShortcuts`).
