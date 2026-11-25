import Foundation

/// A subtitle language as OpenSubtitles knows it. `code` is what the app stores in the
/// overrides entry and puts in the file name (`Title.S01E02.en.srt`); `legacy` is the
/// ISO 639-2 code the permanent download mirror uses.
struct SubtitleLanguage: Sendable, Hashable, Identifiable {
    let code: String
    let name: String
    let legacy: String
    var id: String { code }
}

enum SubtitleLanguages {
    static let all: [SubtitleLanguage] = [
        .init(code: "en", name: "English", legacy: "eng"),
        .init(code: "es", name: "Spanish", legacy: "spa"),
        .init(code: "nl", name: "Dutch", legacy: "dut"),
        .init(code: "fr", name: "French", legacy: "fre"),
        .init(code: "de", name: "German", legacy: "ger"),
        .init(code: "it", name: "Italian", legacy: "ita"),
        .init(code: "pt-PT", name: "Portuguese", legacy: "por"),
        .init(code: "pt-BR", name: "Portuguese (Brazil)", legacy: "pob"),
        .init(code: "pl", name: "Polish", legacy: "pol"),
        .init(code: "ru", name: "Russian", legacy: "rus"),
        .init(code: "uk", name: "Ukrainian", legacy: "ukr"),
        .init(code: "sv", name: "Swedish", legacy: "swe"),
        .init(code: "da", name: "Danish", legacy: "dan"),
        .init(code: "no", name: "Norwegian", legacy: "nor"),
        .init(code: "fi", name: "Finnish", legacy: "fin"),
        .init(code: "cs", name: "Czech", legacy: "cze"),
        .init(code: "hu", name: "Hungarian", legacy: "hun"),
        .init(code: "ro", name: "Romanian", legacy: "rum"),
        .init(code: "el", name: "Greek", legacy: "gre"),
        .init(code: "tr", name: "Turkish", legacy: "tur"),
        .init(code: "hr", name: "Croatian", legacy: "hrv"),
        .init(code: "sr", name: "Serbian", legacy: "scc"),
        .init(code: "bg", name: "Bulgarian", legacy: "bul"),
        .init(code: "ar", name: "Arabic", legacy: "ara"),
        .init(code: "he", name: "Hebrew", legacy: "heb"),
        .init(code: "id", name: "Indonesian", legacy: "ind"),
        .init(code: "vi", name: "Vietnamese", legacy: "vie"),
        .init(code: "th", name: "Thai", legacy: "tha"),
        .init(code: "ja", name: "Japanese", legacy: "jpn"),
        .init(code: "ko", name: "Korean", legacy: "kor"),
        .init(code: "zh-CN", name: "Chinese (simplified)", legacy: "chi"),
        .init(code: "zh-TW", name: "Chinese (traditional)", legacy: "zht"),
    ]

    /// Older Kodi picks use "sp" for Spanish.
    private static let aliases = ["sp": "es", "pt": "pt-PT", "pb": "pt-BR", "ze": "zh-CN", "zh": "zh-CN"]

    static func find(_ code: String) -> SubtitleLanguage? {
        let wanted = aliases[code.lowercased()] ?? code
        return all.first { $0.code.lowercased() == wanted.lowercased() }
    }

    static func find(legacy: String) -> SubtitleLanguage? {
        all.first { $0.legacy == legacy.lowercased() }
    }

    static func name(_ code: String) -> String {
        find(code)?.name ?? code.uppercased()
    }
}

/// One entry of an overrides entry's `subs` array (the Kodi addon's format):
/// `{"url", "fileName", "language", "hi", "fps_from"?, "fps_to"?, "shift_ms"?}`.
struct SavedSubtitle: Sendable, Identifiable, Equatable {
    let url: String
    let fileName: String
    let language: String
    let hearingImpaired: Bool
    let fpsFrom: Double?
    let fpsTo: Double?
    let shiftMs: Int?
    /// SxxEyy read from `fileName` (shows only), the way the addon attaches it to an episode.
    let episode: EpisodeKey?
    var id: String { url }

    var languageName: String { SubtitleLanguages.name(language) }

