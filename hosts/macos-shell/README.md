# macOS proto-shell

A native AppKit window onto a running zide daemon — the first visible
zide. Throwaway chrome, real protocol: everything it shows travels over
the control socket.

- cmux-style sidebar of sessions with their terminal and browser panes
- live terminal pane view (plain-text snapshots refreshed on
  `pane_output` events; the GPU libghostty renderer arrives with the
  real shell, which needs full Xcode)
- input line: Enter sends to the selected terminal pane
- browser panes render as embedded WKWebViews (this app host-registers,
  so `zide eval` works while it runs)
- `+ session` / `+ term` / `+ web` buttons drive the daemon

```sh
./build.sh            # needs Command Line Tools only
zide daemon           # or let any zide command auto-start it
./zide-shell          # the window appears
```

Panes created from the CLI show up live; panes survive the shell being
closed and reopened — they live in the daemon.
