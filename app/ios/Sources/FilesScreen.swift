import SwiftUI

// The Code tab: your project's files. Tap to edit, swipe to delete,
// long-press for rename/duplicate.
struct FilesScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var newFileName = ""
    @State private var showNewFile = false
    @State private var renameTarget: String?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if model.files.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .navigationTitle("Vanta Pocket")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewFile = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    EngineBadge()
                }
            }
            .alert("New file", isPresented: $showNewFile) {
                TextField("name.va", text: $newFileName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Create") {
                    model.createFile(newFileName)
                    newFileName = ""
                }
                Button("Cancel", role: .cancel) { newFileName = "" }
            }
            .alert("Rename file", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })) {
                TextField("new name", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Rename") {
                    if let target = renameTarget { model.renameFile(target, to: renameText) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("No files yet").font(.title3.bold()).foregroundStyle(Theme.ink)
            Text("Make a file, or grab one from Learn.")
                .foregroundStyle(Theme.muted)
            Button("New file") { showNewFile = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var fileList: some View {
        List {
            ForEach(model.files) { file in
                NavigationLink {
                    EditorScreen(fileName: file.name)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: file.name.hasSuffix(".va") ? "curlybraces" : "doc.text")
                            .foregroundStyle(file.name.hasSuffix(".va") ? Theme.accent : Theme.muted)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).foregroundStyle(Theme.ink)
                                .font(.system(.body, design: .monospaced))
                            Text(firstLine(of: file.name))
                                .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Theme.panel)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { model.deleteFile(file.name) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { renameTarget = file.name; renameText = file.name } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        let copy = file.name.replacingOccurrences(of: ".va", with: " copy.va")
                        model.createFile(copy, contents: model.contents(of: file.name))
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) { model.deleteFile(file.name) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { model.refreshFiles() }
    }

    private func firstLine(of name: String) -> String {
        let line = model.contents(of: name)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return line.isEmpty ? "empty" : line
    }
}

// A small live indicator of the engine's state, shown in the toolbar.
struct EngineBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let (label, color): (String, Color) = {
            switch model.engine.state {
            case .booting: return ("warming up", Theme.gold)
            case .ready: return ("ready", Theme.green)
            case .running: return ("running", Theme.accent)
            case .failed: return ("engine failed", Theme.red)
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
    }
}
