import Foundation

/// Line diff (Myers' O(ND) algorithm, after trimming the common prefix and
/// suffix) plus the shapes the UI needs: side-by-side rows, inline hunks and
/// gutter change markers.
enum LineDiffer {
    enum Op: Equatable { case equal(Int, Int), delete(Int), insert(Int) }   // old index / new index

    static func lines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var l = s.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    static func diff(_ a: [String], _ b: [String], maxEdits: Int = 4000) -> [Op] {
        var pre = 0
        while pre < a.count && pre < b.count && a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre && suf < b.count - pre && a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let A = Array(a[pre..<(a.count - suf)]), B = Array(b[pre..<(b.count - suf)])
        var ops: [Op] = (0..<pre).map { .equal($0, $0) }
        ops += middle(A, B, maxEdits: maxEdits).map {
            switch $0 {
            case .equal(let i, let j): return .equal(i + pre, j + pre)
            case .delete(let i): return .delete(i + pre)
            case .insert(let j): return .insert(j + pre)
            }
        }
        ops += (0..<suf).map { .equal(a.count - suf + $0, b.count - suf + $0) }
        return ops
    }

    private static func middle(_ a: [String], _ b: [String], maxEdits: Int) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        // hash lines to ints for fast comparison
        var ids: [String: Int] = [:]
        let ah = a.map { s -> Int in if let v = ids[s] { return v }; let v = ids.count; ids[s] = v; return v }
        let bh = b.map { s -> Int in if let v = ids[s] { return v }; let v = ids.count; ids[s] = v; return v }
        let maxD = min(n + m, maxEdits)
        let off = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off]) { x = v[k + 1 + off] } else { x = v[k - 1 + off] + 1 }
                var y = x - k
                while x < n && y < m && ah[x] == bh[y] { x += 1; y += 1 }
                v[k + off] = x
                if x >= n && y >= m { found = true; trace.append(v); break outer }
                k += 2
            }
        }
        guard found else {
            // too different: show it as a full replacement
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }
        // backtrack
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd[k - 1 + off] < vd[k + 1 + off]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vd[prevK + off]
            let prevY = prevX - prevK
            while x > prevX && y > prevY { x -= 1; y -= 1; ops.append(.equal(x, y)) }
            if d > 0 {
                if x == prevX { y -= 1; ops.append(.insert(y)) } else { x -= 1; ops.append(.delete(x)) }
            }
        }
        while x > 0 && y > 0 { x -= 1; y -= 1; ops.append(.equal(x, y)) }
        return ops.reversed()
    }

    // MARK: side-by-side

    struct Row: Identifiable, Hashable {
        enum Kind { case same, changed, added, removed, fold }
        let id: Int
        let kind: Kind
        let left: (Int, String)?
        let right: (Int, String)?
        var foldCount = 0
        static func == (a: Row, b: Row) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Rows for a two-column view; unchanged runs longer than 2×context fold.
    static func rows(_ a: [String], _ b: [String], context: Int = 3) -> [Row] {
        let ops = diff(a, b)
        var raw: [Row] = []
        var i = 0
        var id = 0
        while i < ops.count {
            if case .equal(let x, let y) = ops[i] {
                raw.append(Row(id: id, kind: .same, left: (x, a[x]), right: (y, b[y]))); id += 1; i += 1; continue
            }
            var dels: [Int] = [], ins: [Int] = []
            while i < ops.count {
                if case .delete(let x) = ops[i] { dels.append(x) } else if case .insert(let y) = ops[i] { ins.append(y) } else { break }
                i += 1
            }
            for k in 0..<max(dels.count, ins.count) {
                let l = k < dels.count ? (dels[k], a[dels[k]]) : nil
                let r = k < ins.count ? (ins[k], b[ins[k]]) : nil
                let kind: Row.Kind = l != nil && r != nil ? .changed : (l != nil ? .removed : .added)
                raw.append(Row(id: id, kind: kind, left: l, right: r)); id += 1
            }
        }
        // fold long unchanged stretches
        var out: [Row] = []
        var j = 0
        while j < raw.count {
            if raw[j].kind != .same { out.append(raw[j]); j += 1; continue }
            var e = j
            while e < raw.count && raw[e].kind == .same { e += 1 }
            let run = e - j
            let keepHead = j == 0 ? 0 : context
            let keepTail = e == raw.count ? 0 : context
            if run > keepHead + keepTail + 1 {
                out += raw[j..<(j + keepHead)]
                out.append(Row(id: 1_000_000 + j, kind: .fold, left: nil, right: nil, foldCount: run - keepHead - keepTail))
                out += raw[(e - keepTail)..<e]
            } else {
                out += raw[j..<e]
            }
            j = e
        }
        return out
    }

    // MARK: gutter markers

    enum Marker: Equatable { case added, modified, deletedAbove }

    /// 0-based line in the new text → marker.
    static func markers(old: [String], new: [String]) -> [Int: Marker] {
        let ops = diff(old, new)
        var out: [Int: Marker] = [:]
        var i = 0
        var nextNew = 0
        while i < ops.count {
            if case .equal(_, let y) = ops[i] { nextNew = y + 1; i += 1; continue }
            var dels = 0
            var ins: [Int] = []
            while i < ops.count {
                if case .delete = ops[i] { dels += 1 } else if case .insert(let y) = ops[i] { ins.append(y) } else { break }
                i += 1
            }
            if ins.isEmpty {
                out[min(nextNew, max(0, new.count - 1))] = out[min(nextNew, max(0, new.count - 1))] ?? .deletedAbove
            } else {
                for (k, y) in ins.enumerated() { out[y] = k < dels ? .modified : .added }
                nextNew = (ins.last ?? nextNew) + 1
            }
        }
        return out
    }
}
