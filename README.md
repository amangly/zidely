# zidely

A terminal built for running many AI coding agents in parallel, growing into
a full AI-native development workspace. One app: multiplexer-grade terminal,
managed git-worktree isolation per agent task, and — over time — an editor,
git UI, and native agent with inline diffs.

Think [cmux](https://cmux.com) + [terax](https://terax.app), combined, with
the core written in Zig.

**Status: pre-alpha scaffold.** Nothing usable yet. The design is settled
(see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)); the code is being built
foundation-first.

## What it will be

- **Agent multitasking** — spawn CLI agents (Claude Code, Codex, Aider, …)
  as first-class tasks, each isolated in its own git worktree + branch,
  with attention notifications and a review → merge → clean-up flow.
- **Multiplexer terminal** — libghostty-powered panes, vertical tabs
  showing branch/dir/ports, split layouts, session restore.
- **IDE, eventually** — our own editor core (rope buffers, tree-sitter,
  LSP, Vim emulation, GPU rendering), git commit graph, web preview,
  and a native agent that proposes inline diffs.

## Architecture in one paragraph

All logic lives in a UI-agnostic Zig core shaped like a server (sessions,
panes, PTYs, agent tasks behind a message-passing API). Thin native shells
render it: Swift/AppKit on macOS first, GTK on Linux second. Terminal
emulation comes from embedding libghostty; editor text gets a custom Zig
GPU renderer. The server-shaped core later becomes a detached daemon —
unlocking live session survival, SSH workspaces, and the automation
socket/CLI — without a rewrite.

## Building

Requires **Zig 0.15.2** exactly (pinned to match Ghostty v1.3.1, our
terminal engine dependency).

```sh
zig build test   # run tests
zig build run    # dev CLI (exercises the core library)
```

## License

[Apache-2.0](LICENSE)
