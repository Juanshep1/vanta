import SwiftUI

/// Settings › AI: provider, Keychain-stored key, smart + fast models, base
/// URL, autocomplete, agent behaviour, knowledge, and a privacy note.
struct AISettingsView: View {
    @ObservedObject var vee = VeeAssistant.shared
    @State private var keyDraft = ""
    @State private var keyEditing = false
    @State private var customSmart = false
    @State private var customFast = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Vee — AI assistant").font(.system(size: 15, weight: .bold))
                    if vee.isMock {
                        Text("MOCK MODE").font(.system(size: 9.5, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.amber.opacity(0.25))).foregroundColor(Theme.amber)
                    }
                }

                group("Provider") {
                    Picker("", selection: Binding(get: { vee.settings.provider }, set: { vee.setProvider($0); keyDraft = ""; keyEditing = false })) {
                        ForEach(AIProvider.all, id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 280)

                    HStack(spacing: 8) {
                        if keyEditing || !vee.hasKey {
                            SecureField("Paste your \(AIProvider.name(vee.settings.provider)) API key", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
                            Image(systemName: "key.fill").foregroundColor(Theme.green)
                            Text("Key saved in your Keychain  ••••\(String(vee.apiKey.suffix(4)))").font(.system(size: 12))
                            Spacer()
                            Button("Change") { keyEditing = true; keyDraft = "" }
                            Button("Remove") { vee.setKey(""); keyEditing = false }
                        }
                    }
                    Text(AIProvider.keyHelp(vee.settings.provider)).font(.system(size: 11)).foregroundColor(Theme.muted)

                    HStack(spacing: 8) {
                        Button { testConnection() } label: {
                            if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
                        }.disabled(!vee.hasKey || testing)
                        if let r = testResult { Text(r).font(.system(size: 11)).foregroundColor(r.hasPrefix("✓") ? Theme.green : Theme.red).lineLimit(2) }
                    }

                    DisclosureGroup("Custom base URL") {
                        TextField(AIProvider.defaultBase(vee.settings.provider), text: $vee.settings.baseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Any proxy or OpenAI-compatible server (e.g. local Ollama at http://localhost:11434/v1 with the OpenRouter/Ollama format). Leave empty for the provider's default.")
                            .font(.system(size: 11)).foregroundColor(Theme.muted)
                    }.font(.system(size: 12))
                }

                group("Models") {
                    modelRow("Smart model", help: "Chat, Agent, ⌘K edits, Fix with Vee", value: $vee.settings.smartModel, custom: $customSmart)
                    modelRow("Fast model", help: "Tab autocomplete — pick something quick and cheap", value: $vee.settings.fastModel, custom: $customFast)
                    HStack(spacing: 8) {
                        Button { vee.refreshModels() } label: {
                            HStack(spacing: 4) {
                                if vee.modelsLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                                Text("Fetch the provider's model list")
                            }
                        }.disabled(vee.modelsLoading)
                        if let e = vee.modelError { Text(e).font(.system(size: 11)).foregroundColor(Theme.red).lineLimit(2) }
                        else if !vee.modelCatalog.isEmpty { Text("\(vee.modelCatalog.count) models").font(.system(size: 11)).foregroundColor(Theme.muted) }
                    }
                }

                group("Tab autocomplete") {
                    Toggle("Ghost-text suggestions as you type (Tab accepts, ⌘→ accepts a word)", isOn: $vee.settings.autocomplete)
                        .toggleStyle(.switch).tint(Theme.accent)
                    HStack {
                        Text("Delay").font(.system(size: 12))
                        Slider(value: Binding(get: { Double(vee.settings.autocompleteDelayMs) }, set: { vee.settings.autocompleteDelayMs = Int($0) }),
                               in: 100...1200, step: 50).frame(maxWidth: 220)
                        Text("\(vee.settings.autocompleteDelayMs) ms").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.muted)
                    }.disabled(!vee.settings.autocomplete)
                    Toggle("Next-edit suggestions (rename a variable → offer the other renames)", isOn: $vee.settings.nextEditPrediction)
                        .toggleStyle(.switch).tint(Theme.accent)
                }

                group("Agent") {
                    Toggle("Auto-apply changes (skip the Review Changes step)", isOn: $vee.settings.agentAutoApply)
                        .toggleStyle(.switch).tint(Theme.accent)
                    Stepper(value: $vee.settings.agentStepLimit, in: 5...200, step: 5) {
                        Text("Step limit: \(vee.settings.agentStepLimit) model turns per request").font(.system(size: 12))
                    }
                    Text("The agent writes files on disk so it can run them. Until you accept, every change can be rejected per hunk, per file or all at once, and each request is a checkpoint you can restore.")
                        .font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }

                group("Knowledge") {
                    Toggle("Look up The Vanta Book & docs for every request", isOn: $vee.settings.useBookKnowledge)
                        .toggleStyle(.switch).tint(Theme.accent)
                    Toggle("Index this workspace so Vee can find relevant code", isOn: $vee.settings.indexCodebase)
                        .toggleStyle(.switch).tint(Theme.accent)
                    KnowledgeStatus()
                }

                group("Privacy") {
                    Text("""
                    Vee sends your message, the relevant parts of your open file and workspace, and matching sections of The Vanta Book directly from this Mac to the provider you chose — there is no Vanta server in between. Autocomplete sends the code around your cursor. Keys are stored in the macOS Keychain, never in plain preferences. Chats are saved per workspace in ~/Library/Application Support/Vanta Studio/AI. Check your provider's data policy (Anthropic does not train on API data by default).
                    """).font(.system(size: 11.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }

                if vee.sessionUsage.total > 0 {
                    Text("This session: \(vee.sessionUsage.summary)").font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 420)
        .onAppear {
            customSmart = !options.contains(vee.settings.smartModel)
            customFast = !options.contains(vee.settings.fastModel)
        }
    }

    var options: [String] {
        var list = vee.modelCatalog.isEmpty ? AIProvider.curatedModels(vee.settings.provider) : vee.modelCatalog
        for m in AIProvider.curatedModels(vee.settings.provider).reversed() where !list.contains(m) { list.insert(m, at: 0) }
        return list
    }

    func modelRow(_ title: String, help: String, value: Binding<String>, custom: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(get: { custom.wrappedValue ? "__custom__" : value.wrappedValue },
                                              set: { v in if v == "__custom__" { custom.wrappedValue = true } else { custom.wrappedValue = false; value.wrappedValue = v } })) {
                    ForEach(withCurrent(value.wrappedValue), id: \.self) { m in Text(m).tag(m) }
                    Divider()
                    Text("Custom…").tag("__custom__")
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 300)
                if let p = Pricing.price(for: value.wrappedValue) {
                    Text(String(format: "$%.2g / $%.2g per M", p.input, p.output)).font(.system(size: 10.5)).foregroundColor(Theme.muted)
                }
            }
            if custom.wrappedValue {
                TextField("model id", text: value).textFieldStyle(.roundedBorder).padding(.leading, 104)
            }
            Text(help).font(.system(size: 11)).foregroundColor(Theme.muted).padding(.leading, 104)
        }
    }

    func withCurrent(_ v: String) -> [String] {
        var l = options
        if !v.isEmpty && !l.contains(v) { l.insert(v, at: 0) }
        return l
    }

    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }

    func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        vee.setKey(k)
        keyDraft = ""
        keyEditing = false
        testResult = nil
    }

    func testConnection() {
        testing = true
        testResult = nil
        let s = vee.settings, key = vee.apiKey
        Task { @MainActor in
            do {
                let r = try await AIClient.send(LLMRequest(model: s.smartModel, system: [SystemPart(text: "Reply with the single word: ok")],
                                                           messages: [.user("ping")], maxTokens: 64, purpose: .utility),
                                                settings: s, apiKey: key)
                testResult = "✓ \(AIPanel.shortModel(s.smartModel)) replied" + (r.usage.total > 0 ? " (\(r.usage.total) tokens)" : "")
            } catch {
                testResult = (error as? AIError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}

struct KnowledgeStatus: View {
    @ObservedObject var kb = KnowledgeBase.shared
    @ObservedObject var code = CodebaseIndex.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kb.isLoaded ? "Book: \(kb.documents.filter { $0.source == .book }.count) chapters + \(kb.documents.filter { $0.source == .docs }.count) docs, \(kb.chunks.count) sections indexed" : "Book: loading…")
            Text(code.indexing ? "Workspace: indexing…" : "Workspace: \(code.fileCount) files, \(code.chunkCount) chunks indexed")
        }
        .font(.system(size: 11)).foregroundColor(Theme.muted)
    }
}
