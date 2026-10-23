import AppKit
import Combine

/// One edit to a document's text, published after it happens.
struct TextChange {
    let uri: URL
    /// Range in the *new* text that was replaced/inserted.
    let range: NSRange
    /// newLength - oldLength
    let delta: Int
    /// Monotonic document version (bumps on every edit).
    let version: Int
}

/// The API every module uses to talk to an editor. `Services.shared.editor` is
/// the focused one (nil when no file is open). Implemented by `EditorPane`.
///
/// Conventions: offsets are UTF-16 indices into `text`; lines/columns are
/// 0-based (`TextPosition`). All calls must be made on the main thread.
protocol EditorController: AnyObject {
    // MARK: document
    var document: Document { get }
    /// File URL (nil for an untitled buffer). `document.uri` is always non-nil.
    var url: URL? { get }
    /// The full current text.
    var text: String { get }

    // MARK: selection & cursor
    /// All selections/cursors (zero-length = caret). The first is the primary.
    var selections: [NSRange] { get set }
    var selectedText: String { get }
    var cursorPosition: TextPosition { get }
    func offset(of position: TextPosition) -> Int
    func position(of offset: Int) -> TextPosition

    // MARK: editing (each call is one undo step)
    func replace(_ range: NSRange, with text: String)
    /// Several replacements applied atomically as ONE undo step. Ranges refer to
    /// the text *before* any of them are applied and must not overlap.
    func replace(edits: [(range: NSRange, text: String)])
    func insertAtCursor(_ text: String)
    /// Replace the whole document (one undo step, keeps unchanged lines in place).
    func setText(_ text: String)

    // MARK: viewport
    /// Scroll so `line` is visible (centred) and optionally put the caret on it.
    func scrollToLine(_ line: Int, select: Bool)
    func reveal(_ range: NSRange)
    /// 0-based lines currently on screen.
    var visibleLines: ClosedRange<Int> { get }
    func focus()

    // MARK: decorations
    /// Squiggles + gutter icons + hover text for this document (source "editor").
    /// Prefer `DiagnosticsStore.shared.publish(_:for:source:)` from language tools.
    func setDiagnostics(_ diagnostics: [Diagnostic])
    /// Gray inline suggestion drawn at `offset` (default: caret). The first line
    /// renders after the cursor, further lines below it (pushing text down).
    /// Tab accepts, Esc dismisses, moving the caret clears it. nil hides it.
    func setGhostText(_ text: String?, at offset: Int?)
    /// Red/green inline diff of `range` → `newText`, with Accept/Reject buttons.
    /// ⌘↩ accepts, Esc rejects. Accept applies `newText` as one undo step and then
    /// calls `onAccept`; reject leaves the text alone and calls `onReject`.
    func showInlineDiff(range: NSRange, newText: String, onAccept: @escaping () -> Void, onReject: @escaping () -> Void)
    func dismissInlineDiff()
    var hasInlineDiff: Bool { get }
    /// Debugger current-line highlight (amber band + gutter arrow). nil clears.
    func highlightLine(_ line: Int?)

    // MARK: breakpoints
    /// 0-based lines with breakpoints in this file (gutter click toggles). Also
    /// observable globally via `BreakpointStore.shared`.
    var breakpoints: Set<Int> { get set }

    // MARK: events
    /// Fires after every text edit in this document.
    var textChanges: AnyPublisher<TextChange, Never> { get }
    /// Fires when the selection/caret moves.
    var selectionChanges: AnyPublisher<[NSRange], Never> { get }
}
