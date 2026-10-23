import Foundation
import Combine

// Language-feature extension points. All positions are **0-based** (line and
// UTF-16 column), exactly like LSP, so an LSP client can pass them straight
// through. Use `EditorController.offset(of:)` / `position(of:)` to convert.

struct TextPosition: Hashable, Comparable, Codable {
    var line: Int
    var column: Int
    init(line: Int, column: Int) { self.line = line; self.column = column }
    static func < (a: TextPosition, b: TextPosition) -> Bool { (a.line, a.column) < (b.line, b.column) }
}

struct TextRange: Hashable, Codable {
    var start: TextPosition
    var end: TextPosition
    init(start: TextPosition, end: TextPosition) { self.start = start; self.end = end }
    /// Whole line(s) helper.
    static func line(_ l: Int) -> TextRange {
        TextRange(start: TextPosition(line: l, column: 0), end: TextPosition(line: l, column: Int.max / 4))
    }
}

/// A file location (for go-to-definition, problems, search results, stack frames).
struct Location: Hashable {
    var uri: URL
    var range: TextRange
}

// MARK: - Diagnostics

enum DiagnosticSeverity: Int, Comparable, Codable {
    case error = 1, warning = 2, info = 3, hint = 4
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct Diagnostic: Identifiable, Hashable {
    let id = UUID()
    var range: TextRange
    var severity: DiagnosticSeverity
    var message: String
    /// Who produced it ("vanta check", "lsp", "run") — diagnostics are stored per (uri, source).
    var source: String
    var code: String? = nil

    init(range: TextRange, severity: DiagnosticSeverity, message: String, source: String, code: String? = nil) {
        self.range = range; self.severity = severity; self.message = message; self.source = source; self.code = code
    }

    /// Convenience: a diagnostic covering a whole (0-based) line.
    init(line: Int, severity: DiagnosticSeverity = .error, message: String, source: String) {
        self.init(range: .line(line), severity: severity, message: message, source: source)
    }
}

/// Anything that can receive diagnostics. `DiagnosticsStore.shared` is the sink;
/// editors, the gutter, the Problems panel and the status bar all read from it.
protocol DiagnosticsSink: AnyObject {
    /// Replace all diagnostics from `source` for `uri`. Pass [] to clear.
    func publish(_ diagnostics: [Diagnostic], for uri: URL, source: String)
    func clear(source: String)
}

final class DiagnosticsStore: ObservableObject, DiagnosticsSink {
    static let shared = DiagnosticsStore()
    /// uri → source → diagnostics
    @Published private(set) var store: [URL: [String: [Diagnostic]]] = [:]
    let changed = PassthroughSubject<URL, Never>()

    func publish(_ diagnostics: [Diagnostic], for uri: URL, source: String) {
        var bySource = store[uri] ?? [:]
        bySource[source] = diagnostics.isEmpty ? nil : diagnostics
        store[uri] = bySource.isEmpty ? nil : bySource
        changed.send(uri)
    }

    func clear(source: String) {
        for uri in Array(store.keys) { publish([], for: uri, source: source) }
    }

    func diagnostics(for uri: URL) -> [Diagnostic] {
        (store[uri] ?? [:]).values.flatMap { $0 }.sorted { $0.range.start < $1.range.start }
    }

    var all: [(URL, [Diagnostic])] {
        store.keys.sorted { $0.path < $1.path }.map { ($0, diagnostics(for: $0)) }
    }

    var errorCount: Int { store.values.flatMap { $0.values.flatMap { $0 } }.filter { $0.severity == .error }.count }
    var warningCount: Int { store.values.flatMap { $0.values.flatMap { $0 } }.filter { $0.severity == .warning }.count }
}

// MARK: - Breakpoints

/// Breakpoints per file (0-based lines). The gutter toggles them; the debugger
/// (Run/) reads `lines(for:)` and observes `changed`.
final class BreakpointStore: ObservableObject {
    static let shared = BreakpointStore()
    @Published private(set) var byURI: [URL: Set<Int>] = [:]
    let changed = PassthroughSubject<URL, Never>()

    func lines(for uri: URL) -> Set<Int> { byURI[uri] ?? [] }

    func toggle(_ line: Int, in uri: URL) {
        var s = byURI[uri] ?? []
        if s.contains(line) { s.remove(line) } else { s.insert(line) }
        set(s, for: uri)
    }

    func set(_ lines: Set<Int>, for uri: URL) {
        byURI[uri] = lines.isEmpty ? nil : lines
        changed.send(uri)
    }

