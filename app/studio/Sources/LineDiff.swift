import Foundation

enum DiffKind { case same, add, remove }

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffKind
    let text: String
}

// A simple LCS line diff for the ⌘K edit review.
enum LineDiff {
    static func diff(_ a: String, _ b: String) -> [DiffLine] {
        let al = a.components(separatedBy: "\n")
        let bl = b.components(separatedBy: "\n")
        let n = al.count, m = bl.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = al[i] == bl[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var i = 0, j = 0
        var out: [DiffLine] = []
        while i < n && j < m {
            if al[i] == bl[j] { out.append(DiffLine(kind: .same, text: al[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append(DiffLine(kind: .remove, text: al[i])); i += 1 }
            else { out.append(DiffLine(kind: .add, text: bl[j])); j += 1 }
        }
        while i < n { out.append(DiffLine(kind: .remove, text: al[i])); i += 1 }
        while j < m { out.append(DiffLine(kind: .add, text: bl[j])); j += 1 }
        return out
    }
}
