import Foundation

/// Gutter change markers per file (0-based line → kind): the Run module's git
/// integration writes them, the editor gutter draws a thin coloured bar.
enum LineChangeKind { case added, modified, deletedAbove }

final class LineMarkerStore {
    static let shared = LineMarkerStore()
    private(set) var byURI: [URL: [Int: LineChangeKind]] = [:]

    func set(_ markers: [Int: LineChangeKind], for uri: URL) {
        byURI[uri.standardizedFileURL] = markers.isEmpty ? nil : markers
    }

    func markers(for uri: URL) -> [Int: LineChangeKind] { byURI[uri.standardizedFileURL] ?? [:] }
}
