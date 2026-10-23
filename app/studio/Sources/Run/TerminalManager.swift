import AppKit
import SwiftUI
import SwiftTerm

/// One integrated terminal: the user's login shell on a pty, rendered by
/// SwiftTerm (VT100/xterm: cursor addressing, 16/256/truecolor, alternate
/// screen for vim/htop/less, scrollback, mouse reporting, selection/copy/paste,
/// TIOCSWINSZ on resize).
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view: StudioTerminalView
    @Published var title: String
    @Published private(set) var cwd: String?
    @Published private(set) var exited: Int32?
    let shellName: String
    private let number: Int

    init(number: Int, cwd: URL?) {
        self.number = number
        let shell = TerminalManager.loginShell
        shellName = (shell as NSString).lastPathComponent
        title = shellName
        view = StudioTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        super.init()
        view.processDelegate = self
        view.getTerminal().changeHistorySize(10_000)
        view.optionAsMetaKey = false               // ⌥ types special characters like every Mac app
        TerminalManager.applyAppearance(view)
        let dir = cwd?.path ?? NSHomeDirectory()
        self.cwd = dir
        view.startProcess(executable: shell, args: ["-l"], environment: TerminalManager.environment(),
                          execName: "-" + shellName, currentDirectory: dir)
    }

    var displayTitle: String { title.isEmpty ? "\(shellName) \(number)" : title }

    func send(_ text: String) { view.send(txt: text) }

    func terminate() { if exited == nil { view.terminate() } }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        DispatchQueue.main.async { self.cwd = path }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.exited = exitCode ?? 0
            self.view.feed(text: "\r\n\u{1B}[2m[process exited with code \(exitCode ?? 0) — press ⏎ to start a new shell]\u{1B}[0m\r\n")
        }
    }
}

/// The terminal view with a few IDE touches: ⏎ restarts an exited shell,
/// right-click menu, and files dropped from Finder paste their quoted paths.
final class StudioTerminalView: LocalProcessTerminalView {
    var onRestart: (() -> Void)?
    var isExited: () -> Bool = { false }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if isExited() {
            if data.contains(13) { onRestart?() }
            return
        }
        super.send(source: source, data: data)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let clear = NSMenuItem(title: "Clear", action: #selector(clearScreen), keyEquivalent: "")
        clear.target = self
        m.addItem(clear)
        return m
    }

    @objc func clearScreen() {
        // clear screen + scrollback, then ask the shell to redraw its prompt
        feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        send(txt: "\u{0C}")
    }

    override func awakeFromNib() { super.awakeFromNib(); registerForDraggedTypes([.fileURL]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        send(txt: urls.map { ShellWords.quote($0.path) }.joined(separator: " ") + " ")
        return true
    }
}

/// All terminal tabs. Views live here (not in SwiftUI state) so they survive
/// the panel being hidden and shown again.
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID?
    private var counter = 0

    var active: TerminalSession? { sessions.first { $0.id == activeID } ?? sessions.last }

    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        if let s = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/zsh"
    }

    static func environment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let keep = ["USER", "LOGNAME", "HOME", "PATH", "SSH_AUTH_SOCK", "TMPDIR", "__CF_USER_TEXT_ENCODING"]
        let pe = ProcessInfo.processInfo.environment
        for k in keep { if let v = pe[k], !env.contains(where: { $0.hasPrefix(k + "=") }) { env.append("\(k)=\(v)") } }
        if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=en_US.UTF-8") }
        env.append("TERM_PROGRAM=VantaStudio")
        env.append("TERM_PROGRAM_VERSION=2.0")
        if let rt = VantaInstall.resolve() { env.append("VANTA_HOME=\(rt.home.path)") }
        return env
    }

    @discardableResult
    func newSession(cwd: URL? = nil) -> TerminalSession {
        counter += 1
        let dir = cwd ?? Services.shared.workspace.root
        let s = TerminalSession(number: counter, cwd: dir)
        s.view.onRestart = { [weak self, weak s] in
            guard let self, let s else { return }
            let d = s.cwd.map { URL(fileURLWithPath: $0) }
            self.replace(s, cwd: d)
        }
        s.view.isExited = { [weak s] in s?.exited != nil }
        s.view.registerForDraggedTypes([.fileURL])
        sessions.append(s)
        activeID = s.id
        return s
    }

    private func replace(_ old: TerminalSession, cwd: URL?) {
        guard let i = sessions.firstIndex(where: { $0.id == old.id }) else { return }
        let fresh = newSession(cwd: cwd)
        sessions.removeLast()
        sessions[i] = fresh
        activeID = fresh.id
        focusActive()
    }

    func close(_ s: TerminalSession) {
        s.terminate()
        sessions.removeAll { $0.id == s.id }
        if activeID == s.id { activeID = sessions.last?.id }
    }

    func closeActive() { if let a = active { close(a) } }

    func ensureSession() { if sessions.isEmpty { newSession() } }

    func focusActive() {
        guard let v = active?.view else { return }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }

    /// Run a command line in the active terminal (opening one if needed).
    func run(_ command: String, cwd: URL? = nil) {
        ensureSession()
        Services.shared.layout.showBottom(PanelID.terminal)
        guard let s = active else { return }
        if let cwd { s.send("cd \(ShellWords.quote(cwd.path))\r") }
        s.send(command + "\r")
        focusActive()
    }

    func clearActive() { active?.view.clearScreen() }

    func terminateAll() { sessions.forEach { $0.terminate() } }

    // MARK: appearance

    static func applyAppearance(_ v: TerminalView) {
        let app = v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSAppearance(named: .aqua)! : NSAppearance(named: .darkAqua)!
        var bg = NSColor.black, fg = NSColor.white, caret = NSColor.white, sel = NSColor.gray
        app.performAsCurrentDrawingAppearance {
            bg = (Theme.nbg.usingColorSpace(.sRGB) ?? .black)
            fg = (Theme.nink.usingColorSpace(.sRGB) ?? .white)
            caret = (Theme.nAccent.usingColorSpace(.sRGB) ?? .white)
            sel = (Theme.nselection.usingColorSpace(.sRGB) ?? .gray)
        }
        v.nativeBackgroundColor = bg
        v.nativeForegroundColor = fg
        v.caretColor = caret
        v.selectedTextBackgroundColor = sel
        let dark = app.name == .darkAqua
        let palette = (dark ? ANSIColours.dark : ANSIColours.light).map { hex -> SwiftTerm.Color in
            let r = UInt16((hex >> 16) & 0xff), g = UInt16((hex >> 8) & 0xff), b = UInt16(hex & 0xff)
            return SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
        }
        v.installColors(palette)
        let size = CGFloat(StudioSettings.shared.prefs.fontSize)
        let name = StudioSettings.shared.prefs.fontName
        let font = (!name.isEmpty ? NSFont(name: name, size: size) : nil) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if v.font != font { v.font = font }
    }
}
