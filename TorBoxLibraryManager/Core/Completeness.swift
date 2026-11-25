import Foundation

/// Aired episodes of a show per season (specials left out), from TMDB's show details.
struct AiredEpisodes: Codable, Sendable, Equatable {
    /// season → number of aired episodes (1...n)
    var seasons: [Int: Int]
    var status: String?
    var fetchedAt: Date

    /// Every aired episode, in order.
    var keys: [EpisodeKey] {
        seasons.keys.sorted().flatMap { season in
            (0..<(seasons[season] ?? 0)).map { EpisodeKey(season: season, episode: $0 + 1) }
        }
    }

    /// From `/tv/{id}`: seasons before the last aired episode's season count fully,
    /// that season up to the last aired episode, later seasons not at all.
    static func from(details: JSONObject, now: Date = Date()) -> AiredEpisodes {
        var seasons: [Int: Int] = [:]
        if let last = details["last_episode_to_air"]?.objectValue,
           let lastSeason = Py.int(last["season_number"]), let lastEpisode = Py.int(last["episode_number"]) {
            for value in details["seasons"]?.arrayValue ?? [] {
                guard let season = value.objectValue, let number = Py.int(season["season_number"]), number > 0 else { continue }
                let count = Py.int(season["episode_count"]) ?? 0
                if number < lastSeason, count > 0 {
                    seasons[number] = count
                } else if number == lastSeason {
                    seasons[number] = lastEpisode
                }
            }
            if lastSeason > 0, seasons[lastSeason] == nil { seasons[lastSeason] = lastEpisode }
        }
        return AiredEpisodes(seasons: seasons.filter { $0.value > 0 }, status: Py.text(details["status"]), fetchedAt: now)
    }
}

/// Which aired episodes a show lacks in the library.
struct CompletenessReport: Sendable, Equatable {
    /// Seasons with none of their aired episodes.
    let missingSeasons: [Int]
    /// Seasons with some episodes: the missing episode numbers.
    let missingEpisodes: [Int: [Int]]
    let airedCount: Int

    var missingCount: Int {
        missingEpisodes.values.reduce(0) { $0 + $1.count }
    }

    var isComplete: Bool { airedCount > 0 && missingSeasons.isEmpty && missingEpisodes.isEmpty }

    static func make(aired: AiredEpisodes, present: Set<EpisodeKey>) -> CompletenessReport {
        var missingSeasons: [Int] = []
        var missingEpisodes: [Int: [Int]] = [:]
        var airedCount = 0
        for (season, count) in aired.seasons where count > 0 {
            airedCount += count
            let missing = (1...count).filter { !present.contains(EpisodeKey(season: season, episode: $0)) }
            if missing.count == count {
                missingSeasons.append(season)
                missingEpisodes[season] = missing
            } else if !missing.isEmpty {
                missingEpisodes[season] = missing
            }
        }
        return CompletenessReport(missingSeasons: missingSeasons.sorted(), missingEpisodes: missingEpisodes, airedCount: airedCount)
    }

    /// One line per season that lacks something: ("Season 3", "all 10 episodes").
    var lines: [(season: Int, text: String)] {
        missingEpisodes.keys.sorted().map { season in
            let episodes = missingEpisodes[season] ?? []
            if missingSeasons.contains(season) {
                return (season, episodes.count == 1 ? "the episode" : "all \(episodes.count) episodes")
            }
            return (season, Self.ranges(episodes))
        }
    }

    /// [4, 7, 8, 9] → "E4, E7–E9"
    static func ranges(_ numbers: [Int]) -> String {
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        func close() {
            guard let start, let previous else { return }
            parts.append(start == previous ? "E\(start)" : "E\(start)–E\(previous)")
        }
        for number in numbers.sorted() {
            if let last = previous, number == last + 1 {
                previous = number
            } else {
                close()
                start = number
                previous = number
            }
        }
        close()
        return parts.joined(separator: ", ")
    }
}

/// Small JSON files next to the catalog (aired episodes, Trakt state).
enum LocalFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorBoxLibrary", isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            AppLog.write("Couldn’t save \(name): \(error.localizedDescription)")
        }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Aired episodes per TMDB show id, cached on disk. Ended shows are refreshed weekly,
/// running ones daily.
actor AiredEpisodeCache {
    static let shared = AiredEpisodeCache()
    private static let fileName = "aired.json"
    private var cache: [String: AiredEpisodes]
    private var inFlight: Set<String> = []

    init() {
        cache = LocalFile.load([String: AiredEpisodes].self, Self.fileName) ?? [:]
    }

    func cached(_ tmdbIDs: [String]) -> [String: AiredEpisodes] {
        var result: [String: AiredEpisodes] = [:]
        for id in tmdbIDs { result[id] = cache[id] }
        return result
    }

    private func isFresh(_ value: AiredEpisodes, now: Date) -> Bool {
        let ended = value.status == "Ended" || value.status == "Canceled"
        return now.timeIntervalSince(value.fetchedAt) < (ended ? 7 : 1) * 86_400
    }

    /// Fetch what is missing or stale; returns the shows that changed.
    func refresh(_ tmdbIDs: [String], tmdb: TMDBClient, force: Bool = false) async -> [String: AiredEpisodes] {
        let now = Date()
        let wanted = Set(tmdbIDs).filter { id in
            !inFlight.contains(id) && (force || cache[id].map { !isFresh($0, now: now) } ?? true)
        }
        guard !wanted.isEmpty else { return [:] }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        let fetched = await withTaskGroup(of: (String, AiredEpisodes?).self) { group in
            for id in wanted {
                group.addTask {
                    // The client itself keeps at most 4 requests in flight.
                    guard let details = try? await tmdb.get("/tv/\(id)") else { return (id, nil) }
                    return (id, AiredEpisodes.from(details: details))
                }
            }
            var result: [String: AiredEpisodes] = [:]
            for await (id, value) in group {
                if let value { result[id] = value }
            }
            return result
        }
        var changed: [String: AiredEpisodes] = [:]
        for (id, value) in fetched {
            if cache[id]?.seasons != value.seasons { changed[id] = value }
            cache[id] = value
        }
        if !fetched.isEmpty { LocalFile.save(cache, Self.fileName) }
        return changed
    }

    func clear() {
        cache = [:]
        LocalFile.remove(Self.fileName)
    }
}
