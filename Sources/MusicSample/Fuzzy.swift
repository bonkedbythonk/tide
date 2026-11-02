import Foundation

/// Forgiving text matching, after anicat's search: accents, case and apostrophes
/// don't matter, and a word may carry a typo or two ("narutp", "dont", "deja vu").
enum Fuzzy {
    /// Lowercased, accents folded, apostrophes dropped, other punctuation as spaces.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        for ch in folded {
            if ch == "'" || ch == "\u{2019}" || ch == "`" { continue }
            out.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return out
    }

    static func words(_ text: String) -> [Substring] {
        fold(text).split(separator: " ")
    }

    /// 0 when some word of the query matches nothing in `text`; otherwise higher
    /// for closer matches. A word matches as a substring, or as a word start
    /// within a slip or two.
    static func score(_ query: [Substring], in text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let target = words(text)
        let joined = target.joined(separator: " ")
        var total = 0
        for q in query {
            if target.contains(where: { $0.hasPrefix(q) }) {
                total += 4
            } else if joined.contains(q) {
                total += 3
            } else {
                let allowed = q.count <= 3 ? 0 : q.count <= 5 ? 1 : 2
                guard allowed > 0, target.contains(where: {
                    distance(Array(q), Array($0.prefix(q.count))) <= allowed
                        || distance(Array(q), Array($0)) <= allowed
                }) else { return 0 }
                total += 1
            }
        }
        return total
    }

    /// Edit distance where swapping two neighbouring letters counts as one slip.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
