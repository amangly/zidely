# Contributing

Pre-alpha: expect churn. Read [ZIDE.md](ZIDE.md) first — it's the
project map and lists the gotchas that will otherwise cost you an hour.

## Environment

The only requirement for the core is **Zig 0.15.2, exactly** (it must
match the ghostty dependency's pin — see ZIDE.md):

```sh
# macOS (arm64); adjust the tarball for your platform
mkdir -p ~/.zig && cd ~/.zig
curl -fsSL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz | tar xJ
ln -s ~/.zig/zig-aarch64-macos-0.15.2/zig ~/.local/bin/zig
zig version   # 0.15.2
```

Linux: same recipe with the `x86_64-linux` or `aarch64-linux` tarball.
Homebrew/apt Zig will usually be the wrong version — don't use them.

`git` must be on PATH (the test suite creates scratch repositories and
worktrees). On macOS, Command Line Tools suffice for the core; the
Swift shell work will need full Xcode.

## Workflow

```sh
zig build test          # must pass
zig fmt src build.zig   # must be clean (CI runs --check)
zig build run           # sanity-check the demo when touching core I/O
```

- First build fetches and compiles dependencies (ghostty-vt, libxev);
  expect a few minutes, then it's cached.
- Conventional Commits, short subjects.
- Tests accompany the change, in the same module, preferring the
  existing integration style (real PTYs, real scratch git repos).
- If your change invalidates ZIDE.md, docs/ARCHITECTURE.md, or
  ROADMAP.md, update them in the same commit.

## CI

GitHub Actions runs `zig build test` and `zig fmt --check` on
`macos-15` and `ubuntu-latest`. The macOS runner is pinned — see the
CI gotcha in ZIDE.md before touching it.