    /// Keep breakpoints on the same code when lines are inserted/removed above them.
    func shift(uri: URL, afterLine: Int, by delta: Int) {
        guard delta != 0, let s = byURI[uri], !s.isEmpty else { return }
        var out = Set<Int>()
        for l in s {
            if l > afterLine { let n = l + delta; if n > afterLine { out.insert(n) } } else { out.insert(l) }
        }
        if out != s { set(out, for: uri) }
    }
}

// MARK: - Provider protocols

/// What a provider gets to look at. `text` is a snapshot; `offset` is a UTF-16 index.
struct DocumentContext {
    let uri: URL
    let text: String
    let languageID: String
    let offset: Int
    let position: TextPosition
}

enum CompletionKind: String {
    case keyword, function, method, variable, type, module, property, constant, snippet, text, file
    var symbol: String {
        switch self {
        case .keyword: return "k.square"
        case .function, .method: return "f.square"
        case .variable: return "v.square"
        case .type: return "t.square"
        case .module: return "shippingbox"
        case .property: return "p.square"
        case .constant: return "c.square"
        case .snippet: return "curlybraces.square"
        case .text: return "textformat"
        case .file: return "doc"
        }
    }
}

struct CompletionItem: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var kind: CompletionKind
    var detail: String? = nil
    var documentation: String? = nil
    /// Text to insert (defaults to label). Use "$0" to mark where the cursor ends up.
    var insertText: String? = nil
    var sortPriority: Int = 0          // higher sorts first among equal fuzzy scores

    init(label: String, kind: CompletionKind, detail: String? = nil, documentation: String? = nil,
         insertText: String? = nil, sortPriority: Int = 0) {
        self.label = label; self.kind = kind; self.detail = detail; self.documentation = documentation
        self.insertText = insertText; self.sortPriority = sortPriority
    }
}

protocol CompletionProvider: AnyObject {
    var id: String { get }
    /// Characters that open the popup immediately (e.g. ".").
    var triggerCharacters: Set<Character> { get }
    /// `prefix` is the identifier fragment before the cursor (may be empty).
    func completions(_ ctx: DocumentContext, prefix: String) async -> [CompletionItem]
}

struct HoverInfo {
    /// Plain text or light Markdown (`code`, **bold**, ``` blocks).
    var markdown: String
    var range: NSRange? = nil
}

protocol HoverProvider: AnyObject {
    var id: String { get }
    func hover(_ ctx: DocumentContext) async -> HoverInfo?
}

enum SymbolKind: String {
    case function, type, kind, variable, constant, test, method, field
    var symbol: String {
        switch self {
        case .function, .method: return "f.cursive"
        case .type: return "t.square"
        case .kind: return "list.bullet.rectangle"
        case .variable: return "v.square"
        case .constant: return "c.square"
        case .test: return "checkmark.seal"
        case .field: return "p.square"
        }
    }
}

struct DocumentSymbol: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var kind: SymbolKind
    var detail: String = ""
    /// 0-based line of the declaration.
    var line: Int
    var endLine: Int? = nil
    var children: [DocumentSymbol] = []
}

protocol SymbolProvider: AnyObject {
    var id: String { get }
    func symbols(text: String, uri: URL) async -> [DocumentSymbol]
}

protocol DefinitionProvider: AnyObject {
    var id: String { get }
    func definition(_ ctx: DocumentContext) async -> [Location]
}

/// AI ghost-text ("tab autocomplete"). The editor asks after the user pauses typing.
protocol InlineCompletionProvider: AnyObject {
    var isEnabled: Bool { get }
    func inlineCompletion(prefix: String, suffix: String, uri: URL) async -> String?
}

/// Formats a whole document (e.g. `vanta fmt`). Return nil to leave it unchanged.
protocol FormattingProvider: AnyObject {
    var id: String { get }
    func format(text: String, uri: URL) async -> String?
}

/// Holds the active providers. Completion/hover/definition providers are
/// *combined* (all are asked); the symbol and formatting providers are single
/// slots — registering replaces the previous one.
final class LanguageRegistry {
    static let shared = LanguageRegistry()

    private(set) var completionProviders: [CompletionProvider] = []
    private(set) var hoverProviders: [HoverProvider] = []
    private(set) var definitionProviders: [DefinitionProvider] = []
    var symbolProvider: SymbolProvider?
    var formattingProvider: FormattingProvider?
    var inlineCompletionProvider: InlineCompletionProvider?

    func register(completion p: CompletionProvider) {
        completionProviders.removeAll { $0.id == p.id }; completionProviders.append(p)
    }
    func register(hover p: HoverProvider) {
        hoverProviders.removeAll { $0.id == p.id }; hoverProviders.append(p)
    }
    func register(definition p: DefinitionProvider) {
        definitionProviders.removeAll { $0.id == p.id }; definitionProviders.append(p)
    }
    func removeCompletionProvider(id: String) { completionProviders.removeAll { $0.id == id } }
    func removeHoverProvider(id: String) { hoverProviders.removeAll { $0.id == id } }
    func removeDefinitionProvider(id: String) { definitionProviders.removeAll { $0.id == id } }

    var allTriggerCharacters: Set<Character> {
        completionProviders.reduce(into: Set<Character>()) { $0.formUnion($1.triggerCharacters) }
    }
}
