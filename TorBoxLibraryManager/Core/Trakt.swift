import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TraktError: LocalizedError {
    case notConfigured
    case notConnected
    case codeExpired
    case denied
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Trakt app’s Client ID and Client Secret in Settings first."
        case .notConnected: return "Connect Trakt in Settings first."
        case .codeExpired: return "The Trakt code expired. Start again."
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

struct TraktDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresAt: Date
    let interval: TimeInterval
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

/// Trakt API v2 with the device code flow (no redirect needed on a phone). The user brings
/// their own API app (trakt.tv/oauth/applications); tokens live in the Keychain.
actor TraktClient {
    static let api = "https://api.trakt.tv"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"

    let clientID: String
    let clientSecret: String

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    static func configured() -> TraktClient? {
        let id = UserDefaults.standard.string(forKey: "trakt.clientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = Secrets.traktSecret() ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return TraktClient(clientID: id, clientSecret: secret)
    }

    // MARK: Device auth

    func deviceCode() async throws -> TraktDeviceCode {
        let object = try await send("POST", "/oauth/device/code", body: ["client_id": .string(clientID)], auth: false)
        guard let code = Py.text(object["device_code"]), let user = Py.text(object["user_code"]) else {
            throw TraktError.status(200, "No device code in the response")
        }
        return TraktDeviceCode(
            deviceCode: code, userCode: user,
            verificationURL: Py.text(object["verification_url"]) ?? "https://trakt.tv/activate",
            expiresAt: Date().addingTimeInterval(object["expires_in"]?.pythonDouble ?? 600),
            interval: max(object["interval"]?.pythonDouble ?? 5, 1)
        )
    }

    /// Poll until the user approves the code. Saves the token.
    func waitForToken(_ code: TraktDeviceCode) async throws -> TraktToken {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let (data, response) = try await raw("POST", "/oauth/device/token", body: [
                "code": .string(code.deviceCode), "client_id": .string(clientID), "client_secret": .string(clientSecret),
            ], token: nil)
            switch response.statusCode {
            case 200:
                let token = try TraktToken(JSONCoding.decodeObject(data))
                token.save()
                return token
            case 400: continue                  // pending
            case 429: interval += 1; continue   // slow down
            case 410: throw TraktError.codeExpired
            case 418: throw TraktError.denied
            default: throw TraktError.status(response.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
        throw TraktError.codeExpired
    }

    func revoke() async {
        guard let token = TraktToken.load() else { return }
        _ = try? await raw("POST", "/oauth/revoke", body: [
            "token": .string(token.accessToken), "client_id": .string(clientID), "client_secret": .string(clientSecret),
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
            "client_secret": .string(clientSecret), "redirect_uri": .string(Self.redirectURI),
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
