import Foundation

/// Tokeniser shared by the book and codebase indexes: lower-cased words and
/// identifiers, snake_case split into parts (the whole identifier is kept too),
/// light plural stemming, English filler words dropped. Vanta keywords such as
/// `to`, `be`, `is`, `each` are kept — they matter in a Vanta question.
enum Tokenizer {
    static let stopwords: Set<String> = [
        "the", "a", "an", "of", "it", "its", "this", "that", "these", "those", "how", "do", "does", "did", "i",
        "you", "me", "my", "your", "what", "can", "are", "was", "were", "will", "would", "should", "could",
        "please", "about", "which", "there", "their", "them", "then", "than", "also", "just", "so", "very",
        "we", "our", "he", "she", "they", "on", "or", "and", "but", "into", "here", "some", "any", "all",
        "have", "had", "been", "being", "one", "get", "got", "way", "want", "like",
    ]

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(text.utf16.count / 5)
        var cur = [UInt16]()
        func flush() {
            guard !cur.isEmpty else { return }
            let w = String(utf16CodeUnits: cur, count: cur.count)
            cur.removeAll(keepingCapacity: true)
            add(w, &out)
        }
        for u in text.utf16 {
            switch u {
            case 65...90: cur.append(u + 32)                    // A-Z → a-z
            case 97...122, 48...57, 95: cur.append(u)            // a-z 0-9 _
            default: flush()
            }
        }
        flush()
        return out
    }

    private static func add(_ w: String, _ out: inout [String]) {
        if w.contains("_") {
            let parts = w.split(separator: "_").map(String.init).filter { $0.count > 1 }
            if parts.count > 1 { out.append(w) }
            for p in parts { add(p, &out) }
            return
        }
        guard w.count > 1 || w.first?.isNumber == true, !stopwords.contains(w) else { return }
        out.append(stem(w))
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4 else { return w }
        if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("s") && !w.hasSuffix("ss") && !w.hasSuffix("us") && !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }
}

/// Okapi BM25 over a fixed set of documents (rebuild to update — it takes a
/// few milliseconds for thousands of chunks).
final class BM25Index {
    private var postings: [String: [(doc: Int, tf: Int)]] = [:]
    private var lengths: [Int] = []
    private var avgLength: Double = 1
    let k1 = 1.2, b = 0.75

    var count: Int { lengths.count }

    init(documents: [[String]]) {
        lengths = documents.map(\.count)
        avgLength = max(1, Double(lengths.reduce(0, +)) / Double(max(1, lengths.count)))
        for (i, toks) in documents.enumerated() {
            var tf: [String: Int] = [:]
            for t in toks { tf[t, default: 0] += 1 }
            for (t, n) in tf { postings[t, default: []].append((i, n)) }
        }
    }

    /// Top `k` documents for the query tokens, best first. `filter` can exclude documents.
    func search(_ query: [String], k: Int, filter: ((Int) -> Bool)? = nil) -> [(doc: Int, score: Double)] {
        let n = Double(lengths.count)
        guard n > 0 else { return [] }
        var scores: [Int: Double] = [:]
        for term in Set(query) {
            guard let list = postings[term] else { continue }
            let df = Double(list.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for (doc, tf) in list {
                if let filter, !filter(doc) { continue }
                let f = Double(tf)
                let dl = Double(lengths[doc])
                scores[doc, default: 0] += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgLength))
            }
        }
        return scores.sorted { $0.value > $1.value }.prefix(k).map { ($0.key, $0.value) }
    }
}
