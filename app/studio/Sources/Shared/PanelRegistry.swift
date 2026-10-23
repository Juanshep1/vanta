import SwiftUI

/// Where a contributed view appears.
enum PanelLocation: String { case sidebar, bottom, auxiliary }

/// A view contributed to the shell: an activity-bar sidebar view, a bottom panel
/// tab, or the right-hand auxiliary panel (the AI panel).
struct PanelDescriptor: Identifiable {
    let id: String
    var title: String
    /// SF Symbol name for the activity bar / panel tab.
    var icon: String
    var location: PanelLocation
    /// Sort order in the activity bar / panel tab strip (lower first).
    var order: Int
    /// Optional small badge ("3") — evaluated whenever the shell redraws.
    var badge: () -> String? = { nil }
    /// Builds the view. Called each time the panel is shown; keep state in your
    /// own ObservableObject, not in the view.
    var makeView: () -> AnyView

    init(id: String, title: String, icon: String, location: PanelLocation, order: Int,
         badge: @escaping () -> String? = { nil }, makeView: @escaping () -> AnyView) {
        self.id = id; self.title = title; self.icon = icon; self.location = location
        self.order = order; self.badge = badge; self.makeView = makeView
    }
}

/// A floating view drawn over the editor area (e.g. the ⌘K prompt).
struct EditorOverlay: Identifiable {
    let id: String
    var makeView: () -> AnyView
}

/// A tab in the Settings window.
struct SettingsSection: Identifiable {
    let id: String
    var title: String
    var icon: String
    var order: Int
    var makeView: () -> AnyView
}

/// Registry of every contributed view. Registering an existing id replaces it,
/// so Phase-2 modules swap the placeholders by registering the same id
/// (ids: see `PanelID`).
final class PanelRegistry: ObservableObject {
    static let shared = PanelRegistry()

    @Published private(set) var panels: [PanelDescriptor] = []
    @Published private(set) var overlays: [EditorOverlay] = []
    @Published private(set) var settingsSections: [SettingsSection] = []
    @Published private(set) var toolbarItems: [EditorOverlay] = []

    /// A control in the title row, left side after the app name (e.g. Run / Stop).
    /// Ids starting with "console." are shown in the Console panel header instead.
    func registerToolbarItem<V: View>(id: String, @ViewBuilder view: @escaping () -> V) {
        let o = EditorOverlay(id: id, makeView: { AnyView(view()) })
        if let i = toolbarItems.firstIndex(where: { $0.id == id }) { toolbarItems[i] = o } else { toolbarItems.append(o) }
    }

    func register(_ p: PanelDescriptor) {
        if let i = panels.firstIndex(where: { $0.id == p.id }) { panels[i] = p } else { panels.append(p) }
    }

    func register<V: View>(id: String, title: String, icon: String, location: PanelLocation, order: Int,
                           badge: @escaping () -> String? = { nil }, @ViewBuilder view: @escaping () -> V) {
        register(PanelDescriptor(id: id, title: title, icon: icon, location: location, order: order,
                                 badge: badge, makeView: { AnyView(view()) }))
    }

    func registerOverlay<V: View>(id: String, @ViewBuilder view: @escaping () -> V) {
        let o = EditorOverlay(id: id, makeView: { AnyView(view()) })
        if let i = overlays.firstIndex(where: { $0.id == id }) { overlays[i] = o } else { overlays.append(o) }
    }

    func registerSettingsSection<V: View>(id: String, title: String, icon: String, order: Int,
                                          @ViewBuilder view: @escaping () -> V) {
        let s = SettingsSection(id: id, title: title, icon: icon, order: order, makeView: { AnyView(view()) })
        if let i = settingsSections.firstIndex(where: { $0.id == id }) { settingsSections[i] = s }
        else { settingsSections.append(s) }
    }

    func panels(at loc: PanelLocation) -> [PanelDescriptor] {
        panels.filter { $0.location == loc }.sorted { $0.order < $1.order }
    }

    func panel(_ id: String) -> PanelDescriptor? { panels.first { $0.id == id } }
}

/// Well-known panel ids. Phase-2 modules register these ids to replace the
/// Phase-1 placeholders.
enum PanelID {
    // sidebar (activity bar)
    static let explorer = "sidebar.explorer"
    static let search = "sidebar.search"
    static let sourceControl = "sidebar.scm"          // Run/ (git)
    static let runDebug = "sidebar.run"               // Run/ (debugger)
    static let tests = "sidebar.tests"                // Language/ (vanta test)
    static let outline = "sidebar.outline"
    static let book = "sidebar.book"
    // bottom panel
    static let console = "panel.console"              // Run/
    static let terminal = "panel.terminal"            // Run/
    static let problems = "panel.problems"            // Language/ may replace
    static let testResults = "panel.tests"            // Language/
    static let debugConsole = "panel.debug"           // Run/
    // right side
    static let ai = "aux.ai"                          // AI/
}

// MARK: - Status bar

enum StatusAlignment { case left, right }

struct StatusItem: Identifiable {
    let id: String
    var alignment: StatusAlignment
    /// Higher priority sits closer to the outer edge.
    var priority: Int
    var makeView: () -> AnyView
}

/// Items in the bottom status bar. Ids used by Phase 1:
/// `status.run` (left), `status.problems` (left), `status.git` (left),
/// `status.cursor`, `status.language`, `status.ai` (right).
final class StatusBarRegistry: ObservableObject {
    static let shared = StatusBarRegistry()
    @Published private(set) var items: [StatusItem] = []

    func register<V: View>(id: String, alignment: StatusAlignment, priority: Int,
                           @ViewBuilder view: @escaping () -> V) {
        let item = StatusItem(id: id, alignment: alignment, priority: priority, makeView: { AnyView(view()) })
        if let i = items.firstIndex(where: { $0.id == id }) { items[i] = item } else { items.append(item) }
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }

    func items(_ a: StatusAlignment) -> [StatusItem] {
        items.filter { $0.alignment == a }.sorted { $0.priority > $1.priority }
    }
}
