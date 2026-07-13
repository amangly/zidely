# ZIDE.md

Living project document: architecture map, conventions, and gotchas.
Written for both human contributors and AI agents (`CLAUDE.md` and
`AGENTS.md` point here). Keep it current — when a change invalidates
something below, update this file in the same commit.

Design *decisions* and their rationale live in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); this file is the map of
what exists today. Delivery status lives in [ROADMAP.md](ROADMAP.md).

## Project

An AI-agent-multitasking terminal growing into an AI-native IDE
(cmux + terax combined), built as a Zig core with native platform
shells. AI agents (claude, codex, ...) run as ordinary processes in
ordinary panes; the shell detects and surfaces them — there is no
managed task machinery (removed 2026-07-14; it lives in git history).
macOS first, Linux second. Pre-alpha: the core library and the macOS
shell both work; panes live in the daemon and survive the app.

Verification commands (run before every commit):

```sh
zig build test              # all tests, both module and CLI
zig fmt src build.zig       # formatting (CI enforces --check)
./macos/build.sh            # the macOS shell (builds GhosttyKit if needed)
open macos/out/Zide.app     # the app; auto-starts the daemon
```

## Toolchain

- **Zig 0.15.2 exactly** — pinned to Ghostty v1.3.1's
  `minimum_zig_version`. Bump only together with the ghostty dependency.
- No other toolchain requirements for the core. The macOS shell (when it
  lands) needs full Xcode; Command Line Tools are enough for the core.

## Module layout

Everything that is not pixels lives in the Zig core (`src/`). Platform
shells will consume it as a library and stay thin.

