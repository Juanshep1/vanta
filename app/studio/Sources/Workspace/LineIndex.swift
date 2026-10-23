import Foundation

/// Start offsets of every line, maintained incrementally as the text changes so
/// line lookups stay O(log n) even on very large files.
struct LineIndex {
    /// starts[i] = UTF-16 offset of the first character of line i. Always ≥ 1 entry.
    private(set) var starts: [Int] = [0]
    private(set) var length: Int = 0

    var count: Int { starts.count }

    mutating func rebuild(_ s: NSString) {
        length = s.length
        starts = [0]
        starts.reserveCapacity(length / 30 + 1)
        let chunk = 16384
        var buf = [unichar](repeating: 0, count: chunk)
        var pos = 0
        while pos < length {
            let n = min(chunk, length - pos)
            s.getCharacters(&buf, range: NSRange(location: pos, length: n))
            for k in 0..<n where buf[k] == 10 { starts.append(pos + k + 1) }
            pos += n
        }
    }

    /// Update after `editedRange` (in the new text) replaced `editedRange.length - delta` old chars.
    mutating func apply(editedRange: NSRange, delta: Int, in s: NSString) {
        let oldEnd = editedRange.location + editedRange.length - delta     // end of replaced span in old text
        // lines whose start lies strictly inside (location, oldEnd] are gone
        let first = upperBound(editedRange.location)                         // first start > location
        var last = first
        while last < starts.count && starts[last] <= oldEnd { last += 1 }
        // new line starts inside the edited range
        var inserted: [Int] = []
        if editedRange.length > 0 {
            var buf = [unichar](repeating: 0, count: editedRange.length)
            s.getCharacters(&buf, range: editedRange)
            for k in 0..<editedRange.length where buf[k] == 10 { inserted.append(editedRange.location + k + 1) }
        }
        if delta != 0 { for i in last..<starts.count { starts[i] += delta } }
        starts.replaceSubrange(first..<last, with: inserted)
        length = s.length
    }

    /// Index of the first start strictly greater than `offset`.
    private func upperBound(_ offset: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 0-based line containing `offset` (clamped).
    func line(at offset: Int) -> Int { max(0, upperBound(offset) - 1) }

    func start(of line: Int) -> Int {
        starts[max(0, min(line, starts.count - 1))]
    }

    /// Range of the line including its trailing newline.
    func range(of line: Int) -> NSRange {
        let l = max(0, min(line, starts.count - 1))
        let s = starts[l]
        let e = l + 1 < starts.count ? starts[l + 1] : length
        return NSRange(location: s, length: e - s)
    }

    /// Range of the line excluding the trailing newline.
    func contentRange(of line: Int, in s: NSString) -> NSRange {
        var r = range(of: line)
        if r.length > 0 && NSMaxRange(r) <= s.length && s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }

    func position(of offset: Int) -> TextPosition {
        let o = max(0, min(offset, length))
        let l = line(at: o)
        return TextPosition(line: l, column: o - starts[l])
    }

    func offset(of p: TextPosition) -> Int {
        guard p.line < starts.count else { return length }
        let r = range(of: max(0, p.line))
        let hasNewline = p.line + 1 < starts.count
        let maxCol = max(0, r.length - (hasNewline ? 1 : 0))
        return r.location + min(max(0, p.column), maxCol)
    }
}
