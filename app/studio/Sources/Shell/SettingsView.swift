import SwiftUI
import AppKit

/// Settings window (⌘,): Editor · Appearance · Run · plus sections modules register (AI…).
struct SettingsView: View {
    @ObservedObject var panels = PanelRegistry.shared
    @ObservedObject var settings = StudioSettings.shared

    var body: some View {
        TabView {
            EditorSettingsPane().tabItem { Label("Editor", systemImage: "text.cursor") }
            AppearanceSettingsPane().tabItem { Label("Appearance", systemImage: "paintpalette") }
            RunSettingsPane().tabItem { Label("Run", systemImage: "play.circle") }
            ForEach(panels.settingsSections.sorted { $0.order < $1.order }) { s in
                s.makeView().tabItem { Label(s.title, systemImage: s.icon) }
            }
        }
        .frame(width: 560)
        .preferredColorScheme(settings.colorScheme)
    }
}

struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(minHeight: 380)
    }
}

struct EditorSettingsPane: View {
    @ObservedObject var s = StudioSettings.shared
    static let monoFonts: [String] = {
        let fm = NSFontManager.shared
        let names = fm.availableFontFamilies.filter { fam in
            guard let f = NSFont(name: fam, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
        }
        return names.sorted()
    }()

    var body: some View {
        SettingsForm {
            Section("Font") {
                Picker("Font", selection: $s.prefs.fontName) {
                    Text("SF Mono (default)").tag("")
                    ForEach(Self.monoFonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $s.prefs.fontSize, in: 8...32, step: 1) {
                    LabeledContent("Size", value: "\(Int(s.prefs.fontSize)) pt")
                }
                Picker("Line height", selection: $s.prefs.lineHeight) {
                    Text("Compact (1.2)").tag(1.2)
                    Text("Comfortable (1.35)").tag(1.35)
                    Text("Relaxed (1.5)").tag(1.5)
                }
            }
            Section("Editing") {
                Picker("Tab size", selection: $s.prefs.tabSize) {
                    Text("2 spaces").tag(2); Text("4 spaces").tag(4); Text("8 spaces").tag(8)
                }
                Toggle("Word wrap", isOn: $s.prefs.wordWrap)
                Toggle("Auto-close brackets and quotes", isOn: $s.prefs.autoCloseBrackets)
                Toggle("Trim trailing whitespace on save", isOn: $s.prefs.trimTrailingWhitespace)
            }
            Section("Display") {
                Toggle("Line numbers", isOn: $s.prefs.showLineNumbers)
                Toggle("Highlight current line", isOn: $s.prefs.highlightCurrentLine)
                Toggle("Indent guides", isOn: $s.prefs.showIndentGuides)
            }
            Section("Files") {
                Picker("Autosave", selection: $s.prefs.autosave) {
                    Text("Off").tag(StudioPrefs.AutosaveMode.off)
                    Text("After a delay").tag(StudioPrefs.AutosaveMode.afterDelay)
                    Text("When focus changes").tag(StudioPrefs.AutosaveMode.onFocusChange)
                }
                if s.prefs.autosave == .afterDelay {
                    Stepper(value: $s.prefs.autosaveDelay, in: 0.5...10, step: 0.5) {
                        LabeledContent("Delay", value: String(format: "%.1f s", s.prefs.autosaveDelay))
                    }
                }
                Toggle("Reopen last folder on launch", isOn: $s.prefs.reopenLastWorkspace)
            }
        }
    }
}

struct AppearanceSettingsPane: View {
    @ObservedObject var s = StudioSettings.shared
    var body: some View {
        SettingsForm {
            Section("Theme") {
                Picker("Appearance", selection: $s.prefs.appearance) {
                    Text("Vanta Night (dark)").tag(StudioPrefs.AppearanceMode.dark)
                    Text("Vanta Day (light)").tag(StudioPrefs.AppearanceMode.light)
                    Text("Match System").tag(StudioPrefs.AppearanceMode.system)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Preview") {
                ThemePreview().frame(height: 130)
            }
        }
    }
}

struct ThemePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line([("to ", Theme.ndecl), ("greet", Theme.nfnDef), ("(name)", Theme.nink)])
            line([("    say ", Theme.nkw), ("\"Hello, ", Theme.nstr), ("{name}", Theme.nescape), ("!\"", Theme.nstr)])
            line([("end", Theme.nkw)])
            line([("let ", Theme.nkw), ("n ", Theme.nink), ("be ", Theme.nkw), ("42", Theme.nnum), ("  # the answer", Theme.ncom)])
            line([("if ", Theme.nkw), ("n ", Theme.nink), ("is at least ", Theme.nopword), ("10", Theme.nnum)])
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editorBg))
    }
    func line(_ parts: [(String, NSColor)]) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor(Color(nsColor: $1.1)) }
            .font(.system(size: 12.5, design: .monospaced))
    }
}

struct RunSettingsPane: View {
    @ObservedObject var s = StudioSettings.shared
    var body: some View {
        SettingsForm {
            Section("Interpreter") {
                TextField("python3 path", text: $s.prefs.pythonPath, prompt: Text("auto-detect"))
                Text("Vanta runs through the bundled interpreter (vanta.py) on your python3.")
                    .font(.system(size: 11)).foregroundColor(Theme.muted)
            }
            Section("Running") {
                Toggle("Save file before running", isOn: $s.prefs.saveBeforeRun)
                Toggle("Clear console on run", isOn: $s.prefs.clearConsoleOnRun)
                TextField("Program arguments", text: $s.prefs.programArguments, prompt: Text("e.g. --verbose input.txt"))
            }
        }
    }
}
