import SwiftUI

/// The whole IDE window: title row · activity bar · sidebar · editor area ·
/// bottom panel · AI panel · status bar, plus the quick-pick overlay.
struct MainWindowView: View {
    @ObservedObject var layout = Services.shared.layout
    @ObservedObject var panels = PanelRegistry.shared
    @ObservedObject var settings = StudioSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TitleRow()
            Hairline()
            HStack(spacing: 0) {
                ActivityBar()
                Hairline(vertical: true)
                if layout.sidebarVisible {
                    SidebarHost()
                        .frame(width: layout.sidebarWidth)
                    ResizeHandle(axis: .horizontal, value: $layout.sidebarWidth, range: 170...560)
                }
                VStack(spacing: 0) {
                    EditorAreaView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if layout.bottomVisible {
                        ResizeHandle(axis: .vertical, value: $layout.bottomHeight, range: 100...700, inverted: true)
                        BottomPanelView()
                            .frame(height: layout.bottomHeight)
                    }
                }
                .frame(minWidth: 360)
                if layout.auxVisible, let ai = panels.panels(at: .auxiliary).first {
                    ResizeHandle(axis: .horizontal, value: $layout.auxWidth, range: 260...720, inverted: true)
                    ai.makeView()
                        .frame(width: layout.auxWidth)
                }
            }
            StatusBarView()
        }
        .background(Theme.bg)
        .foregroundColor(Theme.ink)
        .overlay(alignment: .top) {
            if layout.quickPickVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { layout.quickPickVisible = false }
                    QuickPickView()
                        .padding(.top, 44)
                }
            }
        }
        .preferredColorScheme(settings.colorScheme)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Drag handle between panels. `inverted` for panels anchored to the right/bottom.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var inverted = false
    @State private var start: CGFloat?
    @State private var hover = false

    var body: some View {
        ZStack {
            Rectangle().fill(hover || start != nil ? Theme.accent.opacity(0.6) : Theme.line)
                .frame(width: axis == .horizontal ? (hover || start != nil ? 2 : 1) : nil,
                       height: axis == .vertical ? (hover || start != nil ? 2 : 1) : nil)
        }
        .frame(width: axis == .horizontal ? 5 : nil, height: axis == .vertical ? 5 : nil)
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if start == nil { start = value }
                let d = axis == .horizontal ? g.translation.width : g.translation.height
                value = min(range.upperBound, max(range.lowerBound, (start ?? value) + (inverted ? -d : d)))
            }
            .onEnded { _ in start = nil })
    }
}

// MARK: - Title row

struct TitleRow: View {
    @ObservedObject var workspace = Services.shared.workspace
    @ObservedObject var layout = Services.shared.layout
    @ObservedObject var editors = Services.shared.editors

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("Vanta").font(.system(size: 13, weight: .semibold))
                Text(" Studio").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.accent)
            }
            ToolbarItems()
            Spacer(minLength: 12)
            Button { layout.openQuickPick("") } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text(workspace.root == nil ? "Search files, commands…" : workspace.name)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘P").font(.system(size: 10.5, design: .rounded)).foregroundColor(Theme.muted)
                }
                .padding(.horizontal, 10).frame(width: 380, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                .foregroundColor(Theme.muted)
            }.buttonStyle(.plain).help("Quick Open (⌘P) · Command Palette (⌘⇧P)")
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                toggle("sidebar.left", on: layout.sidebarVisible, help: "Toggle Sidebar (⌘B)") { layout.sidebarVisible.toggle() }
                toggle("rectangle.bottomthird.inset.filled", on: layout.bottomVisible, help: "Toggle Panel (⌘J)") { layout.bottomVisible.toggle() }
                toggle("sidebar.right", on: layout.auxVisible, help: "Toggle AI Panel (⌘L)") { layout.auxVisible.toggle() }
            }
        }
        .padding(.leading, 80)          // room for the traffic lights (hidden title bar)
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Theme.chrome)
    }

    func toggle(_ icon: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12.5))
                .frame(width: 26, height: 22)
                .foregroundColor(on ? Theme.ink : Theme.muted)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.panel2 : .clear))
        }.buttonStyle(.plain).help(help)
    }
}

/// Items contributed to the title row (the Run module adds Run/Stop here).
struct ToolbarItems: View {
    @ObservedObject var panels = PanelRegistry.shared
    var body: some View {
        HStack(spacing: 6) {
            ForEach(panels.toolbarItems.filter { !$0.id.hasPrefix("console.") }) { $0.makeView() }
        }
    }
}

/// A pill-shaped title-row button.
struct ToolbarPill: View {
    let title: String
    let icon: String
    var tint: Color = Theme.ink
    var filled = false
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 22)
            .foregroundColor(filled ? .white : tint)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Theme.accentDim : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(filled ? Color.clear : Theme.line))
        }.buttonStyle(.plain).help(help)
    }
}

