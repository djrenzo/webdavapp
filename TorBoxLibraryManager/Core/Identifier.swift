import Foundation

struct ScoredResult: Sendable {
    let total: Double
    let similarity: Double
    let year: Int?
    let result: JSONObject
    let mediaType: String

    var displayTitle: String {
        Py.text(result["title"]) ?? Py.text(result["name"]) ?? "?"
    }
}

enum IdentifyOutcome: Sendable {
    case matched(JSONObject)
    case unmatched(reason: String)
}

/// Port of torbox_identify (§7.3).
enum Identifier {
    static let minScore = 0.8

    /// `_score`: (total, similarity, result year).
    static func score(query: String, year: Int?, result: JSONObject, mediaType: String) -> (Double, Double, Int?) {
        let names = [
            Py.truthy(result["title"]) ? result["title"] : result["name"],
            Py.truthy(result["original_title"]) ? result["original_title"] : result["original_name"],
        ].compactMap { $0?.stringValue }.filter { !$0.isEmpty }
        let q = TextMatching.normalize(query)
        var similarity = names.map { TextMatching.ratio(q, TextMatching.normalize($0)) }.max() ?? 0
        for name in names where name.contains(":") {
            let head = String(name.split(separator: ":", omittingEmptySubsequences: false).first ?? "")
            similarity = max(similarity, 0.95 * TextMatching.ratio(q, TextMatching.normalize(head)))
        }
        let date = [result["release_date"], result["first_air_date"]]
            .compactMap { $0 }.first(where: \.isTruthy)?.stringValue ?? ""
        let prefix = String(date.prefix(4))
        let resultYear = !prefix.isEmpty && prefix.allSatisfy(\.isWholeNumber) ? Int(prefix) : nil
        var bonus = 0.0
        if let year, year != 0, let resultYear, resultYear != 0 {
            switch abs(year - resultYear) {
            case 0: bonus = 0.1
            case 1: bonus = 0.05
            default: bonus = mediaType == "tvshow" ? -0.05 : -0.2
            }
        }
        return (similarity + bonus, similarity, resultYear)
    }

    /// `_search`: the best result above 0.7 similarity, plus the best below it (for the
    /// "best score 0.74 for X" reason).
    static func search(_ tmdb: TMDBClient, type: String, query: String, year: Int?) async throws -> (best: ScoredResult?, nearMiss: ScoredResult?) {
        let results = try await tmdb.search(type: type, query: query, year: year)
        var best: ScoredResult?
        var nearMiss: ScoredResult?
        for result in results {
            let (total, similarity, resultYear) = score(query: query, year: year, result: result, mediaType: type)
            let scored = ScoredResult(total: total, similarity: similarity, year: resultYear, result: result, mediaType: type)
            if similarity < 0.7 {
                if nearMiss == nil || total > nearMiss!.total { nearMiss = scored }
                continue
            }
            if best == nil || total > best!.total { best = scored }
        }
        return (best, nearMiss)
    }

    /// `_guess_type_from_contents`: "tvshow", "movie" or nil.
    static func guessType(_ credentials: WebDAVCredentials, folderPath: String) async -> String? {
        guard let items = try? await WebDAV.propfind(credentials, path: folderPath) else { return nil }
        if items.contains(where: { $0.isCollection && ReleaseParser.seasonFolder.first(in: $0.name, anchored: true) != nil }) {
            return "tvshow"
        }
        let videos = items.filter { !$0.isCollection && Media.isAddonVideo($0.name) }
        let numbered = videos.filter { EpisodeNumbering.extractEpisodeInfo($0.name) != nil }
        if numbered.count >= 2 || (videos.count >= 3 && !numbered.isEmpty) { return "tvshow" }
        return videos.isEmpty ? nil : "movie"
    }

    /// `identify_folder`.
    static func identify(_ tmdb: TMDBClient, credentials: WebDAVCredentials?, folderName: String, folderPath: String) async throws -> IdentifyOutcome {
        let parsed = ReleaseParser.parse(folderName)
        var types: [String]
        if parsed.tvHint {
            types = ["tvshow"]
        } else if let credentials, let guessed = await guessType(credentials, folderPath: folderPath) {
            types = [guessed]
        } else {
            types = ["movie", "tvshow"]
        }

        var best: ScoredResult?
        var nearMiss: ScoredResult?
        for query in ReleaseParser.queries(for: parsed.title) {
            try Task.checkCancellation()
            for type in types {
                let found = try await search(tmdb, type: type, query: query, year: parsed.year)
                if let candidate = found.best, best == nil || candidate.total > best!.total { best = candidate }
                if let miss = found.nearMiss, nearMiss == nil || miss.total > nearMiss!.total { nearMiss = miss }
            }
            if let best, best.total >= minScore { break }
        }

        guard let best, best.total >= minScore else {
            let shown = best ?? nearMiss
            let reason: String
            if let shown {
                reason = String(format: "Best score %.2f for “%@”", shown.total, shown.displayTitle)
            } else {
                reason = "No TMDB result for “\(parsed.title)”"
            }
            AppLog.write("identify: no match for \"\(folderName)\" (searched \"\(parsed.title)\" as \(types.joined(separator: "/")))")
            return .unmatched(reason: reason)
        }
        let entry = await buildEntry(tmdb, best)
        AppLog.write(String(format: "identify: \"%@\" -> %@ \"%@\" score %.2f", folderName, best.mediaType, best.displayTitle, best.total))
        return .matched(entry)
    }

    /// `_build_entry`.
    static func buildEntry(_ tmdb: TMDBClient, _ match: ScoredResult, source: String = Overrides.sourceAuto) async -> JSONObject {
        let result = match.result
        let tmdbID = result["id"]?.pythonString ?? ""
        var entry: JSONObject = [
            "title": Py.truthy(result["title"]) ? result["title"]! : (result["name"] ?? .null),
            "type": .string(match.mediaType),
            "tmdb_id": .string(tmdbID),
            "source": .string(source),
        ]
        if let year = match.year { entry["year"] = .int(year) }
        if let poster = result["poster_path"]?.stringValue, !poster.isEmpty {
            entry["thumb"] = .string(TMDBClient.imageBase + "w500" + poster)
        }
        if Py.truthy(result["overview"]) { entry["plot"] = result["overview"] }
        do {
            let ids = try await tmdb.externalIDs(type: match.mediaType, id: tmdbID)
            if Py.truthy(ids["imdb_id"]) { entry["imdb_id"] = ids["imdb_id"] }
            if match.mediaType == "tvshow", Py.truthy(ids["tvdb_id"]), let tvdb = ids["tvdb_id"] {
                entry["tvdb_id"] = .string(tvdb.pythonString)
            }
        } catch {
            AppLog.write("identify: external ids failed for \(tmdbID): \(error.localizedDescription)")
        }
        return entry
    }
}
