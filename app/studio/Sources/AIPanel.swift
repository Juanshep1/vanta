import SwiftUI

struct AIPanel: View {
    @EnvironmentObject var model: AppModel

    private let chips: [(String, String)] = [
        ("✨ Make something", "Write me a fun little Vanta program."),
        ("🐞 Fix my error", "__FIX__"),
        ("📖 Explain", "Explain what my current file does, simply."),
        ("⚡️ Improve it", "Improve my current file — cleaner, more idiomatic Vanta. Return the full file."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.accentDim)
                    Text("V").font(.system(size: 16, weight: .heavy)).foregroundColor(.white)
                }.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vee").font(.system(size: 14, weight: .bold))
                    Text(model.agentMode ? (model.agentStatus.isEmpty ? "agent · writes, runs & fixes" : model.agentStatus)
                         : (model.settings.apiKey.isEmpty ? "add a key in ⚙ settings"
                            : "\(model.settings.provider) · writes Vanta"))
                        .font(.system(size: 11)).foregroundColor(model.agentMode ? Theme.accent : Theme.muted)
                }
                Spacer()
                Button { model.agentMode.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.agentMode ? "bolt.fill" : "bolt")
                            .font(.system(size: 10, weight: .bold))
                        Text("Agent").font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 999)
                        .fill(model.agentMode ? Theme.accentDim : Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 999).stroke(Theme.line, lineWidth: 1)))
                    .foregroundColor(model.agentMode ? .white : Theme.muted)
                }.buttonStyle(.plain)
                    .help("Agent mode: Vee writes a program, runs it, reads the output, and fixes errors on its own.")
            }
            .padding(12)
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(chips, id: \.0) { chip in
                        Button {
                            if chip.1 == "__FIX__" { model.fixWithVee() }
                            else { send(chip.1) }
                        } label: {
                            Text(chip.0).font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 999).fill(Theme.panel)
                                    .overlay(RoundedRectangle(cornerRadius: 999).stroke(Theme.line, lineWidth: 1)))
                        }.buttonStyle(.plain).foregroundColor(Theme.muted)
                    }
                }.padding(.horizontal, 11).padding(.vertical, 9)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.aiMessages.isEmpty {
                            Text("Hey! I'm Vee. Ask me to write Vanta, explain your code, or run something and tap “Fix my error”.")
                                .font(.system(size: 13)).foregroundColor(Theme.muted).padding(8)
                        }
                        ForEach(model.aiMessages) { msg in
                            MessageView(msg: msg)
                        }
                        if model.aiBusy {
                            Text("Vee is thinking…").font(.system(size: 12.5)).italic()
                                .foregroundColor(Theme.muted).padding(.leading, 4)
                        }
                        Color.clear.frame(height: 1).id("aiBottom")
                    }
                    .padding(11)
                }
                .onChange(of: model.aiMessages.count) { _, _ in
                    withAnimation { proxy.scrollTo("aiBottom", anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask Vee…", text: $model.aiInput, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .lineLimit(1...4)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1)))
                    .onSubmit { send(model.aiInput) }
                Button { send(model.aiInput) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }.buttonStyle(.plain).foregroundColor(Theme.accent)
            }
            .padding(11)
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
        }
        .background(Theme.bg)
        .foregroundColor(Theme.ink)
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if model.agentMode {
            model.aiInput = ""
            model.agentBuild(t)
        } else {
            model.askVee(t)
        }
    }

    func fixPrompt() -> String {
        let tail = String(model.console.suffix(600))
        return tail.isEmpty
            ? "Review my current file for bugs and improvements."
            : "My program produced this output/error:\n\(tail)\n\nFix the current file and return the complete corrected program."
    }
}

struct MessageView: View {
    @EnvironmentObject var model: AppModel
    let msg: AIMessage

    var body: some View {
        if msg.role == "user" {
            Text(msg.text)
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accentDim))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.isCode {
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(seg.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Theme.ink)
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.nbgColor)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1)))
                            HStack(spacing: 8) {
                                applyButton("✓ Apply") { model.applyCode(seg.text, toNewFile: false) }
                                applyButton("＋ New file") { model.applyCode(seg.text, toNewFile: true) }
                            }
                        }
                    } else {
                        Text(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 13)).foregroundColor(Theme.ink)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line.opacity(0.6), lineWidth: 1)))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func applyButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.green.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.green.opacity(0.4), lineWidth: 1)))
        }.buttonStyle(.plain).foregroundColor(Theme.green)
    }

    var segments: [(isCode: Bool, text: String)] {
        var result: [(Bool, String)] = []
        let parts = msg.text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append((false, part)) }
            } else {
                var code = part
                if let nl = code.firstIndex(of: "\n") {
                    let firstLine = code[code.startIndex..<nl].trimmingCharacters(in: .whitespaces)
                    if firstLine == "va" || firstLine == "vanta" || firstLine.isEmpty {
                        code = String(code[code.index(after: nl)...])
                    }
                }
                result.append((true, code.hasSuffix("\n") ? String(code.dropLast()) : code))
            }
        }
        return result.map { (isCode: $0.0, text: $0.1) }
    }
}