// MARK: - Activity bar

struct ActivityBar: View {
    @ObservedObject var layout = Services.shared.layout
    @ObservedObject var panels = PanelRegistry.shared
    @ObservedObject var diagnostics = DiagnosticsStore.shared

    var body: some View {
        VStack(spacing: 4) {
            ForEach(panels.panels(at: .sidebar)) { p in
                let active = layout.sidebarVisible && layout.activeSidebar == p.id
                Button { layout.showSidebar(p.id, toggle: true) } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: p.icon)
                            .font(.system(size: 17, weight: .regular))
                            .frame(width: 44, height: 40)
                            .foregroundColor(active ? Theme.ink : Theme.muted)
                        if let b = p.badge(), !b.isEmpty {
                            Text(b).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                .background(Capsule().fill(Theme.accentDim))
                                .offset(x: -5, y: 5)
                        }
                    }
                    .overlay(alignment: .leading) {
                        Rectangle().fill(active ? Theme.accent : .clear).frame(width: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.title)
            }
            Spacer()
            SettingsButton()
                .padding(.bottom, 8)
        }
        .padding(.top, 6)
        .frame(width: 46)
        .background(Theme.chrome)
    }
}

struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape").font(.system(size: 16)).foregroundColor(Theme.muted)
                .frame(width: 44, height: 36)
        }.buttonStyle(.plain).help("Settings (⌘,)")
    }
}

// MARK: - Sidebar host

struct SidebarHost: View {
    @ObservedObject var layout = Services.shared.layout
    @ObservedObject var panels = PanelRegistry.shared

    var body: some View {
        let p = panels.panel(layout.activeSidebar) ?? panels.panels(at: .sidebar).first
        VStack(spacing: 0) {
            if let p { p.makeView() } else { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }
}

/// Standard sidebar header: "EXPLORER" + action buttons.
struct SidebarHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    init(_ title: String, @ViewBuilder actions: @escaping () -> Actions) { self.title = title; self.actions = actions }
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundColor(Theme.muted)
            Spacer()
            actions()
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 34)
    }
}

extension SidebarHeader where Actions == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

struct IconButton: View {
    let icon: String
    var help: String = ""
    var size: CGFloat = 12
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(Theme.muted).help(help)
    }
}

/// Empty-state view used for Phase-2 placeholder panels.
struct PlaceholderPanel: View {
    let title: String
    let icon: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundColor(Theme.muted.opacity(0.7))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bottom panel

struct BottomPanelView: View {
    @ObservedObject var layout = Services.shared.layout
    @ObservedObject var panels = PanelRegistry.shared
    @ObservedObject var diagnostics = DiagnosticsStore.shared

    var body: some View {
        let list = panels.panels(at: .bottom)
        let active = list.first { $0.id == layout.activeBottom } ?? list.first
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(list) { p in
                    let on = p.id == active?.id
                    Button { layout.activeBottom = p.id } label: {
                        HStack(spacing: 5) {
                            Text(p.title.uppercased()).font(.system(size: 11, weight: on ? .semibold : .regular)).tracking(0.5)
                            if let b = p.badge(), !b.isEmpty {
                                Text(b).font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.panel2))
                            }
                        }
                        .foregroundColor(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 9).frame(height: 32)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? Theme.accent : .clear).frame(height: 1.5) }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                IconButton(icon: "chevron.down", help: "Hide Panel (⌘J)") { layout.bottomVisible = false }
                    .padding(.trailing, 8)
            }
            .padding(.leading, 8)
            Hairline().opacity(0.6)
            if let active { active.makeView() } else { Spacer() }
        }
        .background(Theme.bg)
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @ObservedObject var registry = StatusBarRegistry.shared
    @ObservedObject var services = Services.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(registry.items(.left)) { item in item.makeView().padding(.horizontal, 7) }
            if let m = services.flashMessage {
                Text(m).font(.system(size: 11)).foregroundColor(Theme.ink).lineLimit(1).padding(.horizontal, 7)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            ForEach(registry.items(.right).reversed()) { item in item.makeView().padding(.horizontal, 7) }
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.muted)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Theme.chrome)
        .overlay(Hairline(), alignment: .top)
    }
}

/// Small clickable status-bar label.
struct StatusLabel: View {
    var icon: String?
    let text: String
    var color: Color = Theme.muted
    var help: String = ""
    var action: (() -> Void)?
    var body: some View {
        let content = HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10.5)) }
            Text(text).lineLimit(1)
        }.foregroundColor(color)
        if let action {
            Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain).help(help)
        } else {
            content.help(help)
        }
    }
}
