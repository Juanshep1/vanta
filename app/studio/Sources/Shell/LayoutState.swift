import SwiftUI

/// Panel visibility + sizes, persisted across launches.
final class LayoutState: ObservableObject {
    struct Stored: Codable {
        var sidebarVisible = true
        var sidebarWidth: Double = 250
        var activeSidebar = PanelID.explorer
        var bottomVisible = true
        var bottomHeight: Double = 220
        var activeBottom = PanelID.console
        var auxVisible = true
        var auxWidth: Double = 360
    }

    @Published var sidebarVisible = true { didSet { save() } }
    @Published var sidebarWidth: CGFloat = 250 { didSet { save() } }
    @Published var activeSidebar = PanelID.explorer { didSet { save() } }
    @Published var bottomVisible = true { didSet { save() } }
    @Published var bottomHeight: CGFloat = 220 { didSet { save() } }
    @Published var activeBottom = PanelID.console { didSet { save() } }
    @Published var auxVisible = true { didSet { save() } }
    @Published var auxWidth: CGFloat = 360 { didSet { save() } }

    /// Quick pick / command palette overlay.
    @Published var quickPickVisible = false
    @Published var quickPickInitialText = ""
    @Published var quickPickToken = 0

    private let key = "vanta-studio-2-layout"
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() {
        loading = true
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            sidebarVisible = s.sidebarVisible; sidebarWidth = CGFloat(s.sidebarWidth); activeSidebar = s.activeSidebar
            bottomVisible = s.bottomVisible; bottomHeight = CGFloat(s.bottomHeight); activeBottom = s.activeBottom
            auxVisible = s.auxVisible; auxWidth = CGFloat(s.auxWidth)
        }
        loading = false
    }

    private func save() {
        guard !loading, !Services.shared.isSnapshot else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let s = Stored(sidebarVisible: self.sidebarVisible, sidebarWidth: Double(self.sidebarWidth), activeSidebar: self.activeSidebar,
                           bottomVisible: self.bottomVisible, bottomHeight: Double(self.bottomHeight), activeBottom: self.activeBottom,
                           auxVisible: self.auxVisible, auxWidth: Double(self.auxWidth))
            if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: self.key) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Show a sidebar view (or toggle the sidebar if it's already showing).
    func showSidebar(_ id: String, toggle: Bool = false) {
        if toggle && sidebarVisible && activeSidebar == id { sidebarVisible = false; return }
        activeSidebar = id
        sidebarVisible = true
    }

    func showBottom(_ id: String, toggle: Bool = false) {
        if toggle && bottomVisible && activeBottom == id { bottomVisible = false; return }
        activeBottom = id
        bottomVisible = true
    }

    func openQuickPick(_ text: String) {
        quickPickInitialText = text
        quickPickVisible = true
        quickPickToken += 1
    }

    /// Apply a snapshot-friendly default layout without persisting it.
    func applyDefaults() {
        loading = true
        sidebarVisible = true; sidebarWidth = 250; activeSidebar = PanelID.explorer
        bottomVisible = true; bottomHeight = 200; activeBottom = PanelID.console
        auxVisible = true; auxWidth = 350
        loading = false
    }
}
