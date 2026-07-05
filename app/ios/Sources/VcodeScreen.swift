import SwiftUI

// vcode — the Vanta coding agent, living in your pocket. Ask for a program;
// it writes it, saves it into your files, runs it, and fixes its own errors.
// Attach project files (📎) and it can fix or extend what you already have.
struct VcodeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var attached: [String] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if model.chat.isEmpty {
                        welcome
                    } else {
                        chatLog
                    }
                    inputBar
                }
            }
            .navigationTitle("vcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !model.chat.isEmpty {
                        Button {
                            model.chat = []
                            model.vcodeProjectFile = nil
                        } label: {
                            Label("New", systemImage: "square.and.pencil")
                                .font(.caption)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 60)
                Text("VANTA")
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accentDim, Theme.accent, Theme.gold],
                                       startPoint: .leading, endPoint: .trailing))
                Text("vcode writes Vanta programs for you,\nsaves them to your files, runs them,\nand fixes its own mistakes.\n\nTap 📎 to hand it one of your files\nto fix or build on.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                if model.ai.apiKey.isEmpty {
                    Label("Add your API key in Settings to start", systemImage: "key.fill")
                        .font(.caption).foregroundStyle(Theme.gold)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["a quiz about space with a score",
                             "a text adventure in a haunted castle",
                             "a times-table trainer that gets harder"], id: \.self) { idea in
                        Button {
                            input = idea
                            inputFocused = true
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb").font(.caption)
                                Text(idea).font(.callout)
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.panel2, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var chatLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.chat) { message in
                        ChatBubble(message: message)
                    }
                    if model.vcodeBusy {
                        HStack(spacing: 8) {
                            ProgressView().tint(Theme.accent)
                            Text("vcode is thinking…").font(.caption).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.chat) {
                withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            // Shows which project follow-up edits will land in, so it's clear
            // vcode is editing — not spawning — a file.
            if attached.isEmpty, let active = model.activeProjectFile {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.outline").font(.caption2)
                    Text("editing \(active)").font(.caption)
                    Spacer()
                    Button("new project") {
                        model.vcodeProjectFile = nil
                        model.currentFile = nil
                    }
                    .font(.caption2.bold())
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
            }
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attached, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip").font(.caption2)
                                Text(name).font(.caption)
                                Button {
                                    attached.removeAll { $0 == name }
                                } label: {
                                    Image(systemName: "xmark").font(.caption2.bold())
                                }
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.accentDim.opacity(0.35), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 10) {
                Menu {
                    if model.files.isEmpty {
                        Text("No files yet")
                    }
                    ForEach(model.files) { file in
                        Button {
                            if !attached.contains(file.name) { attached.append(file.name) }
                        } label: {
                            Label(file.name,
                                  systemImage: attached.contains(file.name) ? "checkmark" : "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(attached.isEmpty ? Theme.muted : Theme.accent)
                }
                TextField("Ask for a program…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(Theme.ink)
                Button {
                    let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    input = ""
                    let files = attached
                    attached = []
                    model.sendToVcode(prompt, attachments: files)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.vcodeBusy ? Theme.muted : Theme.accent)
                }
                .disabled(model.vcodeBusy)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Theme.panel)
    }
}

struct ChatBubble: View {
    @EnvironmentObject var model: AppModel
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accentDim.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Theme.ink)
            }
        case .status:
            Text(message.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .prose(let text):
                        Text(text).foregroundStyle(Theme.ink)
                    case .code(let block):
                        let fileName = block.name ?? "vcode.va"
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(block.code)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(Theme.ink)
                                    .padding(12)
                            }
                            HStack {
                                Image(systemName: "curlybraces").font(.caption2)
                                Text("saved to \(fileName)").font(.caption2)
                                Spacer()
                                Button("Open in editor") {
                                    model.createFile(fileName, contents: block.code)
                                }
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                            }
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.panel2)
                        }
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum Segment {
        case prose(String)
        case code(AppModel.CodeBlock)
    }

    // Split the reply into prose and code blocks (reusing the same parser
    // that decides which files get saved).
    private var segments: [Segment] {
        var out: [Segment] = []
        let blocks = AppModel.extractFiles(message.text)
        var rest = message.text[...]
        var blockIndex = 0
        while let open = rest.range(of: "```") {
            let before = rest[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { out.append(.prose(before)) }
            let body = rest[open.upperBound...]
            if let close = body.range(of: "```") {
                if blockIndex < blocks.count {
                    out.append(.code(blocks[blockIndex]))
                    blockIndex += 1
                }
                rest = body[close.upperBound...]
            } else {
                if blockIndex < blocks.count { out.append(.code(blocks[blockIndex])) }
                rest = rest[rest.endIndex...]
            }
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(.prose(tail)) }
        return out
    }
}
