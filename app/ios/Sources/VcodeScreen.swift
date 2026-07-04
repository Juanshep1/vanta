import SwiftUI

// vcode — the Vanta coding agent, living in your pocket. Ask for a program;
// it writes it, saves it into your files, runs it, and fixes its own errors.
struct VcodeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
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
                        Button("Clear") { model.chat = [] }
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("VANTA")
                .font(.system(size: 34, weight: .black, design: .monospaced))
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accentDim, Theme.accent, Theme.gold],
                                   startPoint: .leading, endPoint: .trailing))
            Text("vcode writes Vanta programs for you,\nsaves them to your files, runs them,\nand fixes its own mistakes.")
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
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
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
            .onChange(of: model.chat) {
                withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
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
                model.sendToVcode(prompt)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.vcodeBusy ? Theme.muted : Theme.accent)
            }
            .disabled(model.vcodeBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
                    case .code(let code):
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(code)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(Theme.ink)
                                    .padding(12)
                            }
                            HStack {
                                Image(systemName: "curlybraces").font(.caption2)
                                Text("saved to vcode.va").font(.caption2)
                                Spacer()
                                Button("Open in editor") {
                                    model.createFile("vcode.va", contents: code)
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
        case code(String)
    }

    // Split the reply into prose and ```va code blocks.
    private var segments: [Segment] {
        var out: [Segment] = []
        var rest = message.text[...]
        while let open = rest.range(of: "```") {
            let before = rest[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { out.append(.prose(before)) }
            var body = rest[open.upperBound...]
            if let newline = body.firstIndex(of: "\n"),
               body[..<newline].trimmingCharacters(in: .whitespaces).count <= 10 {
                body = body[body.index(after: newline)...]
            }
            if let close = body.range(of: "```") {
                let code = body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty { out.append(.code(code)) }
                rest = body[close.upperBound...]
            } else {
                let code = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty { out.append(.code(code)) }
                rest = rest[rest.endIndex...]
            }
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(.prose(tail)) }
        return out
    }
}
