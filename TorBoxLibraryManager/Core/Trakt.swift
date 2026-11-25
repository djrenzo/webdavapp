import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TraktError: LocalizedError {
    case notConfigured
    case notConnected
    case denied
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Trakt app’s Client ID in Settings first."
        case .notConnected: return "Connect Trakt in Settings first."
        case .denied: return "Access was denied on trakt.tv."
        case .status(let code, let message):
            if code == 401 || code == 403 { return "Trakt refused the request (\(code)). Connect Trakt again in Settings." }
            return message.isEmpty ? "Trakt returned HTTP \(code)." : "Trakt returned HTTP \(code): \(message)"
        }
    }
}

struct TraktToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    init(_ object: JSONObject) throws {
        guard let access = Py.text(object["access_token"]), let refresh = Py.text(object["refresh_token"]) else {
            throw TraktError.status(200, "No token in the response")
        }
        accessToken = access
        refreshToken = refresh
        let created = object["created_at"]?.pythonDouble.map { Date(timeIntervalSince1970: $0) } ?? Date()
        expiresAt = created.addingTimeInterval(object["expires_in"]?.pythonDouble ?? 86_400 * 90)
    }

    static func load() -> TraktToken? {
        guard let data = Secrets.traktToken() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TraktToken.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        Secrets.setTraktToken(try? encoder.encode(self))
    }
}

/// PKCE (RFC 7636) for the authorization code flow: only the Client ID is needed.
struct TraktPKCE: Sendable {
    let verifier: String
    let challenge: String
    let state: String

    static func make() -> TraktPKCE {
        let verifier = randomString(64)
        return TraktPKCE(verifier: verifier, challenge: challenge(for: verifier), state: randomString(24))
    }

    /// BASE64URL(SHA256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(Array(verifier.utf8)))
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }
}

/// Plain SHA-256 (FIPS 180-4), so the PKCE challenge also works in the Linux tests.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                w[i] = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[chunk + i * 4 + $1]) }
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let t1 = hh &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
        }
        return h.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - $0 * 8)) } }
    }
}

/// Ids as Trakt reports them; tmdb is what the library matches on, imdb the fallback.
struct TraktIDs: Codable, Sendable, Hashable {
    var trakt: Int?
    var tmdb: Int?
    var imdb: String?

    init(trakt: Int? = nil, tmdb: Int? = nil, imdb: String? = nil) {
        self.trakt = trakt
        self.tmdb = tmdb
        self.imdb = imdb
    }

    init(_ object: JSONObject?) {
        trakt = Py.int(object?["trakt"])
        tmdb = Py.int(object?["tmdb"])
        imdb = Py.text(object?["imdb"])
    }

    /// For POST bodies: only the ids that are known.
    var json: JSONValue {
        var object: JSONObject = [:]
        if let trakt { object["trakt"] = .int(trakt) }
        if let tmdb { object["tmdb"] = .int(tmdb) }
        if let imdb { object["imdb"] = .string(imdb) }
        return .object(object)
    }

    func matches(tmdbID: String?, imdbID: String?) -> Bool {
        if let tmdb, let tmdbID, String(tmdb) == tmdbID { return true }
        if let imdb, let imdbID, imdb.lowercased() == imdbID.lowercased() { return true }
        return false
    }
}

struct TraktWatchedMovie: Codable, Sendable {
    var ids: TraktIDs
    var title: String
    var plays: Int
    var lastWatchedAt: Date?
}

struct TraktWatchedEpisode: Codable, Sendable {
    var key: EpisodeKey
    var lastWatchedAt: Date?
}

struct TraktWatchedShow: Codable, Sendable {
    var ids: TraktIDs
    var title: String
    var lastWatchedAt: Date?
    var episodes: [TraktWatchedEpisode]

    var watchedKeys: Set<EpisodeKey> { Set(episodes.map(\.key)) }

    /// The episode watched most recently (the highest one on equal times), specials left out.
    var lastEpisode: TraktWatchedEpisode? {
        episodes.filter { $0.key.season > 0 }.max { lhs, rhs in
            let lhsDate = lhs.lastWatchedAt ?? .distantPast, rhsDate = rhs.lastWatchedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.key < rhs.key
        }
    }
}

/// A paused movie or episode (`/sync/playback`).
struct TraktPlayback: Codable, Sendable, Identifiable {
    var id: Int
    var progress: Double
    var pausedAt: Date?
    var isMovie: Bool
    /// Movie ids, or the show's ids for an episode.
    var ids: TraktIDs
    var title: String
    var episode: EpisodeKey?
    var episodeTitle: String?
}

struct TraktState: Codable, Sendable {
    var username: String?
    var movies: [TraktWatchedMovie] = []
    var shows: [TraktWatchedShow] = []
    var playback: [TraktPlayback] = []
    var syncedAt: Date?

    static let fileName = "trakt.json"

    func movie(tmdbID: String?, imdbID: String?) -> TraktWatchedMovie? {
        movies.first { $0.ids.matches(tmdbID: tmdbID, imdbID: imdbID) }
    }

