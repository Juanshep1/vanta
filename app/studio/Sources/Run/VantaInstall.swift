import Foundation

/// Finds the Vanta installation programs run with.
///
/// Order: the folder set in Run settings → `$VANTA_HOME` → a Vanta checkout that
/// contains the workspace → the runtime bundled in the app (when it ships
/// vanta_tools) → `~/projects/vanta` → the `vanta` launcher on PATH → the bare
/// bundled interpreter. A full installation (with `vanta_tools/`)
/// gives the debugger and `native/vantac.py` the native build; the bundled copy
/// only runs programs.
struct VantaInstall: Equatable {
    /// Folder holding vanta.py.
    let home: URL
    let source: String

    var vantaPy: URL { home.appendingPathComponent("vanta.py") }
    var vantac: URL? {
        let u = home.appendingPathComponent("native/vantac.py")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var debuggerPy: URL? {
        let u = home.appendingPathComponent("vanta_tools/debugger.py")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    /// The debugger speaks the JSON-lines protocol (`vanta debug --json`).
    var supportsDebugJSON: Bool {
        guard let d = debuggerPy, let text = try? String(contentsOf: d, encoding: .utf8) else { return false }
        return text.contains("def main_json")
    }
    var isBundled: Bool { source == "bundled" }

    /// The version string from vanta.py (`VERSION = "6.0"`), read lazily and cached.
    var version: String {
        if let v = Self.versionCache[home.path] { return v }
        var v = "?"
        if let h = FileHandle(forReadingAtPath: vantaPy.path) {
            let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
            if let r = head.range(of: #"VERSION = "([^"]+)""#, options: .regularExpression) {
                v = head[r].replacingOccurrences(of: "VERSION = ", with: "").replacingOccurrences(of: "\"", with: "")
            }
            try? h.close()
        }
        Self.versionCache[home.path] = v
        return v
    }
    private static var versionCache: [String: String] = [:]

    static func isInstall(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("vanta.py").path)
    }
    static func isFullInstall(_ dir: URL) -> Bool {
        isInstall(dir) && FileManager.default.fileExists(atPath: dir.appendingPathComponent("vanta_tools").path)
    }

    static var bundled: VantaInstall? {
        Bundle.main.url(forResource: "vanta", withExtension: "py", subdirectory: "runtime")
            .map { VantaInstall(home: $0.deletingLastPathComponent(), source: "bundled") }
    }

    /// Resolve for the current workspace (cheap: a handful of stat calls).
    static func resolve(workspace: URL? = Services.shared.workspace.root) -> VantaInstall? {
        let fm = FileManager.default
        let custom = RunSettings.shared.vantaHome.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let u = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if isInstall(u) { return VantaInstall(home: u, source: "settings") }
        }
        if let env = ProcessInfo.processInfo.environment["VANTA_HOME"], isInstall(URL(fileURLWithPath: env)) {
            return VantaInstall(home: URL(fileURLWithPath: env), source: "VANTA_HOME")
        }
        if var dir = workspace?.standardizedFileURL {
            for _ in 0..<8 {
                if isFullInstall(dir) { return VantaInstall(home: dir, source: "workspace") }
                let up = dir.deletingLastPathComponent()
                if up.path == dir.path { break }
                dir = up
            }
        }
        if let b = bundled, isFullInstall(b.home) { return b }
        let dev = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta")
        if isFullInstall(dev) { return VantaInstall(home: dev, source: "~/projects/vanta") }
        if let launcher = launcherHome() { return VantaInstall(home: launcher, source: "vanta on PATH") }
        return bundled
    }

    /// An installation that has the native compiler (the bundled runtime doesn't
    /// ship native/vantac.py, so fall back to a checkout or a vanbrew install).
    static func withCompiler(workspace: URL? = Services.shared.workspace.root) -> VantaInstall? {
        if let r = resolve(workspace: workspace), r.vantac != nil { return r }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta")
        let candidates = [VantaInstall(home: dev, source: "~/projects/vanta")]
            + (launcherHome().map { [VantaInstall(home: $0, source: "vanta on PATH")] } ?? [])
        return candidates.first { $0.vantac != nil }
    }

    /// Parse a `vanta` shell launcher (`exec python3 "/…/vanta.py" "$@"`) on PATH.
    private static func launcherHome() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.vanbrew/bin", NSHomeDirectory() + "/.local/bin"]
        for p in paths {
            let f = URL(fileURLWithPath: p).appendingPathComponent("vanta")
            guard let text = try? String(contentsOf: f, encoding: .utf8), text.count < 4000,
                  let r = text.range(of: #""?(/[^"\s]+/vanta\.py)"?"#, options: .regularExpression) else { continue }
            let path = text[r].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if isInstall(dir) { return dir }
        }
        return nil
    }
}

/// Paths from child processes may differ from the editor's (`/tmp` vs
/// `/private/tmp`, symlinks). Map them onto the URI an open document uses.
enum FilePaths {
    static func real(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }

    static func documentURI(for url: URL) -> URL {
        let r = real(url)
        if let doc = Services.shared.documents.documents.first(where: { $0.url.map(real) == r }) { return doc.uri }
        return url.standardizedFileURL
    }
}
