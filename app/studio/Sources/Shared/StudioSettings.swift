import SwiftUI
import AppKit

/// Persisted, app-wide preferences (Editor / Appearance / Run). AI settings live
/// with the AI module (`VeeAssistant.settings`) and add their own Settings tab
/// through `PanelRegistry.registerSettingsSection`.
struct StudioPrefs: Codable, Equatable {
    enum AppearanceMode: String, Codable, CaseIterable { case system, dark, light }
    enum AutosaveMode: String, Codable, CaseIterable { case off, afterDelay, onFocusChange }

    // Editor
    var fontName: String = ""              // "" = SF Mono (system monospaced)
    var fontSize: Double = 13
    var lineHeight: Double = 1.35
    var tabSize: Int = 4
    var wordWrap: Bool = false
    var showLineNumbers: Bool = true
    var highlightCurrentLine: Bool = true
    var showIndentGuides: Bool = true
    var autoCloseBrackets: Bool = true
    var autosave: AutosaveMode = .off
    var autosaveDelay: Double = 1.0
    var trimTrailingWhitespace: Bool = false

    // Appearance
    var appearance: AppearanceMode = .dark

    // Workspace
    var reopenLastWorkspace: Bool = true

    // Run
    var pythonPath: String = ""            // "" = auto-detect
    var saveBeforeRun: Bool = true
    var clearConsoleOnRun: Bool = true
    var programArguments: String = ""

    init() {}

    // Tolerant decoding: new fields fall back to defaults instead of wiping prefs.
    init(from decoder: Decoder) throws {
        let d = StudioPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? def }
        fontName = v(.fontName, d.fontName); fontSize = v(.fontSize, d.fontSize)
        lineHeight = v(.lineHeight, d.lineHeight); tabSize = v(.tabSize, d.tabSize)
        wordWrap = v(.wordWrap, d.wordWrap); showLineNumbers = v(.showLineNumbers, d.showLineNumbers)
        highlightCurrentLine = v(.highlightCurrentLine, d.highlightCurrentLine)
        showIndentGuides = v(.showIndentGuides, d.showIndentGuides)
        autoCloseBrackets = v(.autoCloseBrackets, d.autoCloseBrackets)
        autosave = v(.autosave, d.autosave); autosaveDelay = v(.autosaveDelay, d.autosaveDelay)
        trimTrailingWhitespace = v(.trimTrailingWhitespace, d.trimTrailingWhitespace)
        appearance = v(.appearance, d.appearance)
        reopenLastWorkspace = v(.reopenLastWorkspace, d.reopenLastWorkspace)
        pythonPath = v(.pythonPath, d.pythonPath); saveBeforeRun = v(.saveBeforeRun, d.saveBeforeRun)
        clearConsoleOnRun = v(.clearConsoleOnRun, d.clearConsoleOnRun)
        programArguments = v(.programArguments, d.programArguments)
    }
}

final class StudioSettings: ObservableObject {
    static let shared = StudioSettings()
    private let key = "vanta-studio-2-prefs"
    var persist = true

    @Published var prefs = StudioPrefs() {
        didSet {
            guard prefs != oldValue else { return }
            save()
            if prefs.appearance != oldValue.appearance { applyAppearance() }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode(StudioPrefs.self, from: data) {
            prefs = p
        }
    }

    func save() {
        guard persist, let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    var editorFont: NSFont {
        let size = CGFloat(prefs.fontSize)
        if !prefs.fontName.isEmpty, let f = NSFont(name: prefs.fontName, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var colorScheme: ColorScheme? {
        switch prefs.appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    func applyAppearance() {
        switch prefs.appearance {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        }
    }

    var nsAppearance: NSAppearance? {
        switch prefs.appearance {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}
