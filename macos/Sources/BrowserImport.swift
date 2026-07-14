// Import cookies from the user's other installed browsers so zide's
// browser opens already signed in — the standard "import from another
// browser" feature (cmux ships one too). Everything stays on this
// machine: cookies are read from the source browser's own store and
// injected into zide's local WKWebView cookie store, never sent
// anywhere.
//
// Chromium family (Chrome, Arc, Brave, Edge…): cookies are AES-128-CBC
// encrypted in a SQLite DB; the key derives from a random password in
// the login Keychain ("<Browser> Safe Storage"). Reading that Keychain
// item triggers the standard macOS authorization prompt — the user's
// consent step. Safari is deliberately unsupported: its cookies are
// TCC-protected and unreadable without Full Disk Access.

import CommonCrypto
import Foundation
import Security
import SQLite3
import WebKit

struct ImportableBrowser {
    let id: String
    let displayName: String
    /// The login-Keychain generic-password service that holds the AES key.
    let keychainService: String
    /// Candidate Cookies SQLite paths under the data root (newer Chromium
    /// moved it under Network/).
    let cookiePaths: [URL]

    var cookieDatabase: URL? {
        cookiePaths.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum BrowserImport {
    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Chromium browsers whose cookie DB exists on this machine.
    static func detectChromium() -> [ImportableBrowser] {
        let table: [(id: String, name: String, service: String, root: String)] = [
            ("chrome", "Google Chrome", "Chrome Safe Storage", "Google/Chrome"),
            ("arc", "Arc", "Arc Safe Storage", "Arc/User Data"),
            ("brave", "Brave", "Brave Safe Storage", "BraveSoftware/Brave-Browser"),
            ("edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("vivaldi", "Vivaldi", "Vivaldi Safe Storage", "Vivaldi"),
            ("chromium", "Chromium", "Chromium Safe Storage", "Chromium"),
        ]
        return table.compactMap { entry in
            let base = appSupport.appendingPathComponent(entry.root)
            let candidates = [
                base.appendingPathComponent("Default/Network/Cookies"),
                base.appendingPathComponent("Default/Cookies"),
            ]
            let browser = ImportableBrowser(
                id: entry.id, displayName: entry.name,
                keychainService: entry.service, cookiePaths: candidates)
            return browser.cookieDatabase != nil ? browser : nil
        }
    }

    enum ImportError: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case keyDerivationFailed
        case noCookieDatabase
        case databaseOpenFailed
        case noCookies

        var description: String {
            switch self {
            case let .keychain(status):
                let sys = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                switch status {
                case errSecUserCanceled, errSecAuthFailed:
                    return "you denied the Keychain prompt — run it again and choose \u{201C}Allow\u{201D} (or \u{201C}Always Allow\u{201D}) when macOS asks for the browser's \u{201C}Safe Storage\u{201D} key (status \(status))"
                case errSecItemNotFound:
                    return "the browser's encryption key wasn't found in your Keychain (status \(status)) — is this the browser you actually use?"
                default:
                    return "Keychain read failed: \(sys) (status \(status))"
                }
            case .keyDerivationFailed: return "could not derive the decryption key"
            case .noCookieDatabase: return "no cookie database found"
            case .databaseOpenFailed: return "could not read the cookie database"
            case .noCookies: return "no cookies found"
            }
        }
    }

    /// Read + decrypt the browser's cookies off the main thread, then
    /// inject them into zide's shared cookie store on the main thread.
    /// `completion` reports how many cookies landed, or an error.
    static func importCookies(
        from browser: ImportableBrowser,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[HTTPCookie], Error>
            do {
                let key = try deriveKey(service: browser.keychainService)
                let cookies = try readCookies(from: browser, key: key)
                result = .success(cookies)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case let .failure(error):
                    completion(.failure(error))
                case let .success(cookies):
                    guard !cookies.isEmpty else {
                        completion(.failure(ImportError.noCookies))
                        return
                    }
                    inject(cookies, completion: completion)
                }
            }
        }
    }

    private static func inject(
        _ cookies: [HTTPCookie],
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { completion(.success(cookies.count)) }
    }

    // MARK: Chromium key derivation

