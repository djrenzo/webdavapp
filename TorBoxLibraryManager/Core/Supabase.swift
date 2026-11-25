import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SupabaseConfig: Sendable, Equatable {
    let url: String
    let key: String
    let email: String
    let password: String

    var isComplete: Bool { !url.isEmpty && !key.isEmpty && !email.isEmpty && !password.isEmpty }

    /// `project_url`: keep only scheme://host when a URL with a path was pasted.
    static func projectURL(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value), let scheme = components.scheme, let host = components.host, !host.isEmpty {
            let port = components.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }
        return value.trimmingTrailing("/")
    }
}

struct SupabaseError: LocalizedError {
    let message: String
    let status: Int?

    var errorDescription: String? {
        if message.contains("schema cache") {
            return message + "\n\nThe database is missing a migration — run the files in supabase/migrations."
        }
        return message
    }
}

/// Minimal Supabase client (Auth + PostgREST), a port of torbox_supabase.py.
actor SupabaseClient {
    static let pageSize = 1000
    static let batchSize = 500

    private struct Session: Codable {
        let url: String
        let email: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
    }

    let config: SupabaseConfig
    private var session: Session?

    init(config: SupabaseConfig) {
        self.config = config
    }

    // MARK: Auth

    private func loadSession() -> Session? {
        guard let data = Secrets.supabaseSession(), let stored = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        guard stored.url == config.url, stored.email == config.email, !stored.accessToken.isEmpty else { return nil }
        return stored
    }

    private func storeSession(_ response: JSONObject) throws {
        guard let access = Py.text(response["access_token"]) else {
            throw SupabaseError(message: "Supabase login returned no access token", status: nil)
        }
        let expiresIn = Double(Py.int(response["expires_in"]) ?? 3600)
        let new = Session(
            url: config.url, email: config.email, accessToken: access,
            refreshToken: Py.text(response["refresh_token"]) ?? "",
            // Renew a minute early so a long push doesn't run into the expiry.
            expiresAt: Date().timeIntervalSince1970 + expiresIn - 60
        )
        session = new
        Secrets.setSupabaseSession(try? JSONEncoder().encode(new))
    }

    private func token(grantType: String, body: JSONObject) async throws {
        let url = "\(config.url)/auth/v1/token?grant_type=\(grantType)"
        let (_, _, response) = try await Self.http("POST", url, headers: ["apikey": config.key], body: .object(body))
        guard let object = response?.objectValue else {
            throw SupabaseError(message: "Supabase login returned no access token", status: nil)
        }
        try storeSession(object)
    }

    func login() async throws {
        do {
            try await token(grantType: "password", body: ["email": .string(config.email), "password": .string(config.password)])
        } catch let error as SupabaseError where error.status == 400 || error.status == 401 {
            throw SupabaseError(message: "Supabase login failed: \(error.message)", status: error.status)
        }
    }

    func signOut() {
        session = nil
        Secrets.setSupabaseSession(nil)
    }

    private func accessToken() async throws -> String {
        if session == nil { session = loadSession() }
        if let session, session.expiresAt > Date().timeIntervalSince1970 { return session.accessToken }
        if let refresh = session?.refreshToken, !refresh.isEmpty {
            do {
                try await token(grantType: "refresh_token", body: ["refresh_token": .string(refresh)])
                if let session { return session.accessToken }
            } catch {
                AppLog.write("Supabase: session refresh failed (\(error.localizedDescription)), logging in again")
            }
        }
        try await login()
        guard let session else { throw SupabaseError(message: "Supabase login failed", status: nil) }
        return session.accessToken
    }

    // MARK: REST

    private func rest(_ method: String, _ path: String, params: [(String, String)] = [], body: JSONValue? = nil,
                      prefer: String? = nil, retryAuth: Bool = true) async throws -> (Int, HTTPURLResponse, JSONValue?) {
        var url = "\(config.url)/rest/v1/\(path)"
        if !params.isEmpty {
            url += "?" + params.map { "\(URLText.quote($0.0, safe: ""))=\(URLText.quote($0.1, safe: ",.:()*"))" }.joined(separator: "&")
        }
        var headers = [
            "apikey": config.key,
            "Authorization": "Bearer \(try await accessToken())",
            "Accept": "application/json",
        ]
        if let prefer { headers["Prefer"] = prefer }
        do {
            return try await Self.http(method, url, headers: headers, body: body)
        } catch let error as SupabaseError where error.status == 401 && retryAuth {
            session = nil
            try await login()
            return try await rest(method, path, params: params, body: body, prefer: prefer, retryAuth: false)
        }
    }

    func rpc(_ function: String, _ args: JSONObject = [:]) async throws -> JSONValue? {
        try await rest("POST", "rpc/\(function)", body: .object(args)).2
    }

    func isMember() async throws -> Bool { try await rpc("is_member")?.boolValue == true }
    func isAdmin() async throws -> Bool { try await rpc("is_admin")?.boolValue == true }

    /// Every matching row, paged 1000 at a time (order must be a unique column).
    func selectAll(_ table: String, select: String, order: String, filters: [(String, String)] = []) async throws -> [JSONObject] {
        var rows: [JSONObject] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let params = filters + [("select", select), ("order", "\(order).asc"), ("limit", "\(Self.pageSize)"), ("offset", "\(offset)")]
            let page = try await rest("GET", table, params: params).2?.arrayValue ?? []
            rows += page.compactMap(\.objectValue)
            if page.count < Self.pageSize { return rows }
            offset += Self.pageSize
        }
    }

    func select(_ table: String, select: String, filters: [(String, String)]) async throws -> [JSONObject] {
        let params = filters + [("select", select)]
        return (try await rest("GET", table, params: params).2?.arrayValue ?? []).compactMap(\.objectValue)
    }

    func insert(_ table: String, row: JSONObject, returning: String = "*") async throws -> JSONObject {
        let result = try await rest("POST", table, params: [("select", returning)], body: .array([.object(row)]), prefer: "return=representation").2
        guard let first = result?.arrayValue?.first?.objectValue else {
            throw SupabaseError(message: "Supabase returned no row for \(table)", status: nil)
        }
        return first
    }

    func update(_ table: String, values: JSONObject, filters: [(String, String)]) async throws {
        _ = try await rest("PATCH", table, params: filters, body: .object(values), prefer: "return=minimal")
    }

    /// Insert or update in batches of 500, grouped by key set, duplicates on the conflict
    /// columns collapsed (last wins).
    @discardableResult
    func upsert(_ table: String, rows: [JSONObject], onConflict: String, returning: String? = nil) async throws -> [JSONObject] {
        let columns = onConflict.split(separator: ",").map(String.init)
        var order: [[JSONValue]] = []
        var unique: [[JSONValue]: JSONObject] = [:]
        for row in rows {
            let key = columns.map { row[$0] ?? .null }
            if unique[key] == nil { order.append(key) }
            unique[key] = row
        }
        var groups: [[String]: [JSONObject]] = [:]
        var groupOrder: [[String]] = []
        for key in order {
            let row = unique[key]!
            let keySet = row.keys.sorted()
            if groups[keySet] == nil { groupOrder.append(keySet) }
            groups[keySet, default: []].append(row)
        }
        var returned: [JSONObject] = []
        for keySet in groupOrder {
            let group = groups[keySet]!
            for start in stride(from: 0, to: group.count, by: Self.batchSize) {
                try Task.checkCancellation()
                var params = [("on_conflict", onConflict)]
                if let returning { params.append(("select", returning)) }
                let prefer = "resolution=merge-duplicates,return=\(returning == nil ? "minimal" : "representation")"
                let batch = Array(group[start..<min(start + Self.batchSize, group.count)])
                let result = try await rest("POST", table, params: params, body: .array(batch.map { .object($0) }), prefer: prefer).2
                if returning != nil { returned += (result?.arrayValue ?? []).compactMap(\.objectValue) }
            }
        }
        return returned
    }

    /// Delete matching rows; returns how many were removed.
    func delete(_ table: String, filters: [(String, String)]) async throws -> Int {
        guard !filters.isEmpty else { throw SupabaseError(message: "Refusing to delete without a filter", status: nil) }
        let (_, response, _) = try await rest("DELETE", table, params: filters, prefer: "return=minimal,count=exact")
        let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
        return Int(range.split(separator: "/").last ?? "") ?? 0
    }

    // MARK: HTTP

    private static func http(_ method: String, _ urlString: String, headers: [String: String], body: JSONValue?) async throws -> (Int, HTTPURLResponse, JSONValue?) {
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "Invalid Supabase URL", status: nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try JSONCoding.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await HTTP.send(request, session: HTTP.supabase)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SupabaseError(message: "Cannot reach Supabase: \(error.localizedDescription)", status: nil)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SupabaseError(message: errorMessage(data, fallback: "HTTP \(response.statusCode)"), status: response.statusCode)
        }
        let trimmed = data.filter { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        let parsed = trimmed.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        return (response.statusCode, response, parsed)
    }

    private static func errorMessage(_ data: Data, fallback: String) -> String {
        guard let body = try? JSONCoding.decodeObject(data) else { return fallback }
        var parts: [String] = []
        for key in ["msg", "message", "error_description", "error", "details", "hint"] {
            if let text = Py.text(body[key]), !parts.contains(text) { parts.append(text) }
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " - ")
    }
}