| Path | Responsibility |
|---|---|
| `src/zide.zig` | Library root; re-exports the modules below |
| `src/session.zig` | Session server: owns the xev event loop, sessions, terminal panes, and browser-pane state; emits `pane_output` / `pane_bell` / `pane_exit` through `EventHandler` |
| `src/term.zig` | Terminal namespace: re-exports Pty, Pane, BellScanner |
| `src/term/Pty.zig` | POSIX pseudo-terminal: openpty, sizing ioctls, child pre-exec setup |
| `src/term/Pane.zig` | PTY-attached child process feeding a ghostty-vt Terminal (queryable screen state, no rendering); `replayBytes` serializes that state back to VT bytes for attach repaints |
| `src/term/bell.zig` | Parser-aware BEL detection (ignores OSC/DCS string terminators) |
| `src/gitx.zig` | Git introspection: repo status (branch, dirty) for pane metadata. Shells out to `git` |
| `src/ipc.zig` | Control socket: JSON-lines protocol over a Unix socket — commands in, events broadcast to every client; `Client` is the synchronous consumer the CLI uses. Also the browser/host protocol (`host-register` + browser-open/navigate/eval routing), the `attach` command (raw PTY passthrough for terminal renderers, plus `resize`; every attachment opens with a state replay — VT bytes reconstructing the pane's content, colors, cursor, and modes — so renderers never start blank), `panes-meta` returns per-pane cwd / git branch+dirty / listening ports / foreground command / last screen line for status displays. `kill-pane` HUPs a pane's child and `remove-pane` drops the *finished* pane from its session (`pane_removed` event) — two steps because removal must come from request context, never from inside the pane's own event callback. `notices` returns a bounded history (256) of attention-worthy events — bells and pane exits, each with seq + unix-ms timestamp — so a shell relaunching after the broadcasts fired rebuilds its notification panel (`{"cmd":"notices","seq":<last-seen>}` returns only newer entries) |
| `src/persist.zig` | Session persistence: save/restore of layout (titles + pane spawn recipes) as versioned JSON |
| `src/procinfo.zig` | Live process introspection: child cwd (libproc / /proc), process-tree snapshot via `ps`, listening TCP ports via `lsof` — descendants matter because shells put jobs in their own process groups |
| `src/editor.zig` | Editor engine — empty until phase 3 |
| `src/main.zig` | The `zide` CLI: `serve`/`daemon` host the server+socket (state restore/save, detach, pidfile), everything else is a client command with tmux-style daemon auto-start. `zide attach <pane>` turns the calling terminal into the pane (raw mode, SIGWINCH → resize, ctrl-\ detaches) — the transport the shell's libghostty surfaces ride. |

The macOS shell (`macos/`, built by `macos/build.sh` with swiftc — no
Xcode project):

| Path | Responsibility |
|---|---|
| `macos/Sources/main.swift` | Entry point: finds the `zide` binary, auto-starts the daemon, `ghostty_init`, hands off to the controller; `ZIDE_UI_DEMO=1` enables chrome fixtures |
| `macos/Sources/GhosttyRuntime.swift` | The process-wide `ghostty_app_t` + runtime callbacks (wakeup/tick, clipboard, close); loads the user's own ghostty config so terminals look like their ghostty |
| `macos/Sources/TerminalSurfaceView.swift` | One libghostty surface per pane; its child command is `zide attach <pane>`. Minimal port of Ghostty's SurfaceView input handling (keys, mouse, scroll, focus, resize) |
| `macos/Sources/ShellController.swift` | Window glue: view-model ↔ sidebar/host, menus/shortcuts (sidebar toggle, notifications, workspace jump), socket events, agent-pane detection; live panes attach into host panel slots |
| `macos/Sources/ShellViewModel.swift` | Workspace/layout/notification view state; collapse, unread, surface selection, split ratio; `.demo()` fixtures, live `applyLive` + `applyPaneMeta` (cwd/branch/ports) |
| `macos/Sources/ShellTheme.swift` | Chrome tokens (colors, fonts, spacing) |
| `macos/Sources/SidebarView.swift` | Translucent sidebar, collapsible groups, footer actions |
| `macos/Sources/WorkspaceRowView.swift` | Vertical-tab row: title, snippet, meta, pin, status dot, unread badge |
| `macos/Sources/WorkspaceHostView.swift` | Surface tabs, draggable splits, panel slots, browser omnibar (live URL + Enter navigates) |
| `macos/Sources/NotificationPanelView.swift` | Notification list panel (⌘⇧I) |
| `macos/Sources/RightSidebarView.swift` | Right sidebar stub (⌘⌥B) |
| `macos/Sources/WorkspaceSwitcherView.swift` | Go-to-workspace switcher (⌘P) |
| `macos/Sources/CommandPaletteView.swift` | Command palette (⌘⇧P) |
| `macos/Sources/SocketClient.swift` | JSON-lines client for the control socket |

Support directories: `docs/` (decision record), `assets/` (logo +
macOS iconset), `hosts/macos-browser/` (standalone WKWebView host
prototype, superseded by the shell's browser panes but kept as a
minimal reference), `scripts/` (GhosttyKit build),
`.github/workflows/` (CI).

## Conventions

- Conventional Commits (`feat:`, `fix:`, `chore:`, ...), short subjects,
  no bodies unless needed. No AI attribution lines.
- Comments explain *why* or a constraint the code can't show — never
  what the next line does.
- Every behavioral change lands with a test in the same module. The
  pattern throughout: integration-style tests that spawn real processes
  on real PTYs and real scratch git repos (`std.testing.tmpDir`).
- Heap-pin anything the kernel or a callback holds a pointer to
  (Pane and PaneHandle are `create()`/`destroy()` for this reason).
- Event handlers chain: install yours, keep the previous one as
  `downstream`, forward everything (see `ipc.Server.onSessionEvent`).
- New dependencies need a pin rationale in docs/ARCHITECTURE.md's
  dependency notes. Prefer the exact versions Ghostty pins (libxev is).

## Known gotchas

- **ghostty is a fork pin**: `amangly/ghostty` branch `zide-v1.3.1` —
  upstream v1.3.1 plus build patches: gating Darwin xcframework/app step
  construction (needs full Xcode otherwise; upstream main already has
  the fix), constructing only the xcframework lib variants the target
  needs (a native build must not resolve iOS SDKs), and
  `GHOSTTY_METAL_DEVELOPER_DIR` for CLT-host Metal compiles. Repin to
  upstream at the next Ghostty release; offer the last two upstream.
- **Dependency emit flags**: consumers must pass
  `emit-xcframework=false` and `emit-macos-app=false` to the ghostty
  dependency — their defaults are *true* on Darwin hosts.
- **libxev Dynamic collapses on macOS** to the static kqueue API:
  guard `detect()` with `@hasDecl` (see `session.zig`).
- **libxev completions**: zero-init with `.{}`. Dynamic's
  `Completion.init()` is broken for io_uring at the pinned commit.
- **libxev Process.wait** delivers a *plain exit code* on both backends
  (kqueue decodes the wait status itself) and reaps the child. Signal
  deaths surface as 0 (macOS) / signal number (Linux) — improving this
  means reaping ourselves.
- **PTY EOF differs by OS**: Linux reports `EIO` on the master after
  child exit, macOS reports 0-byte read. Treat both as EOF.
- **`pane_exit` timing**: emitted only after child exit *and* PTY
  drain — never assume output is complete at process exit.
- **BEL is ambiguous**: 0x07 also terminates OSC sequences; always go
  through `BellScanner`, never grep bytes.
- **CI runners**: `macos-latest` is macOS 26 beta (SDK breaks Zig
  0.15.2 linking) — stay on `macos-15` until the Zig/Ghostty pin moves.
- **Quiescence timer discipline**: any repeating xev timer must disarm
  itself when idle, or `Server.run(.until_done)` never returns.
- **Never close an fd with a pending xev completion**: kqueue silently
  drops the filter and the completion never fires, stranding the loop.
  The ipc server drains its accept completion with a self-connect poke
  on shutdown, and EOFs clients via `shutdown(2)` instead of `close`.
- **libxev is a fork pin** (`amangly/libxev@zide-fix-kqueue-rearm-state`):
  upstream's kqueue backend loses a completion's `.active` state when it
  is rearmed via the submit()/completions path (ready-at-registration
  events), so its eventual disarm skips the active-counter decrement and
  `run(.until_done)` never returns. One-line fix; upstream it.
- **`std.fs.File.writer()` is positional**: every fresh writer starts at
  offset 0 and overwrites redirected output. Use `writeAll` (or
  `writerStreaming`) for stdout.
- **std posix wrappers panic on "impossible" errno**: e.g. macOS returns
  EINVAL from setsockopt on a socket whose peer already disconnected,
  which `std.posix.setsockopt` treats as unreachable. In server paths
  that touch client-controlled sockets, call `std.c` directly and handle
  errno yourself.
- **Daemonize before the event loop exists**: kqueue descriptors do not
  survive fork; `zide daemon` double-forks first, then builds the server.
- **Attached connections leave JSON forever**: after the `attach` ok
  reply a connection is a raw byte pipe — `broadcast` must skip it (one
  JSON line corrupts the stream) and the pane-exit path half-closes it
  with `shutdown(2)` so the client sees EOF.
- **Ghostty surfaces swallow ⌘-shortcuts**: libghostty has its own
  keybindings (⌘T = new_tab) and consumes them in
  `performKeyEquivalent` before the menu ever sees them — our action
  callback then drops them, so the shortcut silently does nothing.
  Shell-owned shortcuts must be refused explicitly
  (`TerminalSurfaceView.shellShortcuts`).
- **Late clients missed every event**: a shell connecting to a live
  daemon never saw the `pane_exit` broadcasts that already happened.
  Any state a client renders must be *queryable*, not broadcast-only —
  that's why `list-sessions` reports `exited`.
- **The app finds `zide` by walking up from the bundle**: running
  `macos/out/Zide.app` from the dev tree works; a copy elsewhere (e.g.
  /Applications) needs `ZIDE_BIN` until there's a real install layout.
- **`zig build test` does not install the binary**: the daemon the app
  auto-starts is `zig-out/bin/zide`, so run plain `zig build` before
  manual testing or you will debug a stale daemon (an auto-started one
  outlives the app, too — `zide shutdown` between runs).
- **Never set DEVELOPER_DIR globally for zig**: Zig 0.15.2 cannot link
  under the macOS 26+ SDKs a new Xcode activates (missing-libSystem
  errors; same failure as `macos-latest` CI). GhosttyKit needs full
  Xcode only for the Metal compiler and `-create-xcframework`, so
  `scripts/build-ghosttykit.sh` scopes it: zig under CLT,
  `GHOSTTY_METAL_DEVELOPER_DIR` (fork patch) for metal/metallib, a PATH
  shim for xcodebuild. Xcode 26+ also needs the Metal Toolchain
  component downloaded once (`xcodebuild -downloadComponent
  MetalToolchain`).

## Further reading

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — settled design
  decisions with rationale, dependency notes, phase plan
- [ROADMAP.md](ROADMAP.md) — phase status
- [CONTRIBUTING.md](CONTRIBUTING.md) — environment setup, workflow
