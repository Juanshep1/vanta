import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

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
                    })) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().pickerStyle(.menu)
            }

            field("API key") {
                SecureField("paste your key", text: $model.settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            field("Model") {
                TextField(AIClient.defaultModel(for: model.settings.provider), text: $model.settings.model)
                    .textFieldStyle(.roundedBorder)
            }

            if model.settings.provider == "ollama-cloud" || model.settings.provider == "nvidia" {
                field("Base URL (optional)") {
                    TextField(AIClient.defaultBase(for: model.settings.provider), text: $model.settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

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
