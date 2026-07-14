// Real download handling, following cmux's download delegate +
// BrowserDownloadFilenameResolver: navigation responses the engine
// can't render (and attachment/archive responses it could) become
// WKDownloads saved to ~/Downloads with collision-safe names and a
// proper web-download quarantine attribute.

import AppKit
import Foundation
import WebKit

/// MIME types that download even though WebKit could display them
/// inline as text (cmux's forceDownloadMIMETypes).
private let forceDownloadMIMETypes: Set<String> = [
    "application/gzip",
    "application/octet-stream",
    "application/x-gzip",
    "application/x-zip-compressed",
    "application/zip",
    "text/csv",
]

enum BrowserDownloadPolicy {
    /// Should this navigation response become a download instead of a
    /// page? Content-Disposition: attachment always wins; then the
    /// force-download MIMEs; then anything the engine can't show.
    static func shouldDownload(
        mimeType: String?,
        canShowMIMEType: Bool,
        contentDisposition: String?,
        isForMainFrame: Bool
    ) -> Bool {
        if let disposition = contentDisposition?.split(separator: ";", maxSplits: 1).first,
           disposition.trimmingCharacters(in: .whitespacesAndNewlines)
           .caseInsensitiveCompare("attachment") == .orderedSame {
            return true
        }
        if let raw = mimeType?.split(separator: ";", maxSplits: 1).first {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if forceDownloadMIMETypes.contains(normalized) { return true }
        }
        guard isForMainFrame else { return false }
        return !canShowMIMEType
    }
}

final class BrowserDownloadManager: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloadManager()

    /// Progress/completion sink — the shell shows these in the status
    /// strip and notification panel.
    var onEvent: ((_ filename: String, _ message: String, _ finishedFile: URL?) -> Void)?

    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            onEvent?(suggestedFilename, "download failed — HTTP \(http.statusCode)", nil)
            completionHandler(nil)
            return
        }
        let directory = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destination = Self.uniqueDestination(
            filename: Self.sanitized(suggestedFilename, fallbackURL: response.url),
            in: directory)
        destinations[ObjectIdentifier(download)] = destination
        onEvent?(destination.lastPathComponent, "downloading…", nil)
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = destinations.removeValue(forKey: ObjectIdentifier(download))
        else { return }
        try? Self.applyQuarantine(to: destination, source: download.originalRequest?.url)
        onEvent?(destination.lastPathComponent, "downloaded to Downloads", destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let destination = destinations.removeValue(forKey: ObjectIdentifier(download))
        let name = destination?.lastPathComponent ?? "download"
        if let destination { try? FileManager.default.removeItem(at: destination) }
        onEvent?(name, "download failed — \(error.localizedDescription)", nil)
    }

    /// Redirect-to-download chains keep the delegate.
    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    // MARK: Filenames (cmux's resolver, minus image-type sniffing)

    static func sanitized(_ raw: String, fallbackURL: URL?) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed as NSString).lastPathComponent
        let base = candidate.isEmpty ? (fallbackURL?.lastPathComponent ?? "") : candidate
        let safe = base.replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "download" : safe
    }

    static func uniqueDestination(filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(filename, isDirectory: false)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = filename as NSString
        let base = ns.deletingPathExtension.isEmpty ? "download" : ns.deletingPathExtension
        let ext = ns.pathExtension
        for index in 1...100 {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        let name = ext.isEmpty ? "\(base)-\(UUID().uuidString)" : "\(base)-\(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Gatekeeper quarantine, like every real browser: downloads carry
    /// where they came from and open with the usual warning.
    static func applyQuarantine(to fileURL: URL, source: URL?) throws {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
            kLSQuarantineAgentNameKey as String: "zide",
        ]
        if let source, let scheme = source.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           var components = URLComponents(url: source, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            if let sanitizedSource = components.url {
                properties[kLSQuarantineDataURLKey as String] = sanitizedSource
                properties[kLSQuarantineOriginURLKey as String] = sanitizedSource
            }
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = fileURL
        try url.setResourceValues(values)
    }
}
