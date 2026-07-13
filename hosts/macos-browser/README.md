# macOS browser host (prototype)

Renders zide's browser panes as real WKWebView windows, driven entirely
through the control socket. This is a stand-in for the future Swift
shell's embedded browser — same protocol, throwaway chrome.

```sh
./build.sh                                   # needs Command Line Tools only
./zide-browser-host &                        # connects + host-registers
zide browse 1 https://ziglang.org            # window appears
zide nav 2 https://example.com               # it navigates
zide eval 2 document.title                   # JS runs, result comes back
```

Existing browser panes are replayed to the host when it attaches, so
starting the host late (or restarting it) re-renders everything. The
host exits when the daemon goes away.
