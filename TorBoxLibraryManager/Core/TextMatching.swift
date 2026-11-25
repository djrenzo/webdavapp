import Foundation

/// A compiled regular expression. Offsets are UTF-16 based, consistently, so cut points
/// and comparisons behave like the Python originals (which use code points).
final class Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            fatalError("Invalid pattern \(pattern): \(error)")
        }
    }

    /// `re.search` (or `re.match` when anchored).
    func first(in text: String, anchored: Bool = false) -> PatternMatch? {
        let ns = text as NSString
        let options: NSRegularExpression.MatchingOptions = anchored ? [.anchored] : []
        guard let match = regex.firstMatch(in: text, options: options, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return PatternMatch(match, ns)
    }

    /// `re.finditer`.
    func all(in text: String) -> [PatternMatch] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { PatternMatch($0, ns) }
    }

    /// `re.sub` with a literal replacement.
    func replace(in text: String, with replacement: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// `re.split` (without capture groups).
    func split(_ text: String) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var location = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: location, length: match.range.location - location)))
            location = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: location))
        return parts
    }
}

struct PatternMatch {
    let start: Int
    let length: Int
    let groups: [String?]

    init(_ match: NSTextCheckingResult, _ text: NSString) {
        start = match.range.location
        length = match.range.length
        groups = (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
    }

    func group(_ index: Int) -> String? { index < groups.count ? groups[index] : nil }
    func int(_ index: Int) -> Int? { group(index).flatMap { Int($0) } }
}

enum TextMatching {
    private static let nonAlphanumeric = Pattern(#"[^a-z0-9]+"#)
    private static let leadingArticle = Pattern(#"^(?:the|a|an|el|la|los|las|le|les|der|die|das) "#)

    /// `_normalize` of torbox_identify: NFKD without combining marks, lowercase, `&` -> and,
    /// runs outside [a-z0-9] -> one space, one leading article dropped.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars
        where scalar.properties.canonicalCombiningClass == .notReordered {
            scalars.append(scalar)
        }
        var value = String(scalars).lowercased()
        value = value.replacingOccurrences(of: "&", with: " and ")
        value = nonAlphanumeric.replace(in: value, with: " ").trimmingCharacters(in: .whitespaces)
        return leadingArticle.replace(in: value, with: "")
    }

    /// Python `difflib.SequenceMatcher(None, a, b).ratio()`, ported exactly
    /// (Ratcliff/Obershelp matching blocks, including the autojunk rule).
    static func ratio(_ a: String, _ b: String) -> Double {
        SequenceMatcher(Array(a.unicodeScalars), Array(b.unicodeScalars)).ratio()
    }
}

struct SequenceMatcher {
    private let a: [Unicode.Scalar]
    private let b: [Unicode.Scalar]
    private var b2j: [Unicode.Scalar: [Int]] = [:]

    init(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) {
        self.a = a
        self.b = b
        for (index, element) in b.enumerated() {
            b2j[element, default: []].append(index)
        }
        let n = b.count
        if n >= 200 {
            let ntest = n / 100 + 1
            let popular = b2j.filter { $0.value.count > ntest }.map(\.key)
            for element in popular { b2j.removeValue(forKey: element) }
        }
    }

    private func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        // No junk (isjunk is None), so only the non-junk extension loops can apply.
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1
            bestj -= 1
            bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    func matchingCharacters() -> Int {
        var queue = [(0, a.count, 0, b.count)]
        var total = 0
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = findLongestMatch(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            total += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return total
    }

    func ratio() -> Double {
        let length = a.count + b.count
        guard length > 0 else { return 1.0 }
        return 2.0 * Double(matchingCharacters()) / Double(length)
    }
}
