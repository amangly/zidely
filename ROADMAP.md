# Roadmap

Phases from the founding design (see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). Order is deliberate:
foundation first, pixels when the core deserves them.

> **Pivot (2026-07-14):** the managed agent-task machinery
> (worktree-per-task provisioning, task manager, review → merge flow,
> task persistence) was removed. AI agents — claude, codex, and
> friends — run as ordinary processes in ordinary panes; the shell
> detects them (foreground command), surfaces their live status line
> in the sidebar, and treats their bells as attention. The removed
> implementation lives in git history if it is ever wanted back.

## Phase 1 — Multiplexer core

- [x] Repo, toolchain pin (Zig 0.15.2), CI (macOS + Linux)
- [x] PTY layer (openpty, sizing, controlling-terminal child setup)
- [x] Panes: PTY child feeding ghostty-vt terminal state
- [x] Event-loop session server (libxev) with pane event stream
- [x] Attention detection: parser-aware bell
- [x] macOS Swift/AppKit shell (`macos/`, cmux-style): GPU libghostty
      surfaces, sidebar of sessions/panes with attention dots, browser
      panes, daemon-owned panes that survive the app
  - [x] `zide attach` — raw PTY transport the surfaces ride
  - [x] attach state replay: the daemon repaints the pane's full
        screen (content, colors, cursor, modes) as the first bytes of
        every attachment — new surfaces and late attachers start from
        the real screen, not blank
  - [x] GhosttyKit.xcframework builds (scripts/build-ghosttykit.sh)
  - [x] agent-aware sidebar: panes running claude/codex/… light up
        (working / needs-attention) and show the pane's live status
        line, driven by `panes-meta` (foreground command + last
        screen line)
  - [x] real splits (⌘D/⌘⇧D spawn daemon panes), close-on-exit panes
  - [ ] daemon-side split layout (splits surviving app restarts),
        IME/preedit
- [x] Session restore (layout + cwd respawn)

## Phase 2 — Automation & reach

- [x] Socket API (the session server's event/command stream, exposed)
- [x] `zide` CLI against the socket
- [x] Embedded browser pane (WKWebView) with programmable API
      (prototype host; moves into the Swift shell when it lands)
- [x] cmux workspace model: sidebar rows are sessions; each workspace
      is a recursive split tree of terminals with browsers docked as
      the right column (never rows); ⌘T = new workspace,
      ⌘W = close panel (last panel closes the workspace),
      ⌘⇧W = close workspace (daemon `remove-session`)
- [x] Real-browser behavior in browser panes, following cmux's
      CmuxBrowser stack: Safari UA engine config, omnibox with
      history/frecency suggestions, error pages, downloads
      (quarantined, to ~/Downloads), OAuth popup windows, HTTP auth
      prompts, load progress + stop/reload, page zoom
- [x] Daemon mode: live session survival across UI restarts
- [x] `panes-meta`: per-pane cwd, git branch/dirty, listening ports,
      foreground command, last screen line (the sidebar metadata the
      shell shows)
- [x] `notices`: daemon-side history of attention-worthy events
      (bells, exits) — the shell's notification panel survives app
      restarts
- [x] `kill-pane` / `remove-pane`: real close semantics for panes
- [ ] SSH / remote workspaces

## Phase 3 — Editor & git UI

- [ ] Editor core: rope buffers, tree-sitter, LSP client, Vim emulation
- [ ] GPU text renderer (CoreText/HarfBuzz shaping)
- [ ] Git UI: commit graph, hunk staging

## Phase 4 — Linux

- [ ] GTK shell + Linux packaging
