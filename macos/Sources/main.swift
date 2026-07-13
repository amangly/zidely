// Zide.app entry point: resolve the zide binary, make sure the daemon
// is up (tmux-style auto-start), initialize libghostty, then hand off
// to the shell controller.

import AppKit
import GhosttyKit

func findZideBinary() -> String? {
    let fm = FileManager.default
    let isExec = { (p: String) in fm.isExecutableFile(atPath: p) }

    if let env = ProcessInfo.processInfo.environment["ZIDE_BIN"], isExec(env) { return env }

    // Dev tree: the app lives at <repo>/macos/out/Zide.app.
    var dir = Bundle.main.bundleURL.deletingLastPathComponent()
    for _ in 0..<4 {
        let candidate = dir.appendingPathComponent("zig-out/bin/zide").path
        if isExec(candidate) { return candidate }
        dir.deleteLastPathComponent()
    }

    // Next to the app binary (a future bundled install).
    if let exe = Bundle.main.executableURL {
        let sibling = exe.deletingLastPathComponent().appendingPathComponent("zide").path
        if isExec(sibling) { return sibling }
    }

    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/zide"
        if isExec(candidate) { return candidate }
    }
    return nil
}

func fatal(_ message: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "zide"
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ShellController?
    var runtime: GhosttyRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let socketPath = ProcessInfo.processInfo.environment["ZIDE_SOCKET"]
            ?? "/tmp/zide-\(getuid()).sock"
        guard let zideBin = findZideBinary() else {
            fatal("cannot find the `zide` binary — build the core first (zig build) or set ZIDE_BIN")
        }

        // Connect, auto-starting the daemon like the CLI does.
        var client = SocketClient(path: socketPath)
        if client == nil {
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: zideBin)
            daemon.arguments = ["daemon", "--socket", socketPath]
            try? daemon.run()
            daemon.waitUntilExit()
            client = SocketClient(path: socketPath)
        }
        guard let client else {
            fatal("cannot reach the zide daemon on \(socketPath)")
        }
        client.onDisconnect = {
            NSApp.terminate(nil)
        }

        guard let runtime = GhosttyRuntime() else {
            fatal("libghostty failed to initialize")
        }
        GhosttyRuntime.shared = runtime
        self.runtime = runtime

        controller = ShellController(
            client: client,
            runtime: runtime,
            zideBin: zideBin,
            socketPath: socketPath)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// libghostty needs its resources (themes, shell integration) which the
// bundle carries; point it there before any ghostty call.
if let resources = Bundle.main.resourcePath {
    let ghosttyResources = resources + "/ghostty"
    if FileManager.default.fileExists(atPath: ghosttyResources) {
        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 1)
    }
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != 0 {
    FileHandle.standardError.write("ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
