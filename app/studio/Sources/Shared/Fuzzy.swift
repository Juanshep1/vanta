import Foundation

/// Subsequence fuzzy matcher (VS Code-ish): rewards consecutive runs, matches at
/// word starts / after separators / camelCase humps, and matches in the
/// basename. Returns nil when `query` isn't a subsequence of `candidate`.
enum Fuzzy {
    struct Match { let score: Int; let indices: [Int] }

    static func match(_ query: String, _ candidate: String) -> Match? {
        let q = Array(query.lowercased().utf16).filter { $0 != 32 }
        if q.isEmpty { return Match(score: 0, indices: []) }
        let c = Array(candidate.utf16)
        let cl = Array(candidate.lowercased().utf16)
        guard cl.count == c.count, q.count <= c.count else { return nil }

        // quick reject
        var qi = 0
        for ch in cl where qi < q.count && ch == q[qi] { qi += 1 }
        if qi < q.count { return nil }

        let lastSlash = c.lastIndex(of: 47) ?? -1           // "/"
        // Greedy from the left, then try to improve by preferring word starts:
        // a small DP over (query index, candidate index) with best score.
        let n = q.count, m = c.count
        let neg = Int.min / 4
        var best = [[Int]](repeating: [Int](repeating: neg, count: m), count: n)
        var from = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)

        func bonus(_ j: Int) -> Int {
            var b = 0
            if j == 0 { b += 8 }
            else {
                let p = c[j - 1]
                if p == 47 || p == 95 || p == 45 || p == 46 || p == 32 { b += 7 }          // / _ - . space
                else if isLower(p) && isUpper(c[j]) { b += 6 }                              // camelHump
            }
            if j > lastSlash { b += 3 }                                                     // basename
            return b
        }

        for j in 0..<m where cl[j] == q[0] {
            best[0][j] = 10 + bonus(j) - min(j, 10) / 3
        }
        if n > 1 {
            for i in 1..<n {
                var runBest = neg, runIdx = -1
                for j in i..<m {
                    // track best previous (j-1 and earlier) for gap transitions
                    let pj = j - 1
                    if pj >= 0 && best[i - 1][pj] > neg {
                        if best[i - 1][pj] > runBest { runBest = best[i - 1][pj]; runIdx = pj }
                    }
                    guard cl[j] == q[i] else { continue }
                    var s = neg, f = -1
                    // consecutive
                    if pj >= 0 && best[i - 1][pj] > neg { s = best[i - 1][pj] + 10 + bonus(j) + 6; f = pj }
                    // gap
                    if runIdx >= 0 && runIdx != pj {
                        let g = runBest + 10 + bonus(j) - min(j - runIdx, 8)
                        if g > s { s = g; f = runIdx }
                    }
                    best[i][j] = s; from[i][j] = f
                }
            }
        }
        var endJ = -1, endS = neg
        for j in 0..<m where best[n - 1][j] > endS { endS = best[n - 1][j]; endJ = j }
        guard endJ >= 0 else { return nil }
        var idx = [Int](repeating: 0, count: n)
        var j = endJ
        for i in stride(from: n - 1, through: 0, by: -1) {
            idx[i] = j
            j = from[i][j]
            if i > 0 && j < 0 { return nil }
        }
        // shorter candidates win ties
        return Match(score: endS - m / 8, indices: idx)
    }

    private static func isLower(_ u: UInt16) -> Bool { u >= 97 && u <= 122 }
    private static func isUpper(_ u: UInt16) -> Bool { u >= 65 && u <= 90 }
}

/// Glob → regex for include/exclude filters ("*.va", "lib/**", "{a,b}/*.md").
/// Patterns without a "/" match the file name or any directory name.
struct GlobMatcher {
    private let regexes: [(NSRegularExpression, Bool)]     // (regex, matchesComponent)

    init(_ patterns: String) {
        regexes = patterns.split(separator: ",").compactMap { raw -> (NSRegularExpression, Bool)? in
            var p = raw.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            if p.hasPrefix("./") { p.removeFirst(2) }
            let component = !p.contains("/")
            var re = "^"
            var i = p.startIndex
            var inBrace = false
            while i < p.endIndex {
                let ch = p[i]
                let next = p.index(after: i)
                switch ch {
                case "*":
                    if next < p.endIndex && p[next] == "*" {
                        re += ".*"
                        i = p.index(after: next)
                        if i < p.endIndex && p[i] == "/" { i = p.index(after: i); re += "(?:/)?" }
                        continue
                    }
                    re += "[^/]*"
                case "?": re += "[^/]"
                case "{": re += "(?:"; inBrace = true
                case "}": re += ")"; inBrace = false
                case ",": re += inBrace ? "|" : ","
                case ".", "(", ")", "+", "|", "^", "$", "[", "]", "\\": re += "\\" + String(ch)
                default: re += String(ch)
                }
                i = next
            }
            re += component ? "$" : "(?:/.*)?$"
            guard let r = try? NSRegularExpression(pattern: re, options: [.caseInsensitive]) else { return nil }
            return (r, component)
        }
    }

    var isEmpty: Bool { regexes.isEmpty }

    /// `relativePath` uses "/" separators, no leading slash.
    func matches(_ relativePath: String) -> Bool {
        let comps = relativePath.split(separator: "/").map(String.init)
        for (r, component) in regexes {
            if component {
                for c in comps where r.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) != nil {
                    return true
                }
            } else if r.firstMatch(in: relativePath, range: NSRange(location: 0, length: (relativePath as NSString).length)) != nil {
                return true
            }
        }
        return false
    }
}
