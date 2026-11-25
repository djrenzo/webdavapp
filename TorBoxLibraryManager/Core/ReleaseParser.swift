import Foundation

/// Port of torbox_common / torbox_identify release-name helpers.
enum Media {
    /// VIDEO_EXTS of torbox_common (the addon also counts `.strm`; listing skips it on iOS).
    static let videoExtensions: Set<String> = [
        ".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".m2ts", ".wmv", ".flv", ".webm",
        ".ogv", ".divx", ".mpg", ".mpeg", ".m2v", ".vob", ".strm"
    ]

    /// `os.path.splitext(name)[1].lower()`.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        if name[..<dot].allSatisfy({ $0 == "." }) { return "" }
        return String(name[dot...]).lowercased()
    }

    /// A video file the listing keeps: known extension (not .strm) and no "sample" in the name.
    static func isListedVideo(_ name: String) -> Bool {
        let ext = fileExtension(name)
        return ext != ".strm" && videoExtensions.contains(ext) && !name.lowercased().contains("sample")
    }

    /// The addon's own test (includes .strm), used for the movie/show guess.
    static func isAddonVideo(_ name: String) -> Bool {
        videoExtensions.contains(fileExtension(name)) && !name.lowercased().contains("sample")
    }
}

struct ParsedRelease: Sendable, Equatable {
    let title: String
    let year: Int?
    let tvHint: Bool
}

