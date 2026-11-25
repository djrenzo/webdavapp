import Foundation

struct EpisodeNumber: Sendable, Equatable {
    let season: Int?
    let episode: Int?

    var needsSeason: Bool { episode != nil && season == nil }
    var label: String {
        if let season, let episode { return "S\(season) · E\(episode)" }
        if let episode { return "Episode \(episode) · season needed" }
        return "Extra · unnumbered"
    }
}

enum EpisodeNumbering {
    static func number(
        name: String, subfolder: String, rootName: String,
        season: Int?, force: Bool
    ) -> EpisodeNumber {
        let forced = force ? season : nil
        let paired = [#"[Ss](\d{1,2})[.\-_ ]?[Ee](\d{1,3})"#, #"(\d{1,2})[xX](\d{2,3})"#]
        for pattern in paired {
            if let captures = captures(pattern, in: name), captures.count == 2 {
                return EpisodeNumber(season: forced ?? Int(captures[0]), episode: Int(captures[1]))
            }
        }
        let bare = [
            #"(?<![A-Za-z0-9])(?:Episode[ ._-]?|EP?)(\d{1,3})(?!\d)"#,
            #"^\s*(\d{1,3})(?:\s*[-–.]\s*|\s+|_)(?=\D)"#
        ]
        for pattern in bare {
            if let values = captures(pattern, in: name, insensitive: true),
               let episode = values.first.flatMap(Int.init) {
                let nearest = subfolder.split(separator: "/").reversed()
                    .compactMap { seasonInName(String($0)) }.first
                return EpisodeNumber(
                    season: forced ?? nearest ?? season ?? seasonInName(rootName), episode: episode
                )
            }
        }
        return EpisodeNumber(season: nil, episode: nil)
    }

    private static func seasonInName(_ name: String) -> Int? {
        let pattern = #"\b(?:S|(?:Season|Saison|Temporada|Staffel|Stagione)[ ._-]?)(\d{1,2})\b"#
        return captures(pattern, in: name, insensitive: true)?.first.flatMap(Int.init)
    }

    private static func captures(_ pattern: String, in text: String, insensitive: Bool = false) -> [String]? {
        let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap {
            guard let range = Range(match.range(at: $0), in: text) else { return nil }
            return String(text[range])
        }
    }
}
