// JSON-lines client for the zide control socket (ipc.zig protocol).
// Requests get integer ids and completions; event objects fan out to
// onEvent. All callbacks run on the main queue.

import AppKit

final class SocketClient {
    private let fd: Int32
    private var nextId: UInt64 = 100
    private var pending: [UInt64: ([String: Any]) -> Void] = [:]
    var onEvent: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr, pathCap - 1)
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            return nil
        }
        startReader()
    }

    /// Send a command; the completion runs on the main queue.
    func send(_ obj: [String: Any], _ completion: (([String: Any]) -> Void)? = nil) {
        var obj = obj
        nextId += 1
        obj["id"] = nextId
        if let completion { pending[nextId] = completion }
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private func startReader() {
        DispatchQueue.global().async { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 {
                    DispatchQueue.main.async { self.onDisconnect?() }
                    return
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer.prefix(upTo: nl))
                    buffer.removeSubrange(...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { continue }
                    DispatchQueue.main.async { self.route(obj) }
                }
            }
        }
    }

    private func route(_ obj: [String: Any]) {
        if obj["event"] is String {
            onEvent?(obj)
        } else if let id = (obj["id"] as? NSNumber)?.uint64Value,
                  let cb = pending.removeValue(forKey: id) {
            cb(obj)
        }
    }
}
