import SwiftUI
import Combine

/// The service container: one place to reach the workspace, documents, the
/// focused editor, settings and every registry. Modules get it in their
/// `register(_ services:)` call and may keep a reference.
///
///     let s = Services.shared
///     s.editor?.insertAtCursor("say \"hi\"")
///     s.commands.register(...)                // menus, shortcuts, palette
///     s.panels.register(...)                  // sidebar / bottom / right views
///     s.statusBar.register(...)               // status bar items
///     s.language.register(completion: ...)    // language features
///     s.diagnostics.publish(...)              // problems / squiggles
final class Services: ObservableObject {
    static let shared = Services()

    let commands = CommandRegistry.shared
    let panels = PanelRegistry.shared
    let statusBar = StatusBarRegistry.shared
    let language = LanguageRegistry.shared
    let diagnostics = DiagnosticsStore.shared
    let breakpoints = BreakpointStore.shared
    let settings = StudioSettings.shared

    let workspace = Workspace()
    let documents = DocumentStore()
    let layout = LayoutState()
    let editors = EditorGroups()

    /// True while rendering `--snapshot` (nothing is persisted, no prompts).
    var isSnapshot = false

    /// The focused editor (nil when nothing is open).
    var editor: EditorController? { editors.activePane }
    /// Fires whenever the focused editor (or its document) changes.
    let activeEditorChanged = PassthroughSubject<EditorController?, Never>()

    /// Module-owned singletons, looked up by type (e.g. `s.resolve(RunController.self)`).
    private var objects: [ObjectIdentifier: AnyObject] = [:]
    func register<T: AnyObject>(_ object: T) { objects[ObjectIdentifier(T.self)] = object }
    func resolve<T: AnyObject>(_ type: T.Type) -> T? { objects[ObjectIdentifier(type)] as? T }

    /// Show a short message in the status bar for a few seconds.
    @Published var flashMessage: String?
    private var flashWork: DispatchWorkItem?
    func flash(_ message: String) {
        flashMessage = message
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flashMessage = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private init() {}
}
