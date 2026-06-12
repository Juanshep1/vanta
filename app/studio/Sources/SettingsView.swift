import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var customModel = false

    private let providers = [
        ("openrouter", "OpenRouter (any model)"),
        ("anthropic", "Anthropic (Claude)"),
        ("ollama-cloud", "Ollama Cloud"),
        ("nvidia", "NVIDIA NIM"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vee — AI settings").font(.system(size: 17, weight: .bold))

            field("Provider") {
                Picker("", selection: Binding(
                    get: { model.settings.provider },
                    set: { p in
                        model.settings.provider = p
                        model.settings.model = AIClient.defaultModel(for: p)
                        model.settings.baseURL = ""
                        model.modelCatalog = []
                        model.modelError = nil
                        customModel = false
                    })) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().pickerStyle(.menu)
            }

            field("API key") {
                SecureField("paste your key", text: $model.settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            field("Model") {
                HStack(spacing: 8) {
                    Picker("", selection: modelSelection) {
                        ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Custom…").tag("__custom__")
                    }
                    .labelsHidden().pickerStyle(.menu)

                    Button { model.refreshModels() } label: {
                        if model.modelsLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Fetch the latest models from your provider (needs your API key)")
                    .disabled(model.modelsLoading)
                }
                if customModel {
                    TextField(AIClient.defaultModel(for: model.settings.provider),
                              text: $model.settings.model)
                        .textFieldStyle(.roundedBorder)
                }
                if let err = model.modelError {
                    Text(err).font(.system(size: 11)).foregroundColor(Theme.red)
                } else if !model.modelCatalog.isEmpty {
                    Text("\(model.modelCatalog.count) models from \(model.settings.provider)")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }

            if model.settings.provider == "ollama-cloud" || model.settings.provider == "nvidia" {
                field("Base URL (optional)") {
                    TextField(AIClient.defaultBase(for: model.settings.provider), text: $model.settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Toggle(isOn: $model.settings.autocomplete) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI tab-autocomplete").font(.system(size: 13, weight: .semibold))
                    Text("Ghost-text suggestions as you type — press Tab to accept.")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            Text(note).font(.system(size: 11.5)).foregroundColor(Theme.muted)

            HStack {
                Spacer()
                Button("Done") { model.saveSettings(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.panel)
        .foregroundColor(Theme.ink)
        .onAppear {
            customModel = !modelOptions.contains(model.settings.model)
            if model.modelCatalog.isEmpty && !model.settings.apiKey.isEmpty {
                model.refreshModels()
            }
        }
    }

    // The list shown in the dropdown: the live catalog if we have it, otherwise
    // a curated starter list — always including whatever is currently selected.
    var modelOptions: [String] {
        var list = model.modelCatalog.isEmpty
            ? AIClient.curatedModels(for: model.settings.provider)
            : model.modelCatalog
        let current = model.settings.model
        if !current.isEmpty && current != "__custom__" && !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { customModel ? "__custom__" : model.settings.model },
            set: { value in
                if value == "__custom__" {
                    customModel = true
                } else {
                    customModel = false
                    model.settings.model = value
                }
            })
    }

    var note: String {
        switch model.settings.provider {
        case "anthropic": return "Key from console.anthropic.com. Native call — no browser CORS limits."
        case "ollama-cloud": return "Key from ollama.com/settings. Because this app calls it natively (not from a browser), Ollama Cloud works directly — no CORS issues."
        case "nvidia": return "Key from build.nvidia.com (free tier). Native call works directly — no CORS issues."
        default: return "Key from openrouter.ai/keys — any model slug from openrouter.ai/models. Your key stays on this Mac."
        }
    }

    func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.muted)
            content()
        }
    }
}
