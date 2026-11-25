import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension EpisodeNumber {
    var key: EpisodeKey? {
        guard let season, let episode else { return nil }
        return EpisodeKey(season: season, episode: episode)
    }
}

enum SubtitleError: LocalizedError {
    case missingKey
    case missingIDs
    case noPermanentLink
    case badFile(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an OpenSubtitles API key in Settings first."
        case .missingIDs: return "This title has no TMDB or IMDb id. Fix its match first."
        case .noPermanentLink: return "This subtitle has no permanent download link, so Kodi and other devices couldn’t load it. Pick another one."
        case .badFile(let reason): return "The subtitle file couldn’t be downloaded: \(reason)"
        }
    }
}

/// One search result. `url` is the permanent download link the addon stores
/// (`subs5.strem.io/.../file/<legacy file id>`); nil when OpenSubtitles has no legacy copy.
struct SubtitleSearchResult: Sendable, Identifiable {
    let id: String
    let fileName: String
    let release: String?
    let language: String
    let hearingImpaired: Bool
    let downloads: Int?
    let fps: Double?
    let uploader: String?
    let trusted: Bool
    let machineTranslated: Bool
    let url: String?

    var languageName: String { SubtitleLanguages.name(language) }
}

/// What to search for: a movie, or one episode of a show.
struct SubtitleTarget: Sendable {
    let tmdbID: String?
    let imdbID: String?
    let episode: EpisodeKey?
}

/// The OpenSubtitles REST API (api.opensubtitles.com, needs a free consumer API key) for
/// rich results, joined with the stremio mirror of OpenSubtitles for links that never
/// expire. Without a key only the mirror is searched.
struct OpenSubtitlesClient: Sendable {
    static let api = "https://api.opensubtitles.com/api/v1"
    static let mirror = "https://opensubtitles-v3.strem.io/subtitles"
    static let userAgent = "WebDAVify v1.0"

    let apiKey: String?

    static func fromKeychain() -> OpenSubtitlesClient {
        OpenSubtitlesClient(apiKey: Secrets.openSubtitlesKey())
    }

    /// Key check for Settings.
    func test() async throws {
        guard let apiKey, !apiKey.isEmpty else { throw SubtitleError.missingKey }
        _ = try await rest("/infos/formats", [:], key: apiKey)
    }

