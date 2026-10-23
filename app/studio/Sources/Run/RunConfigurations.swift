import Foundation
import Combine

/// How a configuration runs its program.
enum RunMode: String, Codable, CaseIterable, Identifiable {
    case interpret, native
    var id: String { rawValue }
    var title: String { self == .interpret ? "Interpreter" : "Build native" }
}

/// Which file a configuration runs.
enum RunTarget: Codable, Hashable {
    case currentFile
    case entryPoint                      // vanta.json "main" (falls back to the current file)
    case file(String)                    // path, relative to the workspace or absolute

    var title: String {
        switch self {
        case .currentFile: return "Current file"
        case .entryPoint: return "Workspace entry point"
        case .file(let p): return p
        }
    }
}

/// A named way to run: target, arguments, environment, working directory, mode.
struct RunConfiguration: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var target: RunTarget = .currentFile
    var arguments: String = ""
    /// One `KEY=VALUE` per line.
    var environment: String = ""
    /// "" = the program's folder. `${workspace}` expands to the workspace root.
    var workingDirectory: String = ""
    var mode: RunMode = .interpret

    static let currentFileID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    static var currentFile: RunConfiguration { RunConfiguration(id: currentFileID, name: "Current File") }

    var parsedArguments: [String] { ShellWords.split(arguments) }

    var parsedEnvironment: [String: String] {
        var out: [String: String] = [:]
        for raw in environment.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            if !k.isEmpty { out[k] = v }
        }
        return out
    }
}

/// Persisted Run-module state (its own UserDefaults key, so it never collides
/// with StudioPrefs): configurations, the chosen one, the Vanta folder override,
/// breakpoint conditions and debugger watch expressions.
final class RunSettings: ObservableObject {
    static let shared = RunSettings()
    private let key = "vanta-studio-2-run"

    struct Stored: Codable {
        var configurations: [RunConfiguration] = []
        var selected: UUID? = nil
        var vantaHome: String = ""
        var conditions: [String: String] = [:]      // "path:line" (0-based) → condition
        var watches: [String] = []
        var stopOnEntry = false
    }

    @Published var configurations: [RunConfiguration] = [] { didSet { save() } }
    @Published var selectedID: UUID = RunConfiguration.currentFileID { didSet { save() } }
    @Published var vantaHome: String = "" { didSet { save() } }
    @Published var conditions: [String: String] = [:] { didSet { save() } }
    @Published var watches: [String] = [] { didSet { save() } }
    @Published var stopOnEntry = false { didSet { save() } }
    private var loading = false

    private init() {
        loading = true
        if let data = UserDefaults.standard.data(forKey: key), let st = try? JSONDecoder().decode(Stored.self, from: data) {
            configurations = st.configurations
            selectedID = st.selected ?? RunConfiguration.currentFileID
            vantaHome = st.vantaHome
            conditions = st.conditions
            watches = st.watches
            stopOnEntry = st.stopOnEntry
        }
        if !configurations.contains(where: { $0.id == RunConfiguration.currentFileID }) {
            configurations.insert(.currentFile, at: 0)
        }
        loading = false
    }

    private func save() {
        guard !loading, !Services.shared.isSnapshot else { return }
        let st = Stored(configurations: configurations, selected: selectedID, vantaHome: vantaHome,
                        conditions: conditions, watches: watches, stopOnEntry: stopOnEntry)
        if let data = try? JSONEncoder().encode(st) { UserDefaults.standard.set(data, forKey: key) }
    }

    var selected: RunConfiguration {
        get { configurations.first { $0.id == selectedID } ?? .currentFile }
        set {
            if let i = configurations.firstIndex(where: { $0.id == newValue.id }) { configurations[i] = newValue }
        }
    }

    @discardableResult
    func addConfiguration(_ base: RunConfiguration? = nil) -> RunConfiguration {
        var c = base ?? RunConfiguration(name: "Configuration \(configurations.count)")
        c.id = UUID()
        if base != nil { c.name += " copy" }
        configurations.append(c)
        selectedID = c.id
        return c
    }

    func remove(_ id: UUID) {
        guard id != RunConfiguration.currentFileID else { return }
        configurations.removeAll { $0.id == id }
        if selectedID == id { selectedID = RunConfiguration.currentFileID }
    }

    // MARK: breakpoint conditions

    static func conditionKey(_ uri: URL, _ line: Int) -> String { "\(uri.standardizedFileURL.path):\(line)" }
    func condition(_ uri: URL, _ line: Int) -> String? {
        let c = conditions[Self.conditionKey(uri, line)]
        return (c?.isEmpty ?? true) ? nil : c
    }
    func setCondition(_ text: String?, _ uri: URL, _ line: Int) {
        let t = text?.trimmingCharacters(in: .whitespaces) ?? ""
        conditions[Self.conditionKey(uri, line)] = t.isEmpty ? nil : t
    }
}

/// vanta.json `"main"` for a workspace.
enum WorkspaceManifest {
    static func entryPoint(_ root: URL?) -> URL? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("vanta.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = obj["main"] as? String, !main.isEmpty else { return nil }
        let u = main.hasPrefix("/") ? URL(fileURLWithPath: main) : root.appendingPathComponent(main)
        return FileManager.default.fileExists(atPath: u.path) ? u.standardizedFileURL : nil
    }
}

/// POSIX-shell-like word splitting for argument fields: quotes and backslashes.
enum ShellWords {
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var has = false
        var quote: Character?
        var escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; has = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; has = true; continue }
            if ch.isWhitespace {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
