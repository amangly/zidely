// Turns whatever the user types in the browser address bar into a
// loadable URL, the way a normal browser omnibox behaves (pattern
// after cmux's BrowserURLResolver):
//
// - A full http(s) URL loads verbatim (other schemes are rejected so
//   file:/javascript: can't be loaded from the bar).
// - A bare host that looks like a domain (`example.com`,
//   `localhost:3000`) becomes an https:// URL — http:// for local
//   dev hosts, which listen on plain HTTP.
// - Anything else (free text, multiple words) becomes a web search.

import Foundation

enum BrowserURLResolver {
    /// `%@` is replaced with the percent-encoded query.
    static let searchTemplate = "https://www.google.com/search?q=%@"

    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let schemed = schemedURL(from: trimmed) { return schemed }
        if looksLikeHost(trimmed) {
            let scheme = isLocalHost(trimmed) ? "http" : "https"
            if let host = URL(string: "\(scheme)://\(trimmed)") { return host }
        }
        return searchURL(for: trimmed)
    }

    /// Query-string *value* encoding: `.urlQueryAllowed` leaves the
    /// separators `&=+?#` unescaped, which would split or reinterpret
    /// searches like "AT&T earnings" or "C++".
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()

    static func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? query
        return URL(string: searchTemplate.replacingOccurrences(of: "%@", with: encoded))
    }

    private static func schemedURL(from input: String) -> URL? {
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    /// Host-like: no spaces, and either `localhost` or a dotted token
    /// with non-empty labels around the last dot.
    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let host = bareHost(of: input)
        if host == "localhost" { return true }
        guard let lastDot = host.lastIndex(of: ".") else { return false }
        let afterDot = host[host.index(after: lastDot)...]
        let beforeDot = host[..<lastDot]
        return !afterDot.isEmpty && !beforeDot.isEmpty
    }

    /// Local dev hosts listen on plain HTTP: localhost, loopback, and
    /// private-LAN IPv4 ranges.
    private static func isLocalHost(_ input: String) -> Bool {
        let host = bareHost(of: input).lowercased()
        if host == "localhost" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { UInt8($0) }.map(Int.init)
        guard values.count == 4 else { return false }
        if values[0] == 127 || values[0] == 10 { return true }
        if values[0] == 192 && values[1] == 168 { return true }
        if values[0] == 172 && (16...31).contains(values[1]) { return true }
        return false
    }

    /// Bare host: no scheme, no port, no path.
    private static func bareHost(of input: String) -> String {
        let hostAndPort = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        return hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostAndPort
    }
}
