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
- [ ] macOS Swift/AppKit shell: libghostty rendering, vertical tabs,
      splits, notification rings (blocked on: full Xcode install)
- [x] Session restore (layout + cwd respawn)

## Phase 2 — Automation & reach

- [x] Socket API (the session server's event/command stream, exposed)
- [x] `zide` CLI against the socket
- [ ] Embedded browser pane (WKWebView) with programmable API
- [ ] Daemon mode: live session survival across UI restarts
- [ ] SSH / remote workspaces

## Phase 3 — Editor & git UI

- [ ] Editor core: rope buffers, tree-sitter, LSP client, Vim emulation
- [ ] GPU text renderer (CoreText/HarfBuzz shaping)
- [ ] Git UI: commit graph, hunk staging, worktree review/merge flow

## Phase 4 — Native agent & Linux

- [ ] Native agent loop (provider-abstracted, local-LLM support)
- [ ] AI edit diffs inline in the editor
- [ ] GTK shell + Linux packaging
