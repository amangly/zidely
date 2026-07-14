# zide architecture

Decision record from the founding design interview (2026-07-13). These are
settled decisions; revisit deliberately, not accidentally.

## Vision

Combine two products into one:

- **cmux** (cmux.com) — native macOS terminal for agent multitasking:
  vertical tabs with git/port/notification status, split panes,
  notification rings, embedded browser, CLI + socket automation API,
  session restore.
- **terax** (terax.app) — lightweight AI-native workspace: terminal +
  editor (real Vim mode), AI agents with inline edit diffs, git UI with
  commit graph, live web preview, local-LLM support.

Ambition: the full combined product, built foundation-first over years —
not an MVP experiment.

## Decisions

| Area | Decision | Why |
|---|---|---|
| UI architecture | Zig core + thin native shells (Swift/AppKit, then GTK) | Ghostty's proven split. Best text rendering, IME, accessibility, and trivial webview embedding; the alternative (pure-Zig UI toolkit) costs 1–2 years before the shell alone is solid. |
| Platforms | macOS phase 1, Linux phase 2, no Windows | Dev machine is macOS; libghostty's most proven path; POSIX-only PTY layer, no ConPTY abstraction. |
| Terminal engine | Embed libghostty, pinned to Ghostty v1.3.1 | World-class VT + GPU rendering in Zig; exactly what cmux does. Spend our years on the IDE/agent layer, not a VT parser. Pins us to Zig 0.15.2. |
| Editor | Own Zig core: rope buffers, tree-sitter (C FFI), LSP client, Vim emulation | The editor is the IDE's identity; owning the buffer model makes AI inline diffs and agent edits first-class. Zed/Helix each walked this path. |
| Editor rendering | Custom Zig GPU text renderer in core (CoreText/HarfBuzz shaping via FFI) | Written once, identical on both platforms; code is monospace so grid-plus-overlays suffices, no rich-text layout needed. |
| Agent model | AI agents (claude, codex, …) run as ordinary processes in ordinary panes; the shell detects them (foreground command) and surfaces status/attention | **Revised 2026-07-14.** The original decision was managed worktree-per-task orchestration with a review → merge flow; it shipped, and was then removed — existing agent CLIs already own that workflow, and the managed layer duplicated them. The implementation lives in git history if it is ever wanted back. Users who want isolation create worktrees themselves and run agents in panes there. |
| Sessions | Server-shaped core library, in-process now, daemon later | Same library later runs detached → live session survival, SSH workspaces, mobile companion. Early "restore" = layout+cwd respawn, honestly labeled. |
| Shell pane transport | libghostty surfaces run `zide attach <pane>` (the tmux-client model); attach = raw-passthrough mode on the control socket | Resolves the PTY-ownership tension: panes stay daemon-owned (survival, agents, CLI) while rendering is native ghostty GPU — cmux's remote-tmux-attach pattern. Any terminal can attach, not just our shell. |
| Automation | The session-server message API doubles as the socket + CLI API | cmux's CLI/socket feature falls out of the architecture for free. |
| Browser / preview | Platform webview (WKWebView, later WebKitGTK) in the shell | No one builds a browser engine; per-platform glue is unavoidable, so it lives in the shells. |
| Workspace model | Sidebar rows are daemon sessions (workspaces); each workspace holds a recursive split tree of terminal panes with browser panels docked as a right-hand column | **Revised 2026-07-14** — the first shell made every pane its own row, which sprayed browsers across the sidebar and let workspaces dissolve when a pane died. cmux's model (workspace = project context owning a surface tree + `_dockSplit` for browsers) is the proven shape; zide's sessions already were that container. |
| Config | Ghostty-style `key = value` file; per-project markdown memory when the native agent lands | Boring and proven. |
| Extensibility | Deferred for years; the server API is the designed-in seam | Don't build a plugin system before there's a product. |
| Toolchain | Zig 0.15.2 exactly | Must match Ghostty v1.3.1's `minimum_zig_version`. Bump only together with the Ghostty pin. |
| License | Apache-2.0 | Open like both references (terax is Apache-2.0; libghostty is MIT, compatible). |

## Dependency notes

- **ghostty** is pinned to `amangly/ghostty@zide-v1.3.1` — upstream
  v1.3.1 plus one build patch gating Darwin xcframework/app step
  *construction* behind the emit options (upstream main already has this
  fix). Without it, consuming the `ghostty-vt` module on a Mac without
  full Xcode fails at build-graph time needing the iOS SDK. Drop the fork
  and repin to the next upstream release (v1.4+) when it ships.
- Consumers must pass `emit-xcframework=false` and `emit-macos-app=false`
  to the dependency: their defaults are *true* on Darwin hosts.
- **libxev** is pinned to `amangly/libxev@zide-fix-kqueue-rearm-state` —
  the commit Ghostty pins plus a one-line kqueue fix (rearm via the
  completions path lost the completion's active state, stranding the
  loop; see ZIDE.md gotchas). Drop the fork once upstreamed.

## Phases

1. **Multiplexer** — libghostty panes, PTY lifecycle, vertical tabs with
   git status, splits, agent-aware panes, notification rings,
   layout/cwd session restore. macOS Swift shell.
2. **Automation & reach** — socket + CLI API, embedded browser pane,
   daemon mode (live session survival), SSH workspaces.
3. **Editor & git UI** — Zig editor core, GPU text renderer, tree-sitter,
   LSP, Vim mode; commit graph, hunk staging.
4. **Linux** — GTK shell, Linux packaging.

## Repo layout

```
src/            Zig core (the product)
  zide.zig    library root
  session.zig   session server — sessions, panes, the future daemon/API seam
  term.zig      PTY + libghostty surface wrapper
  gitx.zig      repo status, commit graph (later)
  editor.zig    editor engine (phase 3)
  main.zig      dev CLI (temporary; becomes the automation CLI)
macos/          Swift/AppKit shell (arrives with the first milestone)
docs/           this file, design notes
```
