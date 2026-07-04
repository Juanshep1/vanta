import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var catalog = ModelCatalog()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                Form {
                    Section("vcode — AI provider") {
                        Picker("Provider", selection: $model.ai.provider) {
                            Text("OpenRouter").tag("openrouter")
                            Text("Anthropic").tag("anthropic")
                            Text("Ollama Cloud").tag("ollama-cloud")
                            Text("NVIDIA").tag("nvidia")
                        }
                        .onChange(of: model.ai.provider) {
                            model.ai.model = AIClient.defaultModel(for: model.ai.provider)
                            catalog.load(settings: model.ai)
                        }
                        SecureField("API key", text: $model.ai.apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        NavigationLink {
                            ModelPickerScreen(catalog: catalog)
                        } label: {
                            LabeledContent("Model") {
                                Text(model.ai.model)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                            }
                        }
                        Toggle("Auto-run & fix programs", isOn: $model.autoFix)
                    }

                    Section("Editor") {
                        HStack {
                            Text("Font size")
                            Slider(value: $model.fontSize, in: 11...22, step: 1)
                            Text("\(Int(model.fontSize))")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    Section("Engine") {
                        HStack {
                            Text("Vanta engine")
                            Spacer()
                            EngineBadge()
                        }
                        Button("Restart engine") { model.engine.restart() }
                            .foregroundStyle(Theme.gold)
                        Text("Programs run on-device: the real Vanta interpreter inside CPython compiled to WebAssembly. No server, no network, nothing leaves your phone (except vcode chats to your AI provider).")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }

                    Section("About") {
                        LabeledContent("App", value: "Vanta Pocket 1.0")
                        LabeledContent("Language", value: "Vanta 5.0")
                        Link("Vanta on GitHub",
                             destination: URL(string: "https://github.com/Juanshep1/vanta")!)
                        Link("vcode on GitHub",
                             destination: URL(string: "https://github.com/Juanshep1/vcode")!)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .onAppear { catalog.load(settings: model.ai) }
        }
    }
}

// The provider's full live model catalog (OpenRouter's is public — several
// hundred models, no key needed), cached per provider so it works offline
// after the first load.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published var models: [String] = []
    @Published var loading = false
    @Published var error: String?
    private var loadedProvider: String?

    func load(settings: AISettings, force: Bool = false) {
        let provider = settings.provider
        if !force, loadedProvider == provider, !models.isEmpty { return }
        loadedProvider = provider
        models = cached(for: provider) ?? AIClient.curatedModels(for: provider)
        error = nil
        loading = true
        Task {
            defer { loading = false }
            do {
                let live = try await AIClient.fetchModels(settings: settings)
                models = live
                cache(live, for: provider)
            } catch {
                // Keep the cached/curated list; only surface the error if we
                // have nothing better than the short curated list.
                if cached(for: provider) == nil { self.error = error.localizedDescription }
            }
        }
    }

    private func cacheKey(_ provider: String) -> String { "model-catalog-\(provider)" }
    private func cached(for provider: String) -> [String]? {
        let list = UserDefaults.standard.stringArray(forKey: cacheKey(provider))
        return (list?.isEmpty == false) ? list : nil
    }
    private func cache(_ list: [String], for provider: String) {
        UserDefaults.standard.set(list, forKey: cacheKey(provider))
    }
}

// Browse and search every model the provider offers.
struct ModelPickerScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var catalog: ModelCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return catalog.models }
        return catalog.models.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            List {
                if catalog.loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Fetching the full catalog…")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    .listRowBackground(Theme.panel)
                }
                if let error = catalog.error {
                    Text(error).font(.caption).foregroundStyle(Theme.red)
                        .listRowBackground(Theme.panel)
                }
                Section {
                    ForEach(filtered, id: \.self) { id in
                        Button {
                            model.ai.model = id
                            dismiss()
                        } label: {
                            HStack {
                                Text(id)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Spacer()
                                if id == model.ai.model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Theme.panel)
                    }
                } header: {
                    Text("\(filtered.count) of \(catalog.models.count) models")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $search, prompt: "Search models")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    catalog.load(settings: model.ai, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(catalog.loading)
            }
        }
    }
}
