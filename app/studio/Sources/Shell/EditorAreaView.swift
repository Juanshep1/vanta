import SwiftUI
import UniformTypeIdentifiers

struct EditorAreaView: View {
    @ObservedObject var editors = Services.shared.editors
    @ObservedObject var panels = PanelRegistry.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(editors.groups.enumerated()), id: \.element.id) { i, g in
                if i > 0 { Hairline(vertical: true) }
                EditorGroupView(group: g, isActive: g.id == editors.activeGroup.id, showsWelcome: editors.groups.count == 1)
            }
        }
        .background(Theme.editorBg)
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                ForEach(panels.overlays) { $0.makeView() }
            }
        }
    }
}

struct EditorGroupView: View {
    @ObservedObject var group: EditorGroup
    let isActive: Bool
    let showsWelcome: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !group.tabs.isEmpty {
                TabBar(group: group, isActive: isActive)
                if let doc = group.activeDocument {
                    DocumentChrome(document: doc)
                    EditorHost(pane: group.pane(for: doc))
                        .id(doc.id)
                }
            } else if showsWelcome {
                WelcomeView()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Breadcrumb + external-change banner above the text.
struct DocumentChrome: View {
    @ObservedObject var document: Document
    @ObservedObject var workspace = Services.shared.workspace

    var body: some View {
        VStack(spacing: 0) {
            if document.hasExternalChange {
                ConflictBanner(onReload: { document.reloadFromDisk() }, onKeep: { document.hasExternalChange = false })
            }
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(Theme.muted.opacity(0.6)) }
                    Text(c).font(.system(size: 11.5)).foregroundColor(i == crumbs.count - 1 ? Theme.ink.opacity(0.85) : Theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 22)
            .background(Theme.editorBg)
        }
    }

    var crumbs: [String] {
        guard let u = document.url else { return [document.name] }
        let rel = workspace.relativePath(u)
        let parts = rel.split(separator: "/").map(String.init)
        return parts.count > 4 ? ["…"] + parts.suffix(4) : parts
    }
}

/// Hosts a long-lived EditorPane (NSView) inside SwiftUI. Panes are cached per
/// group+document, so switching tabs keeps scroll, selection, folds and undo.
struct EditorHost: NSViewRepresentable {
    let pane: EditorPane
    func makeNSView(context: Context) -> HostContainer {
        let v = HostContainer()
        v.show(pane)
        return v
    }
    func updateNSView(_ v: HostContainer, context: Context) { v.show(pane) }

    final class HostContainer: NSView {
        override var isFlipped: Bool { true }
        func show(_ p: NSView) {
            guard subviews.first !== p else { return }
            subviews.forEach { $0.removeFromSuperview() }
            p.removeFromSuperview()
            p.frame = bounds
            p.autoresizingMask = [.width, .height]
            addSubview(p)
        }
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds
        }
    }
}

// MARK: - Tabs

struct TabBar: View {
    @ObservedObject var group: EditorGroup
    let isActive: Bool
    @State private var dragging: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(group.tabs) { tab in
                        TabItemView(tab: tab, group: group, active: tab.id == group.activeTab?.id, groupActive: isActive)
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab.id, group: group, dragging: $dragging))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                IconButton(icon: "square.split.2x1", help: "Split Editor (⌘\\)") { Services.shared.editors.split() }
            }.padding(.horizontal, 6)
        }
        .frame(height: 35)
        .background(Theme.bg)
        .overlay(Hairline(), alignment: .bottom)
    }
}

