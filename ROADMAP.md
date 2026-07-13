# Roadmap

Phases from the founding design (see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). Order is deliberate:
foundation first, pixels when the core deserves them.

## Phase 1 — Multiplexer core + agent orchestration

- [x] Repo, toolchain pin (Zig 0.15.2), CI (macOS + Linux)
- [x] PTY layer (openpty, sizing, controlling-terminal child setup)
- [x] Panes: PTY child feeding ghostty-vt terminal state
- [x] Event-loop session server (libxev) with pane event stream
- [x] Worktree-per-task provisioning (`zide/<slug>` branches)
- [x] Agent task manager: task → worktree → pane → status
- [x] Attention detection: bell (parser-aware) + output quiescence
- [x] macOS Swift/AppKit shell (`macos/`, cmux-style): GPU libghostty
      surfaces, sidebar of sessions/panes with attention dots, browser
      panes, daemon-owned panes that survive the app
  - [x] `zide attach` — raw PTY transport the surfaces ride
  - [x] GhosttyKit.xcframework builds (scripts/build-ghosttykit.sh)
  - [x] agent tasks end-to-end: socket surface (`task-create/list/cleanup`,
        `task_status` stream), `zide task/tasks/task-rm` CLI, sidebar
        AGENT TASKS section with attention rings (verified with a real
        Claude Code agent in a worktree)
  - [x] task review → merge → cleanup: `task-diff`/`task-merge` on the
        socket, `zide task-diff`/`task-merge` CLI, and a review bar in
        the app (colored diff, Merge & Remove, Discard) — merge refuses
        dirty worktrees and aborts cleanly on conflicts
  - [ ] splits, vertical tabs per workspace, IME/preedit
  - [x] agent tasks persist across daemon restarts: saved as records,
        re-adopted pane-less (review/merge/discard only — re-running an
        agent command fresh could redo or undo work)
- [x] Session restore (layout + cwd respawn)

## Phase 2 — Automation & reach

- [x] Socket API (the session server's event/command stream, exposed)
- [x] `zide` CLI against the socket
- [x] Embedded browser pane (WKWebView) with programmable API
      (prototype host; moves into the Swift shell when it lands)
- [x] Daemon mode: live session survival across UI restarts
- [ ] SSH / remote workspaces

## Phase 3 — Editor & git UI

- [ ] Editor core: rope buffers, tree-sitter, LSP client, Vim emulation
- [ ] GPU text renderer (CoreText/HarfBuzz shaping)
- [ ] Git UI: commit graph, hunk staging, worktree review/merge flow

## Phase 4 — Native agent & Linux

- [ ] Native agent loop (provider-abstracted, local-LLM support)
- [ ] AI edit diffs inline in the editor
- [ ] GTK shell + Linux packaging
