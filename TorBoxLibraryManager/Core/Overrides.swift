import Foundation

/// Helpers over one overrides.json entry (§3.1). The JSON object is the source of truth;
/// these only read it, the way the Kodi addon does.
enum Overrides {
    static let sourceAuto = "auto"
    static let mediaTypes = ["movie", "tvshow"]

    /// `_media_type`: type, defaulting to tvshow; nil for an unknown value.
    static func mediaType(_ entry: JSONObject) -> String? {
        let value = Py.truthy(entry["type"]) ? entry["type"]! : .string("tvshow")
        guard let text = value.stringValue, mediaTypes.contains(text) else { return nil }
        return text
    }

    static func isIdentified(_ entry: JSONObject) -> Bool {
        Py.truthy(entry["title"])
    }

    static func isAutomatic(_ entry: JSONObject) -> Bool {
        entry["source"]?.stringValue == sourceAuto
    }

    /// `is_manual`: has a title and source is not exactly "auto".
    static func isManual(_ entry: JSONObject) -> Bool {
        !entry.isEmpty && isIdentified(entry) && !isAutomatic(entry)
    }

    static func title(_ entry: JSONObject) -> String? { Py.text(entry["title"]) }
    static func year(_ entry: JSONObject) -> Int? { Py.int(entry["year"]) }
    static func thumb(_ entry: JSONObject) -> String? { Py.text(entry["thumb"]) }
    static func plot(_ entry: JSONObject) -> String? { Py.text(entry["plot"]) }
    static func tmdbID(_ entry: JSONObject) -> String? { Py.text(entry["tmdb_id"]) }
    static func season(_ entry: JSONObject) -> Int? { Py.int(entry["season"]) }
    static func forceSeason(_ entry: JSONObject) -> Bool { Py.truthy(entry["force_season"]) }

    /// `title_key` (§3.3).
    static func titleKey(_ entry: JSONObject) -> String {
        let type = mediaType(entry) ?? "tvshow"
        for field in ["tmdb_id", "tvdb_id", "imdb_id"] {
            if let value = Py.text(entry[field]) {
                return "\(type):\(field.dropLast(3)):\(value)"
            }
        }
        let title = entry["title"]?.stringValue ?? ""
        let year = Py.int(entry["year"]).flatMap { $0 == 0 ? nil : $0 }.map(String.init) ?? ""
        return "\(type):title:\(TextMatching.normalize(title)):\(year)"
    }

    /// Merge an automatic match over an existing entry (§3.2). Returns nil when the existing
    /// entry is manual and must not be touched.
    static func mergeAutomatic(_ match: JSONObject, over existing: JSONObject?) -> JSONObject? {
        let existing = existing ?? [:]
        if isManual(existing) { return nil }
        var entry = match
        for key in ["subs", "season", "force_season"] {
            if let value = existing[key], !value.isNull { entry[key] = value }
        }
        return entry
    }

    /// A manual match (Fix match, §9.3): the new identification with `source: manual`,
    /// keeping the folder's subs, season and force_season.
    static func manualEntry(from match: JSONObject, existing: JSONObject?) -> JSONObject {
        var entry = match
        entry["source"] = "manual"
        for key in ["subs", "season", "force_season"] {
            if let value = existing?[key], !value.isNull { entry[key] = value }
        }
        return entry
    }
}

/// One title row built from the overrides (`_title_rows`): manual entries first, gaps filled
/// from the others. Used both for the gallery and for the push.
struct TitleRowSet: Sendable {
    var rows: [String: JSONObject] = [:]
    var folderKeys: [String: String] = [:]

    init(overrides: [String: JSONObject]) {
        let ordered = overrides.sorted { lhs, rhs in
            let lhsAuto = Overrides.isAutomatic(lhs.value), rhsAuto = Overrides.isAutomatic(rhs.value)
            if lhsAuto != rhsAuto { return !lhsAuto }
            return lhs.key < rhs.key
        }
        for (folderName, entry) in ordered {
            guard Py.truthy(entry["title"]), let type = Overrides.mediaType(entry) else { continue }
            let key = Overrides.titleKey(entry)
            folderKeys[folderName] = key
            let candidate: JSONObject = [
                "key": .string(key),
                "media_type": .string(type),
                "title": entry["title"] ?? .null,
                "year": Py.number(Py.int(entry["year"])),
                "tmdb_id": Py.string(Py.text(entry["tmdb_id"])),
                "tvdb_id": Py.string(Py.text(entry["tvdb_id"])),
                "imdb_id": Py.string(Py.text(entry["imdb_id"])),
                "plot": Py.string(Py.text(entry["plot"])),
                "poster_url": Py.string(Py.text(entry["thumb"])),
            ]
            var row = rows[key] ?? candidate
            for (field, value) in candidate where row[field] == nil || row[field]!.isNull {
                row[field] = value
            }
            rows[key] = row
        }
        for key in rows.keys {
            rows[key] = rows[key]!.filter { !$0.value.isNull }
        }
    }
}
