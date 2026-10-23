import Foundation

/// One `vanta debug --json` process and its wire protocol.
///
/// Commands go to the debugger's stdin as JSON lines; events come back on
/// stdout as lines starting with U+001E (record separator) followed by JSON.
/// Everything else on stdout is the program's own output. See
/// `vanta_tools/debugger.py` (`JsonDebugger`) for the other side.
final class DebugSession {
    struct Frame: Identifiable, Hashable {
        let id: Int
        let name: String
        let file: String
        let line: Int          // 1-based
    }

    struct Variable: Identifiable, Hashable {
        var id: String { "\(parentRef)/\(name)" }
        var parentRef = 0
        let name: String
        let value: String
        let type: String
        let ref: Int           // > 0 when it has children
        let count: Int?
    }

    enum Event {
        case ready
        case stopped(reason: String, file: String, line: Int, stack: [Frame])
        case continued
        case output(String)                     // program output (or a debugger note)
        case error(message: String, file: String?, line: Int?)
        case exited(Int32)
    }

    private let runner = ProcessRunner()
    private var buffer = ""
    private var seq = 0
    private var pending: [Int: (Any?) -> Void] = [:]
    var onEvent: (Event) -> Void = { _ in }
    private(set) var isAlive = false

    func start(python: String, vantaPy: URL, file: URL, arguments: [String], cwd: URL, environment: [String: String]) {
        isAlive = true
        runner.start(executable: python, arguments: [vantaPy.path, "debug", "--json", file.path] + arguments,
                     workingDirectory: cwd, environment: environment,
                     onOutput: { [weak self] s in self?.receive(s) },
                     onFinish: { [weak self] code in
                         guard let self else { return }
                         let wasAlive = self.isAlive
                         self.isAlive = false
                         self.flushText()
                         for (_, cb) in self.pending { cb(nil) }
                         self.pending = [:]
                         if wasAlive { self.onEvent(.exited(code)) }
                     })
    }

    /// Feed raw process output (exposed for the self-test).
    func receive(_ chunk: String) {
        buffer += chunk
        while true {
            guard let mark = buffer.firstIndex(of: "\u{1E}") else {
                flushText()
                return
            }
            if mark > buffer.startIndex { onEvent(.output(String(buffer[..<mark]))) }
            guard let nl = buffer[mark...].firstIndex(of: "\n") else {
                buffer = String(buffer[mark...])          // wait for the rest of the event
                return
            }
            let json = String(buffer[buffer.index(after: mark)..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            handle(json)
        }
    }

    private func flushText() {
        if !buffer.isEmpty && !buffer.hasPrefix("\u{1E}") { onEvent(.output(buffer)); buffer = "" }
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "ready": onEvent(.ready)
        case "stopped":
            onEvent(.stopped(reason: obj["reason"] as? String ?? "step", file: obj["file"] as? String ?? "",
                             line: obj["line"] as? Int ?? 0, stack: Self.frames(obj["stack"])))
        case "continued": onEvent(.continued)
        case "output": onEvent(.output(obj["text"] as? String ?? ""))
        case "error": onEvent(.error(message: obj["message"] as? String ?? "error", file: obj["file"] as? String, line: obj["line"] as? Int))
        case "exited":
            isAlive = false
            onEvent(.exited(Int32(obj["code"] as? Int ?? 0)))
        case "response":
            if let s = obj["seq"] as? Int, let cb = pending.removeValue(forKey: s) { cb(obj["body"]) }
        default: break
        }
    }

    static func frames(_ any: Any?) -> [Frame] {
        (any as? [[String: Any]] ?? []).map {
            Frame(id: $0["id"] as? Int ?? 0, name: $0["name"] as? String ?? "?", file: $0["file"] as? String ?? "", line: $0["line"] as? Int ?? 0)
        }
    }

    static func variable(_ d: [String: Any], parent: Int) -> Variable {
        Variable(parentRef: parent, name: d["name"] as? String ?? "?", value: d["value"] as? String ?? "",
                 type: d["type"] as? String ?? "", ref: d["ref"] as? Int ?? 0, count: d["count"] as? Int)
    }

    // MARK: commands

    func send(_ obj: [String: Any]) {
        guard isAlive, let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        if ProcessInfo.processInfo.environment["VANTA_DEBUG_TRACE"] != nil { print("→ debugger: \(s)") }
        runner.write(s + "\n")
    }

    private func request(_ obj: [String: Any], _ done: @escaping (Any?) -> Void) {
        guard isAlive else { done(nil); return }
        seq += 1
        var o = obj
        o["seq"] = seq
        pending[seq] = done
        send(o)
    }

    func setBreakpoints(file: String, _ bps: [(line: Int, condition: String?)]) {
        send(["cmd": "setBreakpoints", "file": file,
              "breakpoints": bps.map { b -> [String: Any] in
                  var d: [String: Any] = ["line": b.line]
                  if let c = b.condition { d["condition"] = c }
                  return d
              }])
    }

    func begin(stopOnEntry: Bool) { send(["cmd": "start", "stopOnEntry": stopOnEntry]) }
    func command(_ name: String) { send(["cmd": name]) }
    func pause() { send(["cmd": "pause"]) }
    func input(_ text: String) { send(["cmd": "input", "text": text]) }

    func scopes(frame: Int, _ done: @escaping ([(name: String, ref: Int)]) -> Void) {
        request(["cmd": "scopes", "frame": frame]) { body in
            done((body as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["ref"] as? Int ?? 0) })
        }
    }

    func variables(ref: Int, _ done: @escaping ([Variable]) -> Void) {
        request(["cmd": "variables", "ref": ref]) { body in
            done((body as? [[String: Any]] ?? []).map { Self.variable($0, parent: ref) })
        }
    }

    /// Result is a Variable, or an error message.
    func evaluate(_ expr: String, frame: Int, _ done: @escaping (Result<Variable, EvalError>) -> Void) {
        request(["cmd": "evaluate", "expr": expr, "frame": frame]) { body in
            guard let d = body as? [String: Any] else { done(.failure(EvalError(message: "the program isn't paused"))); return }
            if let e = d["error"] as? String { done(.failure(EvalError(message: e))) } else { done(.success(Self.variable(d, parent: -1))) }
        }
    }

    struct EvalError: Error { let message: String }

    func terminate() {
        guard isAlive else { return }
        send(["cmd": "quit"])
        let r = runner
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if r.isRunning { r.stop() } }
    }

    func kill() {
        isAlive = false
        runner.stop()
    }
}
