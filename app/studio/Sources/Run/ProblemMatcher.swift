import Foundation

/// Turns runtime errors printed by a run into Problems (source "run").
///
/// Vanta reports errors as
///
///     Oops! line 3: I don't know what 'totl' is yet
///       --> shop.va:3
///        |
///      3 |     give back totl + tax
///        |               ^^^^
///        = hint: did you mean 'total'?
///
/// Uncaught Python exceptions (an interpreter bug) are matched by their last
/// `File "…va", line N` frame.
enum ProblemMatcher {
    static let source = "run"

    struct Problem: Equatable {
        var file: URL
        var line: Int            // 1-based
        var column: Int?         // 0-based (from the ^ caret line)
        var message: String
    }

    static func match(_ output: String, resolve: (String) -> URL?, mainFile: URL?) -> [Problem] {
        var out: [Problem] = []
        let lines = output.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if let r = l.range(of: "Oops! ") {
                var msg = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                var lineNo: Int?
                if let m = msg.firstMatch(of: #/^line (\d+): (.*)$/#) {
                    lineNo = Int(m.1); msg = String(m.2)
                }
                var file: URL? = nil
                var col: Int? = nil
                var hint: String?
                var j = i + 1
                while j < lines.count && j <= i + 8 {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let m = t.firstMatch(of: #/^--> (.+):(\d+)$/#) {
                        file = resolve(String(m.1)); lineNo = Int(m.2) ?? lineNo
                    } else if t.hasPrefix("= hint:") {
                        hint = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    } else if t.contains("|"), let caret = lines[j].firstIndex(of: "^"),
                              let bar = lines[j].firstIndex(of: "|") {
                        col = max(0, lines[j].distance(from: bar, to: caret) - 2)
                    } else if t.hasPrefix("Oops!") { break }
                    j += 1
                }
                if let lineNo, let f = file ?? mainFile {
                    if let hint { msg += " (\(hint))" }
                    out.append(Problem(file: f, line: lineNo, column: col, message: msg))
                }
                i = j
                continue
            }
            if l.hasPrefix("Traceback (most recent call last)") {
                var last: (String, Int)?
                var j = i + 1
                while j < lines.count {
                    let t = lines[j]
                    if let m = t.firstMatch(of: #/File "([^"]+\.va)", line (\d+)/#) { last = (String(m.1), Int(m.2) ?? 1) }
                    if !t.hasPrefix(" ") && !t.isEmpty {
                        if let last, let f = resolve(last.0) {
                            out.append(Problem(file: f, line: last.1, column: nil, message: t))
                        }
                        break
                    }
                    j += 1
                }
                i = j + 1
                continue
            }
            i += 1
        }
        return out
    }

    /// Publish problems (grouped per file) and clear files that no longer have any.
    static func publish(_ problems: [Problem]) {
        let d = DiagnosticsStore.shared
        d.clear(source: source)
        var byFile: [URL: [Diagnostic]] = [:]
        for p in problems {
            let line = max(0, p.line - 1)
            var range = TextRange.line(line)
            if let c = p.column, c >= 0 {
                range = TextRange(start: TextPosition(line: line, column: c), end: TextPosition(line: line, column: Int.max / 4))
            }
            byFile[FilePaths.documentURI(for: p.file), default: []].append(
                Diagnostic(range: range, severity: .error, message: p.message, source: source))
        }
        for (u, diags) in byFile { d.publish(diags, for: u, source: source) }
    }
}
