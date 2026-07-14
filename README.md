<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-white-256.png">
    <img src="assets/logo-256.png" alt="zide logo" width="128">
  </picture>
</p>

# zide

A terminal built for running many AI coding agents in parallel, growing into
a full AI-native development workspace.

Think [cmux](https://cmux.com) + [terax](https://terax.app), combined, with
the core written in Zig.

<p align="center">
  <a href="https://github.com/amangly/zide/raw/main/assets/zide-overview.mp4">
    <img src="assets/zide-overview.gif" alt="zide overview — agent-aware workspaces, terminal splits, docked browser" width="100%">
  </a>
</p>

> _Overview: agent-aware workspaces (Claude and Codex running side by side),
> recursive terminal splits, and a docked browser — all daemon-backed.
> Click for the full-quality video._

**Status: pre-alpha, but real.** A daemon owns sessions and PTY panes (they
survive the app); the macOS app renders them on GPU libghostty surfaces in a
cmux-style workspace — recursive splits, a docked WebKit browser, and a sidebar
that follows what each pane is running (an agent, a command, a directory). AI
agents run as ordinary processes; the shell detects and surfaces them.
macOS-first; Linux and the editor are next.

## Get it

Download the latest [macOS release](https://github.com/amangly/zide/releases)
(Apple Silicon), or build from source — see **[macos/README.md](macos/README.md)**.

## What it is

- **Agent multitasking** — run CLI agents (Claude Code, Codex, Aider, …) as
  ordinary processes in panes; the sidebar detects each one and follows its
  status.
- **Multiplexer terminal** — libghostty GPU panes, recursive splits, a docked
  browser, and daemon-backed sessions that survive the app.
- **IDE, eventually** — our own editor core (rope buffers, tree-sitter, LSP,
  Vim emulation, GPU rendering), a git UI, and a native agent with inline diffs.

## Architecture in one paragraph

All logic lives in a UI-agnostic Zig core shaped like a server — sessions,
panes, and PTYs behind a message-passing socket. Thin native shells render it:
Swift/AppKit on macOS first, GTK on Linux next. Terminal emulation comes from
embedding libghostty; the editor will get a custom Zig GPU renderer. The core
runs as a detached daemon, so sessions survive the UI and the same socket
doubles as the automation API and CLI.

## Documentation

| Doc | What's in it |
|---|---|
| [macos/README.md](macos/README.md) | macOS setup, build, install, and distribution |
| [ZIDE.md](ZIDE.md) | Living project map: modules, conventions, gotchas |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design decisions and their rationale |
| [ROADMAP.md](ROADMAP.md) | Phase plan and status |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Environment setup and workflow |

## License

[Apache-2.0](LICENSE)