struct TabDropDelegate: DropDelegate {
    let target: UUID
    let group: EditorGroup
    @Binding var dragging: UUID?
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) { Services.shared.editors.moveTab(d, before: target, in: group) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct TabItemView: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject var document: Document
    @ObservedObject var group: EditorGroup
    let active: Bool
    let groupActive: Bool
    @State private var hover = false

    init(tab: EditorTab, group: EditorGroup, active: Bool, groupActive: Bool) {
        self.tab = tab; self.document = tab.document; self.group = group
        self.active = active; self.groupActive = groupActive
    }

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: document.name, isDirectory: false)
            Text(document.name)
                .font(.system(size: 12.5))
                .italic(tab.isPreview)
                .foregroundColor(active ? Theme.ink : Theme.muted)
                .lineLimit(1)
            ZStack {
                if document.isDirty && !hover {
                    Circle().fill(Theme.ink.opacity(0.8)).frame(width: 7, height: 7)
                } else {
                    Button { Services.shared.editors.close(tab: tab, in: group) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.panel2 : .clear))
                    }
                    .buttonStyle(.plain).foregroundColor(Theme.muted)
                    .opacity(hover || active ? 1 : 0)
                }
            }.frame(width: 16, height: 16)
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 35)
        .background(active ? Theme.editorBg : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(active && groupActive ? Theme.accent : .clear).frame(height: 1.5)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line.opacity(0.6)).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { tab.isPreview = false }
        .simultaneousGesture(TapGesture().onEnded { Services.shared.editors.activate(group: group, tab: tab) })
        .contextMenu {
            Button("Close") { Services.shared.editors.close(tab: tab, in: group) }
            Button("Close Others") { Services.shared.editors.closeOthers(tab, in: group) }
            Divider()
            if let u = document.url {
                Button("Reveal in Explorer") { Services.shared.workspace.reveal(u); Services.shared.layout.showSidebar(PanelID.explorer) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string)
                }
            }
            Button("Split Right") { Services.shared.editors.activate(group: group, tab: tab); Services.shared.editors.split() }
        }
        .help(document.url?.path ?? document.name)
    }
}

/// Small coloured glyph per file type.
struct FileIcon: View {
    let name: String
    let isDirectory: Bool
    var expanded = false
    var body: some View {
        let ext = (name as NSString).pathExtension.lowercased()
        Group {
            if isDirectory {
                Image(systemName: expanded ? "folder.fill" : "folder").foregroundColor(Theme.accent.opacity(0.85))
            } else if ext == "va" || ext == "vanta" {
                Text("V").font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 13, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accentDim))
            } else {
                Image(systemName: symbol(ext)).foregroundColor(color(ext))
            }
        }
        .font(.system(size: 11))
        .frame(width: 15)
    }
    func symbol(_ e: String) -> String {
        switch e {
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
    func color(_ e: String) -> Color {
        switch e {
        case "md", "markdown": return Theme.blue
        case "json", "yml", "yaml", "toml": return Theme.amber
        case "py": return Theme.green
        default: return Theme.muted
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var workspace = Services.shared.workspace
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Text("Vanta").font(.system(size: 30, weight: .semibold))
                        Text(" Studio").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.accent)
                    }
                    Text("The native IDE for the Vanta language.").font(.system(size: 14)).foregroundColor(Theme.muted)
                }
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 9) {
                        section("Start")
                        link("doc.badge.plus", "New File", "⌘N") { CommandRegistry.shared.run("file.new") }
                        link("folder", "Open…", "⌘O") { CommandRegistry.shared.run("file.open") }
                        link("command", "Command Palette", "⌘⇧P") { CommandRegistry.shared.run("view.commandPalette") }
                        link("book", "The Vanta Book", "") { Services.shared.layout.showSidebar(PanelID.book) }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        section("Recent")
                        if workspace.recent.isEmpty {
                            Text("No recent folders").font(.system(size: 12.5)).foregroundColor(Theme.muted)
                        }
                        ForEach(workspace.recent.prefix(6), id: \.self) { u in
                            Button { AppActions.openWorkspace(u) } label: {
                                HStack(spacing: 6) {
                                    Text(u.lastPathComponent).foregroundColor(Theme.accent)
                                    Text(u.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .foregroundColor(Theme.muted).lineLimit(1)
                                }.font(.system(size: 12.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    section("Shortcuts")
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        row("Quick Open", "⌘P"); row("Run Program", "⌘R")
                        row("Find in Files", "⌘⇧F"); row("Inline AI edit", "⌘K")
                        row("Toggle AI panel", "⌘L"); row("Split editor", "⌘\\")
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.editorBg)
    }

    func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundColor(Theme.muted)
    }
    func link(_ icon: String, _ title: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                if !key.isEmpty { Text(key).foregroundColor(Theme.muted).font(.system(size: 11.5)) }
            }.font(.system(size: 13)).foregroundColor(Theme.accent)
        }.buttonStyle(.plain)
    }
    func row(_ a: String, _ k: String) -> some View {
        GridRow {
            Text(a).font(.system(size: 12.5)).foregroundColor(Theme.ink.opacity(0.85))
            Text(k).font(.system(size: 12, design: .rounded)).foregroundColor(Theme.muted)
        }
    }
}