    func show(tmdbID: String?, imdbID: String?) -> TraktWatchedShow? {
        shows.first { $0.ids.matches(tmdbID: tmdbID, imdbID: imdbID) }
    }
}

/// Trakt API v2. Sign-in is the authorization code flow with PKCE, so the user's own API
/// app (trakt.tv/oauth/applications) only needs to provide a Client ID. Tokens live in the Keychain.
actor TraktClient {
    static let api = "https://api.trakt.tv"
    static let authorizeURL = "https://trakt.tv/oauth/authorize"
    /// Must be listed as a Redirect URI in the Trakt app.
    static let redirectURI = "webdavify://trakt"
    static let callbackScheme = "webdavify"

    let clientID: String

    init(clientID: String) {
        self.clientID = clientID
    }

    static func configured() -> TraktClient? {
        let id = UserDefaults.standard.string(forKey: "trakt.clientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : TraktClient(clientID: id)
    }

    // MARK: Sign-in (authorization code + PKCE)

    /// The trakt.tv page the user signs in on; it redirects to `redirectURI?code=…&state=…`.
    nonisolated func authorizationURL(_ pkce: TraktPKCE) -> URL {
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Read the redirect, check its state and trade the code for a token. Saves the token.
    func finishSignIn(callback: URL, pkce: TraktPKCE) async throws -> TraktToken {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? TraktError.denied : TraktError.status(400, value("error_description") ?? error)
        }
        guard value("state") == pkce.state, let code = value("code") else {
            throw TraktError.status(400, "The sign-in reply didn’t match. Try again.")
        }
        let (data, response) = try await raw("POST", "/oauth/token", body: [
            "code": .string(code), "client_id": .string(clientID), "redirect_uri": .string(Self.redirectURI),
            "grant_type": "authorization_code", "code_verifier": .string(pkce.verifier),
        ], token: nil)
        guard response.statusCode == 200 else {
            let object = try? JSONCoding.decodeObject(data)
            throw TraktError.status(response.statusCode, Py.text(object?["error_description"]) ?? Py.text(object?["error"]) ?? "")
        }
        let token = try TraktToken(JSONCoding.decodeObject(data))
        token.save()
        return token
    }

    func revoke() async {
        guard let token = TraktToken.load() else { return }
        _ = try? await raw("POST", "/oauth/revoke", body: [
            "token": .string(token.accessToken), "client_id": .string(clientID),
        ], token: nil)
        Secrets.setTraktToken(nil)
    }

    private func validToken() async throws -> TraktToken {
        guard var token = TraktToken.load() else { throw TraktError.notConnected }
        if token.expiresAt.timeIntervalSinceNow < 86_400 {
            token = try await refresh(token)
        }
        return token
    }

    private func refresh(_ token: TraktToken) async throws -> TraktToken {
        let (data, response) = try await raw("POST", "/oauth/token", body: [
            "refresh_token": .string(token.refreshToken), "client_id": .string(clientID),
            "redirect_uri": .string(Self.redirectURI),
            "grant_type": "refresh_token",
        ], token: nil)
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 { Secrets.setTraktToken(nil) }
            throw TraktError.status(response.statusCode, "Couldn’t refresh the Trakt login")
        }
        let fresh = try TraktToken(JSONCoding.decodeObject(data))
        fresh.save()
        return fresh
    }

    // MARK: Requests

    private func raw(_ method: String, _ path: String, body: JSONObject?, token: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: Self.api + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(OpenSubtitlesClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONCoding.encode(.object(body)) }
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await HTTP.send(request)
            if response.statusCode == 429, attempt < 4 {
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                continue
            }
            return (data, response)
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: JSONObject? = nil, auth: Bool = true) async throws -> JSONObject {
        let value = try await sendValue(method, path, body: body, auth: auth)
        return value.objectValue ?? [:]
    }

    private func sendValue(_ method: String, _ path: String, body: JSONObject? = nil, auth: Bool = true) async throws -> JSONValue {
        var token = auth ? try await validToken() : nil
        var (data, response) = try await raw(method, path, body: body, token: token?.accessToken)
        if response.statusCode == 401, let current = token {
            token = try await refresh(current)
            (data, response) = try await raw(method, path, body: body, token: token?.accessToken)
        }
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONCoding.decodeObject(data)
            throw TraktError.status(response.statusCode, Py.text(object?["error_description"]) ?? Py.text(object?["error"]) ?? "")
        }
        guard !data.isEmpty else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: Sync

    func sync() async throws -> TraktState {
        async let settings = sendValue("GET", "/users/settings")
        async let movies = sendValue("GET", "/sync/watched/movies")
        async let shows = sendValue("GET", "/sync/watched/shows")
        async let playback = sendValue("GET", "/sync/playback")
        return try await TraktParser.state(
            settings: settings.objectValue ?? [:], movies: movies.arrayValue ?? [],
            shows: shows.arrayValue ?? [], playback: playback.arrayValue ?? []
        )
    }

    /// POST /sync/history (or /remove) with `{"movies": [...], "shows": [...]}`.
    func history(_ body: JSONObject, remove: Bool) async throws {
        try await send("POST", remove ? "/sync/history/remove" : "/sync/history", body: body)
    }

    func removePlayback(_ id: Int) async throws {
        _ = try await sendValue("DELETE", "/sync/playback/\(id)")
    }
}

