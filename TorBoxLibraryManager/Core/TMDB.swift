import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TMDBError: LocalizedError {
    case missingToken
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Add a TMDB read access token in Settings first."
        case .notFound(let what): return "TMDB has no \(what)."
        }
    }
}

/// TMDB v3 API with a v4 read access token. At most 4 requests in flight; HTTP 429 waits
/// for Retry-After (§11).
struct TMDBClient: Sendable {
    static let api = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p/"
    private static let limiter = AsyncLimiter(4)

    let token: String

    init(token: String) {
        self.token = token
    }

    static func fromKeychain() throws -> TMDBClient {
        guard let token = Secrets.tmdbToken(), !token.isEmpty else { throw TMDBError.missingToken }
        return TMDBClient(token: token)
    }

    static func image(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return imageBase + size + path
    }

    func get(_ path: String, _ params: [String: String] = [:]) async throws -> JSONObject {
        var components = URLComponents(string: Self.api + path)!
        if !params.isEmpty {
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves '+' alone, which servers read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let finalRequest = request
        return try await Self.limiter.run {
            let request = finalRequest
            var attempt = 0
            while true {
                attempt += 1
                let (data, response) = try await HTTP.send(request)
                if response.statusCode == 429 || (500..<600).contains(response.statusCode), attempt < 4 {
                    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0.75 * pow(2, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    let object = try? JSONCoding.decodeObject(data)
                    let message = Py.text(object?["status_message"]) ?? ""
                    throw HTTPStatusError(status: response.statusCode, message: message)
                }
                return try JSONCoding.decodeObject(data)
            }
        }
    }

    /// Token check for Settings.
    func test() async throws {
        _ = try await get("/authentication")
    }

    func search(type: String, query: String, year: Int?) async throws -> [JSONObject] {
        let path = type == "tvshow" ? "/search/tv" : "/search/movie"
        var params = ["query": query, "include_adult": "false"]
        if let year { params[type == "tvshow" ? "first_air_date_year" : "year"] = String(year) }
        var results = try await get(path, params)["results"]?.arrayValue ?? []
        if results.isEmpty && year != nil {
            params.removeValue(forKey: "first_air_date_year")
            params.removeValue(forKey: "year")
            results = try await get(path, params)["results"]?.arrayValue ?? []
        }
        return results.prefix(10).compactMap(\.objectValue)
    }

    func externalIDs(type: String, id: String) async throws -> JSONObject {
        try await get("/\(type == "tvshow" ? "tv" : "movie")/\(id)/external_ids")
    }

    /// `_fetch_tmdb`: details plus the episodes of the given seasons (19 seasons per request).
    func details(type: String, id: String, seasons: Set<Int>) async throws -> (details: JSONObject, episodes: [Int: [JSONObject]]) {
        let kind = type == "tvshow" ? "tv" : "movie"
        let wanted = type == "tvshow" ? seasons.sorted() : []
        var chunks = stride(from: 0, to: wanted.count, by: 19).map { Array(wanted[$0..<min($0 + 19, wanted.count)]) }
        if chunks.isEmpty { chunks = [[]] }
        var details: JSONObject?
        var episodes: [Int: [JSONObject]] = [:]
        for chunk in chunks {
            let append = (["external_ids"] + chunk.map { "season/\($0)" }).joined(separator: ",")
            let data = try await get("/\(kind)/\(id)", ["append_to_response": append])
            guard Py.truthy(data["id"]) else { throw TMDBError.notFound("\(kind) \(id)") }
            if details == nil { details = data }
            for season in chunk {
                if let list = data["season/\(season)"]?.objectValue?["episodes"]?.arrayValue {
                    episodes[season] = list.compactMap(\.objectValue)
                }
            }
        }
        return (details ?? [:], episodes)
    }
}
