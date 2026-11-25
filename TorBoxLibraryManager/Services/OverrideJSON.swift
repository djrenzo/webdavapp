import Foundation

/// Raw JSON remains authoritative. JSONSerialization preserves every unedited
/// key, including nested subtitle objects and values unknown to this app.
struct OverrideJSON: Sendable {
    let raw: Data
    let title: String
    let mediaType: String
    let year: Int?
    let tmdbID: String
    let tvdbID: String
    let imdbID: String
    let poster: String
    let originalTitle: String
    let source: String?
    let season: Int?
    let forceSeason: Bool

    init(raw: Data) throws {
        let object = try Self.object(raw)
        self.raw = raw
        title = object["title"] as? String ?? ""
        mediaType = object["type"] as? String ?? "tvshow"
        year = object["year"] as? Int
        tmdbID = object["tmdb_id"] as? String ?? ""
        tvdbID = object["tvdb_id"] as? String ?? ""
        imdbID = object["imdb_id"] as? String ?? ""
        poster = object["thumb"] as? String ?? ""
        originalTitle = object["original_title"] as? String ?? ""
        source = object["source"] as? String
        season = object["season"] as? Int
        forceSeason = object["force_season"] as? Bool ?? false
    }

    var isIdentified: Bool { !title.isEmpty }
    var isAutomatic: Bool { source == "auto" }
    var isManual: Bool { isIdentified && !isAutomatic }

    var titleKey: String {
        if !tmdbID.isEmpty { return "\(mediaType):tmdb:\(tmdbID)" }
        if !tvdbID.isEmpty { return "\(mediaType):tvdb:\(tvdbID)" }
        if !imdbID.isEmpty { return "\(mediaType):imdb:\(imdbID)" }
        let yearText = year.map(String.init) ?? ""
        return "\(mediaType):title:\(Self.normalize(title)):\(yearText)"
    }

    static func normalize(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCompatibilityMapping
        let unmarked = decomposed.unicodeScalars.filter {
            !CharacterSet.nonBaseCharacters.contains($0)
        }
        let lower = String(String.UnicodeScalarView(unmarked))
            .lowercased().replacingOccurrences(of: "&", with: " and ")
        let ascii = lower.replacingOccurrences(
            of: "[^a-z0-9]+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        var words = ascii.split(separator: " ").map(String.init)
        let articles = ["the", "a", "an", "el", "la", "los", "las", "le", "les", "der", "die", "das"]
        if let first = words.first, articles.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    func edited(using draft: EntryDraft) throws -> Data {
        var object = try Self.object(raw)
        object["title"] = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        object["type"] = draft.mediaType
        object["year"] = Int(draft.year)
        object["season"] = Int(draft.season)
        object["force_season"] = Int(draft.season) != nil && draft.forceSeason
        object["source"] = "manual"
        return try Self.encode(object)
    }

    static func mergedMetadata(_ entries: [OverrideJSON]) throws -> OverrideJSON {
        // Stable sorting ensures deterministic priority among manual entries.
        let ordered = entries.filter(\.isManual) + entries.filter { !$0.isManual }
        var merged: [String: Any] = [:]
        for entry in ordered {
            for (key, value) in try object(entry.raw) where nonempty(value) {
                if !nonempty(merged[key]) { merged[key] = value }
            }
        }
        return try OverrideJSON(raw: encode(merged))
    }

    static func object(_ raw: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CatalogError.invalidJSON
        }
        return object
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func nonempty(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }
}
