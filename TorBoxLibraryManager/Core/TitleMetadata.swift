import Foundation

struct EpisodeInfo: Sendable {
    let name: String?
    let stillURL: URL?
    let airDate: String?
}

/// Extra details for the title screen (§9.2): from Supabase `titles`/`episodes` once
/// pushed, otherwise from TMDB on demand.
struct TitleMetadata: Sendable {
    var fanartURL: URL?
    var tagline: String?
    var genres: [String] = []
    var rating: Double?
    var runtime: Int?
    var status: String?
    var premiered: String?
    var plot: String?
    var episodes: [Int: [Int: EpisodeInfo]] = [:]

    static func load(key: String, mediaType: String, tmdbID: String?, seasons: Set<Int>, settings: AppSettings) async -> TitleMetadata? {
        if let config = settings.supabaseConfig {
            let client = SupabaseClient(config: config)
            if let rows = try? await client.select(
                "titles", select: "*,episodes(season_number,episode_number,name,still_url,air_date)",
                filters: [("key", "eq.\(key)")]
            ), let row = rows.first {
                var metadata = TitleMetadata(
                    fanartURL: Py.text(row["fanart_url"]).flatMap(URL.init(string:)),
                    tagline: Py.text(row["tagline"]),
                    genres: (row["genres"]?.arrayValue ?? []).compactMap(\.stringValue),
                    rating: row["rating"]?.pythonDouble,
                    runtime: Py.int(row["runtime"]),
                    status: Py.text(row["status"]),
                    premiered: Py.text(row["premiered"]),
                    plot: Py.text(row["plot"])
                )
                for value in row["episodes"]?.arrayValue ?? [] {
                    guard let episode = value.objectValue, let season = Py.int(episode["season_number"]),
                          let number = Py.int(episode["episode_number"]) else { continue }
                    metadata.episodes[season, default: [:]][number] = EpisodeInfo(
                        name: Py.text(episode["name"]),
                        stillURL: Py.text(episode["still_url"]).flatMap(URL.init(string:)),
                        airDate: Py.text(episode["air_date"])
                    )
                }
                if metadata.fanartURL != nil || !metadata.genres.isEmpty || !metadata.episodes.isEmpty {
                    return metadata
                }
            }
        }
        guard let tmdbID, let tmdb = try? TMDBClient.fromKeychain(),
              let result = try? await tmdb.details(type: mediaType, id: tmdbID, seasons: seasons) else { return nil }
        let details = result.details
        let isTV = mediaType == "tvshow"
        var metadata = TitleMetadata(
            fanartURL: TMDBClient.image(details["backdrop_path"]?.stringValue, size: "w1280").flatMap(URL.init(string:)),
            tagline: Py.text(details["tagline"]),
            genres: (details["genres"]?.arrayValue ?? []).compactMap { Py.text($0.objectValue?["name"]) },
            rating: Push.rating(details["vote_average"]),
            runtime: Py.int(isTV ? details["episode_run_time"]?.arrayValue?.first : details["runtime"]),
            status: Py.text(details["status"]),
            premiered: Push.date(details[isTV ? "first_air_date" : "release_date"]),
            plot: Py.text(details["overview"])
        )
        for (season, episodes) in result.episodes {
            for episode in episodes {
                guard let number = Py.int(episode["episode_number"]) else { continue }
                metadata.episodes[season, default: [:]][number] = EpisodeInfo(
                    name: Py.text(episode["name"]),
                    stillURL: TMDBClient.image(episode["still_path"]?.stringValue, size: "w300").flatMap(URL.init(string:)),
                    airDate: Push.date(episode["air_date"])
                )
            }
        }
        return metadata
    }
}