/// Pure parsing and request-body building, checked by the core tests.
enum TraktParser {
    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func state(settings: JSONObject, movies: [JSONValue], shows: [JSONValue], playback: [JSONValue]) -> TraktState {
        var state = TraktState()
        state.username = Py.text(settings["user"]?.objectValue?["username"])
        state.movies = movies.compactMap { value in
            guard let item = value.objectValue, let movie = item["movie"]?.objectValue else { return nil }
            return TraktWatchedMovie(
                ids: TraktIDs(movie["ids"]?.objectValue), title: Py.text(movie["title"]) ?? "",
                plays: Py.int(item["plays"]) ?? 1, lastWatchedAt: date(item["last_watched_at"])
            )
        }
        state.shows = shows.compactMap { value in
            guard let item = value.objectValue, let show = item["show"]?.objectValue else { return nil }
            var episodes: [TraktWatchedEpisode] = []
            for season in item["seasons"]?.arrayValue ?? [] {
                guard let season = season.objectValue, let number = Py.int(season["number"]) else { continue }
                for episode in season["episodes"]?.arrayValue ?? [] {
                    guard let episode = episode.objectValue, let episodeNumber = Py.int(episode["number"]) else { continue }
                    episodes.append(TraktWatchedEpisode(
                        key: EpisodeKey(season: number, episode: episodeNumber), lastWatchedAt: date(episode["last_watched_at"])
                    ))
                }
            }
            return TraktWatchedShow(
                ids: TraktIDs(show["ids"]?.objectValue), title: Py.text(show["title"]) ?? "",
                lastWatchedAt: date(item["last_watched_at"]), episodes: episodes
            )
        }
        state.playback = playback.compactMap { value in
            guard let item = value.objectValue, let id = Py.int(item["id"]) else { return nil }
            let progress = item["progress"]?.pythonDouble ?? 0
            if item["type"]?.stringValue == "movie", let movie = item["movie"]?.objectValue {
                return TraktPlayback(
                    id: id, progress: progress, pausedAt: date(item["paused_at"]), isMovie: true,
                    ids: TraktIDs(movie["ids"]?.objectValue), title: Py.text(movie["title"]) ?? "", episode: nil, episodeTitle: nil
                )
            }
            guard let show = item["show"]?.objectValue, let episode = item["episode"]?.objectValue,
                  let season = Py.int(episode["season"]), let number = Py.int(episode["number"]) else { return nil }
            return TraktPlayback(
                id: id, progress: progress, pausedAt: date(item["paused_at"]), isMovie: false,
                ids: TraktIDs(show["ids"]?.objectValue), title: Py.text(show["title"]) ?? "",
                episode: EpisodeKey(season: season, episode: number), episodeTitle: Py.text(episode["title"])
            )
        }.sorted { ($0.pausedAt ?? .distantPast) > ($1.pausedAt ?? .distantPast) }
        state.syncedAt = Date()
        return state
    }

    static func movieBody(_ ids: TraktIDs) -> JSONObject {
        ["movies": .array([.object(["ids": ids.json])])]
    }

    /// Whole show (episodes nil), whole seasons (episodes empty) or single episodes.
    static func showBody(_ ids: TraktIDs, episodes: [EpisodeKey]?, seasons: [Int] = []) -> JSONObject {
        var show: JSONObject = ["ids": ids.json]
        if let episodes {
            var bySeason: [Int: [Int]] = [:]
            for key in episodes { bySeason[key.season, default: []].append(key.episode) }
            var list: [JSONValue] = seasons.sorted().map { .object(["number": .int($0)]) }
            for season in bySeason.keys.sorted() where !seasons.contains(season) {
                list.append(.object([
                    "number": .int(season),
                    "episodes": .array(bySeason[season]!.sorted().map { .object(["number": .int($0)]) }),
                ]))
            }
            show["seasons"] = .array(list)
        }
        return ["shows": .array([.object(show)])]
    }
}

/// "Keep going": the next episode after the last one watched.
enum UpNext {
    struct Pick: Sendable, Equatable {
        let next: EpisodeKey
        let last: EpisodeKey
        let inLibrary: Bool
    }

    /// `order`: the show's episodes in order (aired ones when known, else the library's).
    /// Episodes already watched are skipped; nil when nothing after the last watched remains.
    static func pick(watched: TraktWatchedShow, order: [EpisodeKey], present: Set<EpisodeKey>) -> Pick? {
        guard let last = watched.lastEpisode?.key else { return nil }
        let seen = watched.watchedKeys
        let sequence = Array(Set(order).union(present)).filter { $0.season > 0 }.sorted()
        guard let next = sequence.first(where: { $0 > last && !seen.contains($0) }) else { return nil }
        return Pick(next: next, last: last, inLibrary: present.contains(next))
    }
}
