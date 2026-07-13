Read @ZIDE.md before making changes — it is the living map of this
project: module layout, conventions, and hard-won gotchas (dependency
pins, libxev/PTY platform quirks, CI constraints).

Non-negotiables:

- Zig 0.15.2 exactly; never bump independently of the ghostty pin.
- `zig build test` and `zig fmt src build.zig` must pass before commit.
- Update ZIDE.md / docs/ARCHITECTURE.md / ROADMAP.md in the same
  commit that invalidates them.
