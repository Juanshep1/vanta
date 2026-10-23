import Foundation

enum DiffKind { case same, add, remove }

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffKind
    let text: String
}

/// A contiguous change between a base text and a new text (0-based line indexes).
struct DiffHunk: Identifiable, Hashable {
    var id: String { "\(baseStart):\(baseLines.count):\(newStart):\(newLines.count)" }
    let baseStart: Int
    let baseLines: [String]
    let newStart: Int
    let newLines: [String]
}

/// LCS line diff (used by the editor's inline diff, ⌘K, and the agent's
/// Review Changes list). Common prefix/suffix lines are trimmed first so big
/// files with small edits stay fast.
enum LineDiff {
    static func diff(_ a: String, _ b: String) -> [DiffLine] {
        diffLines(a.components(separatedBy: "\n"), b.components(separatedBy: "\n"))
    }

    static func diffLines(_ al: [String], _ bl: [String]) -> [DiffLine] {
        var pre = 0
        while pre < al.count && pre < bl.count && al[pre] == bl[pre] { pre += 1 }
        var suf = 0
        while suf < al.count - pre && suf < bl.count - pre && al[al.count - 1 - suf] == bl[bl.count - 1 - suf] { suf += 1 }
        let a = Array(al[pre..<(al.count - suf)]), b = Array(bl[pre..<(bl.count - suf)])
        var out: [DiffLine] = al[0..<pre].map { DiffLine(kind: .same, text: $0) }
        let n = a.count, m = b.count
        if n * m > 4_000_000 {
            // too big for LCS: replace the middle wholesale
            out += a.map { DiffLine(kind: .remove, text: $0) } + b.map { DiffLine(kind: .add, text: $0) }
        } else {
            var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n && j < m {
                if a[i] == b[j] { out.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1 }
                else if dp[i + 1][j] >= dp[i][j + 1] { out.append(DiffLine(kind: .remove, text: a[i])); i += 1 }
                else { out.append(DiffLine(kind: .add, text: b[j])); j += 1 }
            }
            while i < n { out.append(DiffLine(kind: .remove, text: a[i])); i += 1 }
            while j < m { out.append(DiffLine(kind: .add, text: b[j])); j += 1 }
        }
        out += al[(al.count - suf)...].map { DiffLine(kind: .same, text: $0) }
        return out
    }

    static func hunks(_ base: String, _ new: String) -> [DiffHunk] {
        let d = diff(base, new)
        var out: [DiffHunk] = []
        var bi = 0, ni = 0
        var k = 0
        while k < d.count {
            if d[k].kind == .same { bi += 1; ni += 1; k += 1; continue }
            let bs = bi, ns = ni
            var bl: [String] = [], nl: [String] = []
            while k < d.count && d[k].kind != .same {
                if d[k].kind == .remove { bl.append(d[k].text); bi += 1 } else { nl.append(d[k].text); ni += 1 }
                k += 1
            }
            out.append(DiffHunk(baseStart: bs, baseLines: bl, newStart: ns, newLines: nl))
        }
        return out
    }

    /// `new` with one hunk undone (its lines go back to the base version).
    static func revert(_ h: DiffHunk, in new: String) -> String {
        var lines = new.components(separatedBy: "\n")
        guard h.newStart <= lines.count, h.newStart + h.newLines.count <= lines.count else { return new }
        lines.replaceSubrange(h.newStart..<(h.newStart + h.newLines.count), with: h.baseLines)
        return lines.joined(separator: "\n")
    }

    /// `base` with one hunk applied (accepting that hunk into the baseline).
    static func apply(_ h: DiffHunk, to base: String) -> String {
        var lines = base.components(separatedBy: "\n")
        guard h.baseStart <= lines.count, h.baseStart + h.baseLines.count <= lines.count else { return base }
        lines.replaceSubrange(h.baseStart..<(h.baseStart + h.baseLines.count), with: h.newLines)
        return lines.joined(separator: "\n")
    }

    static func stats(_ base: String, _ new: String) -> (added: Int, removed: Int) {
        let h = hunks(base, new)
        return (h.reduce(0) { $0 + $1.newLines.count }, h.reduce(0) { $0 + $1.baseLines.count })
    }

    /// Smallest whole-line range of `old` that differs from `new`, with the
    /// replacement text — for showing a focused inline diff in the editor.
    static func changedRegion(old: String, new: String) -> (range: NSRange, replacement: String)? {
        guard old != new else { return nil }
        let o = old.components(separatedBy: "\n"), n = new.components(separatedBy: "\n")
        var pre = 0
        while pre < o.count && pre < n.count && o[pre] == n[pre] { pre += 1 }
        var suf = 0
        while suf < o.count - pre && suf < n.count - pre && o[o.count - 1 - suf] == n[n.count - 1 - suf] { suf += 1 }
        let ns = old as NSString
        var start = 0
        for l in o[0..<pre] { start += (l as NSString).length + 1 }
        let oldMid = o[pre..<(o.count - suf)]
        var len = oldMid.reduce(0) { $0 + ($1 as NSString).length + 1 }
        var repl = n[pre..<(n.count - suf)].map { $0 + "\n" }.joined()
        if start + len > ns.length {                       // the change touches the last line (no trailing \n)
            if repl.hasSuffix("\n") { repl.removeLast() }
            if start > ns.length {                         // pure append after the last line
                start = ns.length; len = 0; repl = "\n" + repl
            } else {
                len = ns.length - start
            }
        }
        return (NSRange(location: start, length: len), repl)
    }
}