enum ReleaseParser {
    private static let extensionPattern = Pattern(
        #"\.("# + Media.videoExtensions.map { String($0.dropFirst()) }.sorted().joined(separator: "|") + #")$"#,
        ignoreCase: true
    )
    private static let leadingTags = Pattern(#"^\s*(?:\[[^\]]*\]\s*|\{[^}]*\}\s*)+"#)
    private static let dotsAndUnderscores = Pattern(#"[._]+"#)
    private static let whitespace = Pattern(#"\s+"#)
    private static let year = Pattern(#"(?<!\d)(19\d{2}|20\d{2})(?!\d)"#)
    static let tvMarker = Pattern(
        #"\bS\d{1,2}(?:[ ._-]?E\d{1,3})?\b"#
            + #"|\b(?:Season|Temporada|Saison|Staffel)[ ._-]?\d{1,2}\b"#
            + #"|\b\d{1,2}x\d{2,3}\b"#
            + #"|\bComplete[ ._-](?:Series|Season)\b"#
            + #"|\bE(?:P)?\d{2,3}\b"#,
        ignoreCase: true
    )
    static let seasonFolder = Pattern(
        #"^(?:S\d{1,2}|(?:Season|Saison|Temporada|Staffel)[ ._-]?\d{1,2})\b"#, ignoreCase: true
    )
    static let qualityTags = Pattern(
        #"\b("#
            + #"2160p|1080p|1080i|720p|576p|480p|4K|UHD|HD|SD|"#
            + #"BluRay|BDRip|BRRip|WEB[-.]?DL|WEBRip|WEB|"#
            + #"HDTV|DVDRip|DVDScr|DVD|PDTV|SDTV|HDCAM|CAM|TS|"#
            + #"x264|x265|H\.?264|H\.?265|HEVC|AVC|XviD|DivX|"#
            + #"AAC[\d.]*|AC3|DTS|DD[\d.]*|TrueHD|Atmos|EAC3|DDP[\d.]*|"#
            + #"10bit|8bit|HDR|HDR10|DV|DoVi|"#
            + #"AMZN|NF|DSNP|HMAX|ATVP|PCOK|iP|"#
            + #"PROPER|REPACK|EXTENDED|THEATRICAL|UNRATED|DIRECTORS\.CUT|"#
            + #"MULTI|MULTi|FRENCH|GERMAN|SPANISH|ITALIAN|"#
            + #"\[TR-EN\]|\[EN\]|\[rartv\]"#
            + #")\b"#,
        ignoreCase: true
    )
    private static let packWords = Pattern(
        #"(?:\s+(?:Int[ée]grale?|Complete|Completa|Completo|Collection|Colecci[oó]n|Box[ ]?Set|"#
            + #"Full[ ]Series|Serie[s]?[ ]Completa))+$"#,
        ignoreCase: true
    )
    private static let bracket = Pattern(#"[\[({]"#)
    private static let trailingJunk = Pattern(#"[\s\-–:(\[{]+$"#)
    private static let querySplit = Pattern(#"\s+-\s+|\s*/\s*"#)

    /// `parse_release_name`.
    static func parse(_ name: String) -> ParsedRelease {
        var value = extensionPattern.replace(in: name, with: "")
        value = leadingTags.replace(in: value, with: "")
        if !value.contains(" ") || value.filter({ $0 == "." }).count >= 2 {
            value = dotsAndUnderscores.replace(in: value, with: " ")
        }
        value = whitespace.replace(in: value, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = value as NSString

        let tvMatch = tvMarker.first(in: value)
        var cuts = [ns.length]
        if let tvMatch, tvMatch.start > 0 { cuts.append(tvMatch.start) }

        var foundYear: Int?
        for match in year.all(in: value) where match.start != 0 {
            foundYear = match.int(1)
            cuts.append(match.start)
            break
        }
        if let match = qualityTags.all(in: value).first(where: { $0.start > 0 }) { cuts.append(match.start) }
        if let match = bracket.all(in: value).first(where: { $0.start > 0 }) { cuts.append(match.start) }

        var title = ns.substring(to: cuts.min() ?? ns.length)
        title = trailingJunk.replace(in: title, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = packWords.replace(in: title.precomposedStringWithCanonicalMapping, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = value }
        return ParsedRelease(title: title, year: foundYear, tvHint: tvMatch != nil)
    }

    /// The title, then up to three parts of it ("Frieren - Sousou no Frieren"), deduplicated.
    static func queries(for title: String) -> [String] {
        let parts = querySplit.split(title)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return ([title] + parts.prefix(3)).filter { seen.insert($0).inserted }
    }
}

struct EpisodeNumber: Sendable, Hashable, Codable {
    var season: Int?
    var episode: Int?

    var needsSeason: Bool { episode != nil && season == nil }
    var isNumbered: Bool { episode != nil && season != nil }
}

/// Port of extract_episode_info / extract_bare_episode / guess_season / subfolder_season
/// and torbox_sync.number_files.
enum EpisodeNumbering {
    private static let seasonEpisode = [Pattern(#"[Ss](\d{1,2})[.\-_ ]?[Ee](\d{1,3})"#), Pattern(#"(\d{1,2})[xX](\d{2,3})"#)]
    private static let bareEpisode = Pattern(#"(?<![A-Za-z0-9])(?:Episode[ ._-]?|EP?)(\d{1,3})(?!\d)"#, ignoreCase: true)
    private static let leadingNumber = Pattern(#"\s*(\d{1,3})(?:\s*[-–.]\s*|\s+|_)(?=\D)"#)
    private static let seasonName = Pattern(
        #"\b(?:S|(?:Season|Saison|Temporada|Staffel|Stagione)[ ._-]?)(\d{1,2})\b"#, ignoreCase: true
    )

    /// Pattern A: (season, episode) or nil.
    static func extractEpisodeInfo(_ name: String) -> (season: Int, episode: Int)? {
        for pattern in seasonEpisode {
            if let match = pattern.first(in: name), let season = match.int(1), let episode = match.int(2) {
                return (season, episode)
            }
        }
        return nil
    }

    /// Pattern B: a bare episode number.
    static func extractBareEpisode(_ name: String) -> Int? {
        if let match = bareEpisode.first(in: name) { return match.int(1) }
        if let match = leadingNumber.first(in: name, anchored: true) { return match.int(1) }
        return nil
    }

    static func guessSeason(_ name: String) -> Int? {
        seasonName.first(in: name)?.int(1)
    }

    /// Season of the nearest subfolder between the root folder and the file.
    /// `decodedPath` is the file's decoded WebDAV path.
    static func subfolderSeason(decodedPath: String, rootName: String) -> Int? {
        let parts = decodedPath.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping }.dropLast()
        let root = rootName.precomposedStringWithCanonicalMapping.trimmingTrailing("/")
        guard let rootIndex = parts.lastIndex(of: root) else { return nil }
        for part in parts[(rootIndex + 1)...].reversed() {
            if let season = guessSeason(part) { return season }
        }
        return nil
    }

    struct Input: Sendable {
        let name: String
        let decodedPath: String
        let size: Int64
    }

    struct Output: Sendable, Equatable {
        let number: EpisodeNumber
        let isMain: Bool
    }

    /// `number_files(raw_name, override, items)`.
    static func number(rootName: String, override: JSONObject, files: [Input]) -> [Output] {
        if Overrides.mediaType(override) == "movie" && Py.truthy(override["title"]) {
            let main = files.indices.max { files[$0].size < files[$1].size }
            return files.indices.map { Output(number: EpisodeNumber(), isMain: $0 == main) }
        }
        let seasonOverride = Py.int(override["season"])
        let forced = Py.truthy(override["force_season"]) ? seasonOverride : nil
        return files.map { file in
            if let info = extractEpisodeInfo(file.name) {
                return Output(number: EpisodeNumber(season: forced ?? info.season, episode: info.episode), isMain: false)
            }
            guard let episode = extractBareEpisode(file.name) else {
                return Output(number: EpisodeNumber(), isMain: false)
            }
            let season = forced
                ?? subfolderSeason(decodedPath: file.decodedPath, rootName: rootName)
                ?? seasonOverride
                ?? guessSeason(rootName)
            return Output(number: EpisodeNumber(season: season, episode: episode), isMain: false)
        }
    }
}

extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var value = self
        while value.last == character { value.removeLast() }
        return value
    }
}
