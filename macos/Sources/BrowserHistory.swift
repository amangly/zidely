// Browser history with omnibar frecency, following cmux's
// BrowserHistoryFileRepository + BrowserHistorySuggestionEngine:
// visits and typed navigations accumulate per normalized URL in a
// JSON file, and the omnibar ranks matches by literal/prefix/substring
// hits on host, URL, path, and title blended with recency decay and
// log-scaled visit/typed counts.

import Foundation

struct BrowserHistoryEntry: Codable {
    var url: String
    var title: String?
    var lastVisited: Date
    var visitCount: Int
    var typedCount: Int
    var lastTypedAt: Date?
}

struct BrowserSuggestion {
    let title: String
    let url: String
}

final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()
    static let maxEntries = 4000

    /// Normalized-URL key → entry; the key dedups http/https visits
    /// the way cmux does (www./default port/trailing slash stripped).
    private var entries: [String: BrowserHistoryEntry] = [:]
    private let fileURL: URL
    private var saveScheduled = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zide", isDirectory: true)
            .appendingPathComponent("browser_history.json")
        load()
    }

    // MARK: Recording

    func recordVisit(url: URL, title: String?) {
        guard let key = Self.normalizedKey(url: url) else { return }
        var entry = entries[key] ?? BrowserHistoryEntry(
            url: url.absoluteString, title: nil, lastVisited: Date(),
            visitCount: 0, typedCount: 0, lastTypedAt: nil)
        entry.url = url.absoluteString
        entry.lastVisited = Date()
        entry.visitCount += 1
        if let title, !title.isEmpty { entry.title = title }
        entries[key] = entry
        scheduleSave()
    }

    /// The user typed (rather than clicked to) this URL — typed
    /// navigations dominate frecency, like a real omnibox.
    func recordTyped(url: URL) {
        guard let key = Self.normalizedKey(url: url) else { return }
        var entry = entries[key] ?? BrowserHistoryEntry(
            url: url.absoluteString, title: nil, lastVisited: Date(),
            visitCount: 0, typedCount: 0, lastTypedAt: nil)
        entry.typedCount += 1
        entry.lastTypedAt = Date()
        entries[key] = entry
        scheduleSave()
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let key = Self.normalizedKey(url: url),
              var entry = entries[key], entry.title != title else { return }
        entry.title = title
        entries[key] = entry
        scheduleSave()
    }

    // MARK: Suggestions

    func suggestions(for rawQuery: String, limit: Int = 6) -> [BrowserSuggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let tokens = Self.tokenize(query)
        let now = Date()
        return entries.values
            .compactMap { entry -> (Double, BrowserHistoryEntry)? in
                guard let score = Self.score(entry: entry, query: query, tokens: tokens, now: now)
                else { return nil }
                return (score, entry)
            }
            .sorted { $0.0 > $1.0 }
            .prefix(limit)
            .map { BrowserSuggestion(title: $0.1.title ?? "", url: $0.1.url) }
    }

    /// cmux's scoring: exact/prefix/substring weights on host, URL,
    /// path, and title, then a frecency blend. Single-character
    /// queries require a prefix match to avoid noise.
    static func score(entry: BrowserHistoryEntry, query: String, tokens: [String], now: Date) -> Double? {
        let urlLower = entry.url.lowercased()
        let urlSansScheme = strippingScheme(urlLower)
        let components = URLComponents(string: entry.url)
        let host = components?.host?.lowercased() ?? ""
        let path = (components?.percentEncodedPath ?? "").lowercased()
        let q = (components?.percentEncodedQuery ?? "").lowercased()
        let pathAndQuery = q.isEmpty ? path : "\(path)?\(q)"
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let queryIncludesScheme = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlMatch = queryIncludesScheme ? urlLower : urlSansScheme
        if query.count == 1 {
            guard host.hasPrefix(query) || title.hasPrefix(query) || urlMatch.hasPrefix(query)
            else { return nil }
        }

        let queryMatches = urlMatch.contains(query) || host.contains(query)
            || pathAndQuery.contains(query) || title.contains(query)
        let tokenMatches = !tokens.isEmpty && tokens.allSatisfy { token in
            urlSansScheme.contains(token) || host.contains(token)
                || pathAndQuery.contains(token) || title.contains(token)
        }
        guard queryMatches || tokenMatches else { return nil }

        var score = 0.0
        if urlMatch == query { score += 1200 }
        if host == query { score += 980 }
        if host.hasPrefix(query) { score += 680 }
        if urlMatch.hasPrefix(query) { score += 560 }
        if title.hasPrefix(query) { score += 420 }
        if pathAndQuery.hasPrefix(query) { score += 300 }
        if host.contains(query) { score += 210 }
        if pathAndQuery.contains(query) { score += 165 }
        if title.contains(query) { score += 145 }

        for token in tokens {
            if host == token { score += 260 } else if host.hasPrefix(token) { score += 170 } else if host.contains(token) { score += 110 }
            if pathAndQuery.hasPrefix(token) { score += 80 } else if pathAndQuery.contains(token) { score += 52 }
            if title.hasPrefix(token) { score += 74 } else if title.contains(token) { score += 48 }
        }

        let ageHours = max(0, now.timeIntervalSince(entry.lastVisited) / 3600)
        score += max(0, 110 - (ageHours / 3))
        score += min(120, log1p(Double(max(1, entry.visitCount))) * 38)
        score += min(190, log1p(Double(max(0, entry.typedCount))) * 80)
        if let lastTypedAt = entry.lastTypedAt {
            let typedAgeHours = max(0, now.timeIntervalSince(lastTypedAt) / 3600)
            score += max(0, 85 - (typedAgeHours / 4))
        }
        return score
    }

    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols)
        for raw in query.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    static func strippingScheme(_ value: String) -> String {
        if value.hasPrefix("https://") { return String(value.dropFirst(8)) }
        if value.hasPrefix("http://") { return String(value.dropFirst(7)) }
        return value
    }

    /// Visit-dedup key: scheme, host sans leading www., default port
    /// dropped, trailing-slash-normalized path, lowercased query.
    static func normalizedKey(url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased()
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var port = components.port
        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) { port = nil }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let queryPart = (components.percentEncodedQuery?.isEmpty == false)
            ? "?\(components.percentEncodedQuery!.lowercased())" : ""
        let portPart = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portPart)\(path)\(queryPart)"
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? decoder.decode([BrowserHistoryEntry].self, from: data)
        else { return }
        for entry in list {
            guard let url = URL(string: entry.url), let key = Self.normalizedKey(url: url)
            else { continue }
            entries[key] = entry
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    private func save() {
        var list = entries.values.sorted { $0.lastVisited > $1.lastVisited }
        if list.count > Self.maxEntries { list.removeLast(list.count - Self.maxEntries) }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
