import Foundation

/// A Vanta block: the opener line (`to`, `if`, `repeat`, `type`, `match`, …) and
/// the line of its matching `end`. `mids` are `otherwise` / `rescue` / `when`
/// lines that belong to it.
struct CodeBlock: Hashable {
    var start: Int
    var end: Int
    var head: String
    var mids: [Int] = []
}

/// Line classification + block matching for folding, `to…end` highlighting and
/// smart indentation. Mirrors `vanta fmt`'s rules (vanta_tools/fmt.py).
enum BlockStructure {
    enum LineRole { case none, opener(String), mid(String), end }

    /// Classify a line's text (no newline).
    static func role(of line: String) -> LineRole {
        var t = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let f = t.first, f.isLetter || f == "_" else { return .none }
        var head = String(t.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        if head == "private" || head == "shared" {
            t = t.dropFirst(head.count).drop { $0 == " " || $0 == "\t" }
            head = String(t.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        let rest = t.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
        switch head {
        case "end": return .end
        case "otherwise", "rescue": return .mid(head)
        case "when": return .mid("when")
        case "if":
            // `if` statement (not a trailing inline-if); inline-if never starts a line
            return .opener(head)
        case "repeat", "while", "to", "attempt", "type", "match", "using", "lock":
            return .opener(head)
        case "for":
            return rest.hasPrefix("each") ? .opener(head) : .none
        case "test":
            return rest.hasPrefix("\"") ? .opener(head) : .none
        case "kind":
            // `kind Suit` opens a block; `kind Light is red, green` is one line
            let words = rest.split(separator: " ")
            return words.count == 1 ? .opener(head) : .none
        default:
            return .none
        }
    }

    /// Does pressing Return after this line indent the next one?
    static func opensIndent(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.isEmpty { return false }
        switch role(of: line) {
        case .opener, .mid: return true
        default:
            // unbalanced opening bracket at end of line: [ { (
            if let last = trimmed.last, "([{".contains(last) { return true }
            return false
        }
    }

    /// Compute all blocks. `inTripleAtStart(l)` says whether line l begins inside
    /// a triple-quoted string (so it's not code).
    static func analyze(_ ns: NSString, lines: LineIndex, inTripleAtStart: (Int) -> Bool) -> [CodeBlock] {
        var stack: [CodeBlock] = []
        var out: [CodeBlock] = []
        let n = lines.count
        for l in 0..<n {
            if inTripleAtStart(l) { continue }
            let r = lines.contentRange(of: l, in: ns)
            if r.length == 0 { continue }
            // read just the first ~40 chars — enough to classify
            let head = ns.substring(with: NSRange(location: r.location, length: min(r.length, 60)))
            switch role(of: head) {
            case .opener(let h):
                stack.append(CodeBlock(start: l, end: l, head: h))
            case .mid(let h):
                if !stack.isEmpty {
                    if h == "when" && stack.last?.head != "match" { break }
                    stack[stack.count - 1].mids.append(l)
                }
            case .end:
                if var b = stack.popLast() { b.end = l; out.append(b) }
            case .none: break
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