    var adjustments: String? {
        var parts: [String] = []
        if let fpsFrom, let fpsTo { parts.append(String(format: "%g → %g fps", fpsFrom, fpsTo)) }
        if let shiftMs, shiftMs != 0 { parts.append("\(shiftMs > 0 ? "+" : "")\(shiftMs) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct EpisodeKey: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    let season: Int
    let episode: Int

    static func < (lhs: EpisodeKey, rhs: EpisodeKey) -> Bool {
        (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
    }

    var description: String { String(format: "S%02dE%02d", season, episode) }
}

enum SubtitleEntries {
    /// `_SUBTITLE_SUFFIX` of the addon's library export: what it keeps of a stored fileName.
    static let suffix = Pattern(#"((?:\.[A-Za-z]{2,3}(?:-[A-Za-z]{2})?)?(?:\.(?:hi|sdh|forced))?\.(?:srt|ass|ssa|vtt|sub))$"#, ignoreCase: true)

    /// The usable subtitles of an entry, in stored order (later picks win in the export).
    static func saved(_ entry: JSONObject) -> [SavedSubtitle] {
        let isTV = Overrides.mediaType(entry) == "tvshow"
        return (entry["subs"]?.arrayValue ?? []).compactMap { value in
            guard let sub = value.objectValue,
                  let url = Py.text(sub["url"])?.trimmingCharacters(in: .whitespaces),
                  let fileName = Py.text(sub["fileName"])?.trimmingCharacters(in: .whitespaces),
                  suffix.first(in: fileName) != nil else { return nil }
            var episode: EpisodeKey?
            if isTV, let info = EpisodeNumbering.extractEpisodeInfo(fileName) {
                episode = EpisodeKey(season: info.season, episode: info.episode)
            }
            var fpsFrom: Double?, fpsTo: Double?
            if Py.truthy(sub["fps_from"]) && Py.truthy(sub["fps_to"]) {
                fpsFrom = sub["fps_from"]?.pythonDouble
                fpsTo = sub["fps_to"]?.pythonDouble
            }
            return SavedSubtitle(
                url: url, fileName: fileName, language: Py.text(sub["language"]) ?? "en",
                hearingImpaired: Py.truthy(sub["hi"]), fpsFrom: fpsFrom, fpsTo: fpsTo,
                shiftMs: Py.truthy(sub["shift_ms"]) ? sub["shift_ms"]?.pythonInt : nil, episode: episode
            )
        }
    }

    /// Subtitles attached to a movie, or to one episode of a show.
    static func saved(_ entry: JSONObject, episode: EpisodeKey?) -> [SavedSubtitle] {
        saved(entry).filter { episode == nil || $0.episode == episode }
    }

    /// The subtitle the Kodi export would use per language suffix (the last pick).
    static func active(_ subs: [SavedSubtitle]) -> [SavedSubtitle] {
        var bySuffix: [String: Int] = [:]
        for (index, sub) in subs.enumerated() {
            let ending = suffix.first(in: sub.fileName)?.group(1)?.lowercased() ?? sub.fileName
            let key = "\(sub.episode?.description ?? "")\(ending)"
            bySuffix[key] = index
        }
        return bySuffix.values.sorted().map { subs[$0] }
    }

    /// `library_folder_name` of the addon: "Title (Year) {tmdb-603}".
    static func movieBaseName(_ entry: JSONObject) -> String {
        let title = Overrides.title(entry) ?? "Movie"
        var name = Overrides.year(entry).map { "\(title) (\($0))" } ?? title
        for key in ["tmdb", "imdb", "tvdb"] {
            if let id = Py.text(entry["\(key)_id"]) {
                name += " {\(key)-\(id)}"
                break
            }
        }
        name = name.replacingOccurrences(of: ":", with: " -")
        name = Pattern(#"[<>"/\\|?*]"#).replace(in: name, with: "")
        name = Pattern(#"\s+"#).replace(in: name, with: " ")
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// The stored fileName for a pick: the library name the addon would export the video
    /// as, plus the language (`Title.S01E02.en.srt`, `Title (1999) {tmdb-603}.en.srt`).
    static func fileName(for entry: JSONObject, episode: EpisodeKey?, language: String) -> String {
        if let episode {
            let title = Overrides.title(entry) ?? "Show"
            return "\(title).\(episode).\(language).srt"
        }
        return "\(movieBaseName(entry)).\(language).srt"
    }

    /// `_remember_subtitle`, plus: an earlier pick for the same video and language is
    /// dropped, so each episode or movie has one subtitle per language.
    static func adding(_ sub: JSONObject, to entry: JSONObject) -> JSONObject {
        var entry = entry
        let url = Py.text(sub["url"]) ?? ""
        let fileName = (Py.text(sub["fileName"]) ?? "").lowercased()
        let kept = (entry["subs"]?.arrayValue ?? []).filter { value in
            guard let saved = value.objectValue else { return true }
            return Py.text(saved["url"]) != url && Py.text(saved["fileName"])?.lowercased() != fileName
        }
        entry["subs"] = .array(kept + [.object(sub)])
        return entry
    }

    static func removing(url: String, from entry: JSONObject) -> JSONObject {
        var entry = entry
        let kept = (entry["subs"]?.arrayValue ?? []).filter { Py.text($0.objectValue?["url"])?.trimmingCharacters(in: .whitespaces) != url }
        entry["subs"] = .array(kept)
        return entry
    }
}
