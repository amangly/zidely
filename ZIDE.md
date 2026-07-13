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
shells. macOS first, Linux second. Pre-alpha: the core library works,
no UI shell yet.

Verification commands (run before every commit):

```sh
zig build test              # all tests, both module and CLI
zig fmt src build.zig       # formatting (CI enforces --check)
zig build run               # event-loop demo: two shells, one loop
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
| `src/term/Pane.zig` | PTY-attached child process feeding a ghostty-vt Terminal (queryable screen state, no rendering) |
| `src/term/bell.zig` | Parser-aware BEL detection (ignores OSC/DCS string terminators) |
| `src/agent.zig` | Agent orchestration: `Manager` ties task → worktree → pane → status; attention detection; `TaskEventHandler` stream |
| `src/gitx.zig` | Git layer: worktree-per-task provisioning (branch `zide/<slug>`), shells out to `git` |
| `src/ipc.zig` | Control socket: JSON-lines protocol over a Unix socket — commands in, events broadcast to every client; `Client` is the synchronous consumer the CLI uses. Also the browser/host protocol: `host-register` + browser-open/navigate/eval routing |
| `src/persist.zig` | Session persistence: save/restore of layout (titles + pane spawn recipes) as versioned JSON |
| `src/editor.zig` | Editor engine — empty until phase 3 |
| `src/main.zig` | The `zide` CLI: `serve`/`daemon` host the server+socket (state restore/save, detach, pidfile), everything else is a client command with tmux-style daemon auto-start |

Support directories: `docs/` (decision record), `assets/` (logo +
macOS iconset), `hosts/` (native prototypes built with swiftc only —
`macos-shell/` is a windowed proto-shell over the socket protocol,
`macos-browser/` a standalone WKWebView host; see their READMEs),
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
  (Pane, PaneHandle, Manager are `create()`/`destroy()` for this reason).
- Event handlers chain: install yours, keep the previous one as
  `downstream`, forward everything (see `agent.Manager.onEvent`).
- New dependencies need a pin rationale in docs/ARCHITECTURE.md's
  dependency notes. Prefer the exact versions Ghostty pins (libxev is).

## Known gotchas

- **ghostty is a fork pin**: `amangly/ghostty` branch `zide-v1.3.1` —
  upstream v1.3.1 plus a build patch gating Darwin xcframework/app step
  construction (needs full Xcode otherwise; upstream main already has
  the fix). Repin to upstream at the next Ghostty release.
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

## Further reading

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — settled design
  decisions with rationale, dependency notes, phase plan
- [ROADMAP.md](ROADMAP.md) — phase status
- [CONTRIBUTING.md](CONTRIBUTING.md) — environment setup, workflow