    /// The AES key = PBKDF2-HMAC-SHA1(keychainPassword, "saltysalt",
    /// 1003 iterations, 16 bytes) — Chromium's fixed macOS parameters.
    private static func deriveKey(service: String) throws -> [UInt8] {
        let password = try keychainPassword(service: service)
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: 16)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &derived, derived.count)
        }
        guard status == kCCSuccess else { throw ImportError.keyDerivationFailed }
        return derived
    }

    private static func keychainPassword(service: String) throws -> Data {
        // The legacy Keychain API prompts more reliably for cross-app
        // reads of another app's ACL-restricted item (the modern
        // SecItemCopyMatching can silently return errSecItemNotFound
        // instead of showing the authorization dialog for an unsigned
        // caller).
        var length: UInt32 = 0
        var bytes: UnsafeMutableRawPointer?
        let status = SecKeychainFindGenericPassword(
            nil,
            UInt32(service.utf8.count), service,
            0, nil,
            &length, &bytes, nil)
        guard status == errSecSuccess, let bytes else {
            throw ImportError.keychain(status)
        }
        defer { SecKeychainItemFreeContent(nil, bytes) }
        return Data(bytes: bytes, count: Int(length))
    }

    // MARK: Cookie DB read + decrypt

    private static func readCookies(from browser: ImportableBrowser, key: [UInt8]) throws -> [HTTPCookie] {
        guard let source = browser.cookieDatabase else { throw ImportError.noCookieDatabase }
        // The live browser holds a WAL lock; work on a private copy.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zide-import-\(browser.id)-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: source, to: temp)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: temp.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ImportError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT host_key, name, encrypted_value, path, expires_utc, is_secure, samesite
        FROM cookies
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.databaseOpenFailed
        }
        defer { sqlite3_finalize(stmt) }

        var cookies: [HTTPCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let host = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) })
            else { continue }
            let encBytes = sqlite3_column_bytes(stmt, 2)
            guard encBytes > 0, let encPtr = sqlite3_column_blob(stmt, 2) else { continue }
            let encrypted = Data(bytes: encPtr, count: Int(encBytes))
            guard let value = decrypt(encrypted, key: key) else { continue }
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "/"
            let expiresUtc = sqlite3_column_int64(stmt, 4)
            let isSecure = sqlite3_column_int(stmt, 5) != 0
            let sameSite = sqlite3_column_int(stmt, 6)

            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: path.isEmpty ? "/" : path,
            ]
            if isSecure { props[.secure] = "TRUE" }
            if expiresUtc > 0 { props[.expires] = chromeTimeToDate(expiresUtc) }
            // 0 none, 1 lax, 2 strict; -1 unspecified.
            switch sameSite {
            case 1: props[.sameSitePolicy] = "lax"
            case 2: props[.sameSitePolicy] = "strict"
            default: break
            }
            if let cookie = HTTPCookie(properties: props) { cookies.append(cookie) }
        }
        return cookies
    }

    /// Chromium timestamps: microseconds since 1601-01-01 UTC.
    private static func chromeTimeToDate(_ value: Int64) -> Date {
        let unixSeconds = Double(value) / 1_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: unixSeconds)
    }

    /// Decrypt one `encrypted_value`. macOS Chromium: "v10" prefix, then
    /// AES-128-CBC (IV = 16 spaces). Chrome M130+ prepends a 32-byte
    /// SHA-256 domain hash to the plaintext, so prefer the interpretation
    /// that yields valid UTF-8 after stripping it.
    private static func decrypt(_ blob: Data, key: [UInt8]) -> String? {
        guard blob.count > 3 else {
            // Unencrypted (rare, older): decode as-is.
            return String(data: blob, encoding: .utf8)
        }
        let prefix = blob.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else {
            return String(data: blob, encoding: .utf8)
        }
        let ciphertext = blob.dropFirst(3)
        guard ciphertext.count % 16 == 0, !ciphertext.isEmpty else { return nil }

        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = ciphertext.withUnsafeBytes { ct in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv,
                ct.baseAddress, ciphertext.count,
                &out, out.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        let plain = Data(out.prefix(moved))
        if plain.count > 32, let stripped = String(data: plain.dropFirst(32), encoding: .utf8) {
            return stripped
        }
        return String(data: plain, encoding: .utf8)
    }
}
