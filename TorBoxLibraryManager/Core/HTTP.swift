import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HTTP {
    /// WebDAV and TMDB: 30 s.
    static let standard: URLSession = makeSession(timeout: 30)
    /// Supabase: 60 s.
    static let supabase: URLSession = makeSession(timeout: 60)

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }

    static func send(_ request: URLRequest, session: URLSession = standard) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

struct HTTPStatusError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
    }
}

/// At most `limit` operations in flight (TMDB requests, WebDAV listings).
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        available = limit
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}

enum URLText {
    private static let unreservedASCII = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /// Python `urllib.parse.quote(text, safe=safe)` (UTF-8, ASCII-only unreserved set).
    static func quote(_ text: String, safe: String = "/") -> String {
        let allowed = CharacterSet(charactersIn: unreservedASCII + safe)
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Python `urllib.parse.unquote`.
    static func unquote(_ text: String) -> String {
        guard text.contains("%") else { return text }
        return text.removingPercentEncoding ?? text
    }

    /// The path of a URL or absolute path, like `urlparse(url).path`.
    static func path(of url: String) -> String {
        var value = url
        if let schemeEnd = value.range(of: "://") {
            let rest = value[schemeEnd.upperBound...]
            value = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
        } else if value.hasPrefix("//") {
            let rest = value.dropFirst(2)
            value = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
        }
        if let index = value.firstIndex(of: "#") { value = String(value[..<index]) }
        if let index = value.firstIndex(of: "?") { value = String(value[..<index]) }
        // urlparse splits ;params off the last path segment.
        let lastSlash = value.lastIndex(of: "/") ?? value.startIndex
        if let semicolon = value[lastSlash...].firstIndex(of: ";") { value = String(value[..<semicolon]) }
        return value
    }

    /// `scheme://host[:port]` of a URL string.
    static func origin(of url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            return url.trimmingTrailing("/")
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// Percent-encode a value for use inside another URL's query (`url=` parameters).
    static func queryValue(_ text: String) -> String {
        quote(text, safe: "")
    }
}
