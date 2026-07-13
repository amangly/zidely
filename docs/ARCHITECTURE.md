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
| Agent model | Orchestrate external CLI agents first; native Zig agent later | Orchestration is cheap (agents are PTY processes) and delivers the value now; the native agent needs the editor and competes with Claude Code on day one. Both share pane/workspace plumbing. |
| Worktrees | First-class managed worktree-per-agent-task with review → merge → clean-up | This is what makes parallel agents safe; worktree-awareness must live in the core data model from day one. Shell out to `git`; libgit2 only if necessary. |
| Sessions | Server-shaped core library, in-process now, daemon later | Same library later runs detached → live session survival, SSH workspaces, mobile companion. Early "restore" = layout+cwd respawn, honestly labeled. |
| Automation | The session-server message API doubles as the socket + CLI API | cmux's CLI/socket feature falls out of the architecture for free. |
| Browser / preview | Platform webview (WKWebView, later WebKitGTK) in the shell | No one builds a browser engine; per-platform glue is unavoidable, so it lives in the shells. |
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

## Phases

1. **Multiplexer** — libghostty panes, PTY lifecycle, vertical tabs with
   git status, splits, managed worktree agent tasks, notification rings,
   layout/cwd session restore. macOS Swift shell.
2. **Automation & reach** — socket + CLI API, embedded browser pane,
   daemon mode (live session survival), SSH workspaces.
3. **Editor & git UI** — Zig editor core, GPU text renderer, tree-sitter,
   LSP, Vim mode; commit graph, hunk staging.
4. **Native agent & Linux** — provider-abstracted agent loop with inline
   diffs, local-LLM support; GTK shell, Linux packaging.

## Repo layout

```
src/            Zig core (the product)
  zide.zig    library root
  session.zig   session server — sessions, panes, the future daemon/API seam
  term.zig      PTY + libghostty surface wrapper
  agent.zig     agent task orchestration
  gitx.zig      worktree management, repo status, commit graph (later)
  editor.zig    editor engine (phase 3)
  main.zig      dev CLI (temporary; becomes the automation CLI)
macos/          Swift/AppKit shell (arrives with the first milestone)
docs/           this file, design notes
```