    func search(_ target: SubtitleTarget, languages: [String]) async throws -> [SubtitleSearchResult] {
        guard target.tmdbID != nil || target.imdbID != nil else { throw SubtitleError.missingIDs }
        let wanted = Set(languages.map { $0.lowercased() })
        async let mirrorList = mirrorResults(target)
        var results: [SubtitleSearchResult] = []
        var seen = Set<String>()

        if let apiKey, !apiKey.isEmpty {
            let links = (try? await mirrorList) ?? [:]
            for item in try await restResults(target, languages: languages, key: apiKey) {
                var item = item
                if let link = links[item.id] {
                    item = item.with(url: link.url)
                    seen.insert(item.id)
                }
                results.append(item)
            }
            // Mirror-only results (not in the API's first page) after the API's.
            for (id, link) in links where !seen.contains(id) && wanted.contains(link.language.lowercased()) {
                results.append(link.result(id: id))
            }
        } else {
            let links = try await mirrorList
            results = links.filter { wanted.contains($0.value.language.lowercased()) }.map { $0.value.result(id: $0.key) }
                .sorted { $0.fileName < $1.fileName }
        }
        // Usable first, then the most downloaded.
        return results.enumerated().sorted { lhs, rhs in
            let lhsUsable = lhs.element.url != nil, rhsUsable = rhs.element.url != nil
            if lhsUsable != rhsUsable { return lhsUsable }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Download the picked file once: proves the link works before it is saved.
    static func verify(_ url: String) async throws -> String {
        guard let link = URL(string: url) else { throw SubtitleError.badFile("invalid link") }
        var request = URLRequest(url: link)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SubtitleError.badFile("HTTP \(response.statusCode)") }
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        guard text.contains("-->") || text.lowercased().contains("[events]") else { throw SubtitleError.badFile("not a subtitle file") }
        return text
    }

    // MARK: REST API

    private func rest(_ path: String, _ params: [String: String], key: String) async throws -> JSONObject {
        var components = URLComponents(string: Self.api + path)!
        if !params.isEmpty {
            // The API redirects unless parameters are sorted and lower case.
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value.lowercased()) }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONCoding.decodeObject(data)
            let message = Py.text(object?["message"]) ?? Py.text(object?["errors"]?.arrayValue?.first) ?? ""
            throw HTTPStatusError(status: response.statusCode, message: message)
        }
        return try JSONCoding.decodeObject(data)
    }

    private func restResults(_ target: SubtitleTarget, languages: [String], key: String) async throws -> [SubtitleSearchResult] {
        var params = ["languages": languages.sorted().joined(separator: ",")]
        let tmdb = target.tmdbID
        let imdb = target.imdbID.map { $0.lowercased().replacingOccurrences(of: "tt", with: "") }.flatMap { Int($0) }.map(String.init)
        if let episode = target.episode {
            params["type"] = "episode"
            params["season_number"] = String(episode.season)
            params["episode_number"] = String(episode.episode)
            if let tmdb { params["parent_tmdb_id"] = tmdb } else if let imdb { params["parent_imdb_id"] = imdb }
        } else {
            params["type"] = "movie"
            if let tmdb { params["tmdb_id"] = tmdb } else if let imdb { params["imdb_id"] = imdb }
        }
        let response = try await rest("/subtitles", params, key: key)
        return (response["data"]?.arrayValue ?? []).compactMap { value in
            guard let attributes = value.objectValue?["attributes"]?.objectValue else { return nil }
            let legacy = Py.text(attributes["legacy_subtitle_id"]) ?? Py.text(attributes["subtitle_id"]) ?? Py.text(value.objectValue?["id"]) ?? UUID().uuidString
            let file = attributes["files"]?.arrayValue?.first?.objectValue
            let release = Py.text(attributes["release"])
            return SubtitleSearchResult(
                id: legacy,
                fileName: Py.text(file?["file_name"]) ?? release ?? "Subtitle \(legacy)",
                release: release,
                language: Py.text(attributes["language"]).map { SubtitleLanguages.find($0)?.code ?? $0 } ?? languages.first ?? "en",
                hearingImpaired: Py.truthy(attributes["hearing_impaired"]),
                downloads: Py.int(attributes["download_count"]),
                fps: attributes["fps"]?.pythonDouble.flatMap { $0 > 0 ? $0 : nil },
                uploader: Py.text(attributes["uploader"]?.objectValue?["name"]),
                trusted: Py.truthy(attributes["from_trusted"]),
                machineTranslated: Py.truthy(attributes["machine_translated"]) || Py.truthy(attributes["ai_translated"]),
                url: nil
            )
        }
    }

    // MARK: Mirror

    struct MirrorLink: Sendable {
        let url: String
        let language: String
        let fileName: String
        let fps: Double?

        func result(id: String) -> SubtitleSearchResult {
            SubtitleSearchResult(
                id: id, fileName: fileName, release: nil, language: language,
                hearingImpaired: fileName.range(of: #"[.\-_ ](hi|sdh)[.\-_ ]"#, options: [.regularExpression, .caseInsensitive]) != nil,
                downloads: nil, fps: fps, uploader: nil, trusted: false, machineTranslated: false, url: url
            )
        }
    }

    /// Legacy subtitle id → permanent link, from the mirror (keyed by IMDb id).
    private func mirrorResults(_ target: SubtitleTarget) async throws -> [String: MirrorLink] {
        guard let imdb = target.imdbID, imdb.hasPrefix("tt") else { return [:] }
        let path: String
        if let episode = target.episode {
            path = "\(Self.mirror)/series/\(imdb):\(episode.season):\(episode.episode).json"
        } else {
            path = "\(Self.mirror)/movie/\(imdb)/filename=t.json"
        }
        guard let url = URL(string: path) else { return [:] }
        let (data, response) = try await HTTP.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw HTTPStatusError(status: response.statusCode, message: "") }
        let object = try JSONCoding.decodeObject(data)
        var links: [String: MirrorLink] = [:]
        for value in object["subtitles"]?.arrayValue ?? [] {
            guard let item = value.objectValue, let id = Py.text(item["id"]), let link = Py.text(item["url"]),
                  let legacy = Py.text(item["lang"]) else { continue }
            links[id] = MirrorLink(
                url: link,
                language: SubtitleLanguages.find(legacy: legacy)?.code ?? legacy,
                fileName: Py.text(item["subtitleFileName"]) ?? Py.text(item["movieReleaseName"]) ?? "Subtitle \(id)",
                fps: Py.int(item["fpsMilli"]).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
            )
        }
        return links
    }
}

private extension SubtitleSearchResult {
    func with(url: String) -> SubtitleSearchResult {
        SubtitleSearchResult(
            id: id, fileName: fileName, release: release, language: language, hearingImpaired: hearingImpaired,
            downloads: downloads, fps: fps, uploader: uploader, trusted: trusted, machineTranslated: machineTranslated, url: url
        )
    }
}

extension SubtitleSearchResult {
    /// The `subs` entry the addon would write for this pick.
    func entry(fileName: String) -> JSONObject {
        [
            "url": .string(url ?? ""),
            "fileName": .string(fileName),
            "language": .string(language),
            "hi": .bool(hearingImpaired),
        ]
    }
}
