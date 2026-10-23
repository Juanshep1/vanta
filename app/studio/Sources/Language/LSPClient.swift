import Foundation

/// Where the Vanta runtime lives and how to start python on it.
enum VantaRuntime {
    /// `Resources/runtime` inside the app (vanta.py + vanta_tools + lib + docs).
    static var directory: URL? {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
           FileManager.default.fileExists(atPath: u.appendingPathComponent("vanta.py").path) { return u }
        return nil
    }
    static var vantaPy: URL? { directory?.appendingPathComponent("vanta.py") }

    static func python() -> String? {
        let custom = StudioSettings.shared.prefs.pythonPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty && FileManager.default.isExecutableFile(atPath: custom) { return custom }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                  "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Run `python3 vanta.py ARGS` to completion (off the main thread).
    static func run(_ args: [String], cwd: URL?, stdin: String? = nil, timeout: TimeInterval = 60) async -> (code: Int32, out: String) {
        guard let py = python(), let vanta = vantaPy else { return (-1, "python3 or the Vanta runtime is missing") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: py)
                p.arguments = [vanta.path] + args
                if let cwd { p.currentDirectoryURL = cwd }
                var env = ProcessInfo.processInfo.environment
                env["PYTHONUNBUFFERED"] = "1"
                env["NO_COLOR"] = "1"
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                let inp = Pipe()
                p.standardInput = inp
                var data = Data()
                let lock = NSLock()
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    lock.lock(); data.append(d); lock.unlock()
                }
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "couldn't start python3: \(error.localizedDescription)")); return
                }
                if let stdin { inp.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data()) }
                try? inp.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); data.append(rest); let all = data; lock.unlock()
                cont.resume(returning: (p.terminationStatus, String(decoding: all, as: UTF8.self)))
            }
        }
    }
}

struct LSPError: Error, CustomStringConvertible {
    let code: Int
    let message: String
    var description: String { message }
}

/// JSON-RPC 2.0 over stdio to `python3 vanta.py lsp`. All callbacks arrive on the main thread.
final class LSPClient {
    typealias JSON = [String: Any]

    private(set) var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<Any?, LSPError>) -> Void] = [:]
    private let ioQueue = DispatchQueue(label: "vanta.lsp.io")
    private let rootURL: URL?
    private var crashTimes: [Date] = []
    private var stopping = false
    private(set) var failed = false

    private(set) var isReady = false
    private(set) var capabilities: JSON = [:]
    /// Called for every server notification (method, params).
    var onNotification: ((String, JSON) -> Void)?
    /// Called after (re)initialising — the owner re-sends open documents.
    var onReady: (() -> Void)?
    /// Called when the server is gone for good (too many crashes / no python).
    var onFailure: ((String) -> Void)?
    private var readyWaiters: [() -> Void] = []

    init(root: URL?) { self.rootURL = root }

    // MARK: lifecycle

    func start() {
        stopping = false
        failed = false
        guard let py = VantaRuntime.python(), let vanta = VantaRuntime.vantaPy else {
            giveUp("python3 or the bundled Vanta runtime wasn't found")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [vanta.path, "lsp"]
        p.currentDirectoryURL = rootURL ?? VantaRuntime.directory
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.ioQueue.async { self?.received(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { NSLog("vanta lsp: %@", s) }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.terminated(proc) }
        }
        do { try p.run() } catch {
            giveUp("couldn't start the language server: \(error.localizedDescription)")
            return
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        ioQueue.sync { buffer = Data() }
        isReady = false
        let params: JSON = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURL.map { $0.absoluteString } as Any,
            "capabilities": ["textDocument": ["completion": ["completionItem": ["snippetSupport": true]],
                                              "hover": ["contentFormat": ["markdown"]]]],
            "clientInfo": ["name": "Vanta Studio", "version": "2.0"],
        ]
        sendRequest("initialize", params, timeout: 20) { [weak self] result in
            guard let self else { return }
            if case .success(let r) = result, let caps = (r as? JSON)?["capabilities"] as? JSON { self.capabilities = caps }
            self.notify("initialized", [:])
            self.isReady = true
            self.onReady?()
            let w = self.readyWaiters; self.readyWaiters = []
            w.forEach { $0() }
        }
    }

    func stop() {
        stopping = true
        guard let p = process else { return }
        if p.isRunning {
            sendRequest("shutdown", nil, timeout: 1) { [weak self] _ in
                self?.notify("exit", nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if p.isRunning { p.terminate() } }
            }
        }
        process = nil
        isReady = false
        failAll("the language server stopped")
    }

    func restart() {
        stop()
        crashTimes = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
    }

    private func terminated(_ p: Process) {
        guard p === process else { return }
        process = nil
        isReady = false
        failAll("the language server exited")
        guard !stopping else { return }
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashTimes.count > 4 {
            giveUp("the language server keeps crashing (exit \(p.terminationStatus))")
            return
        }
        let delay = 0.5 * Double(crashTimes.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.process == nil, !self.stopping else { return }
            self.start()
        }
    }

    private func failAll(_ why: String) {
        let p = pending
        pending = [:]
        for (_, cb) in p { cb(.failure(LSPError(code: -1, message: why))) }
    }

    /// Run `body` once the server has answered `initialize`.
    func whenReady(_ body: @escaping () -> Void) {
        if isReady || failed { body() } else { readyWaiters.append(body) }
    }

    private func giveUp(_ why: String) {
        failed = true
        onFailure?(why)
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0() }
    }

    // MARK: sending

    func notify(_ method: String, _ params: Any?) {
        var msg: JSON = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        write(msg)
    }

    func sendRequest(_ method: String, _ params: Any?, timeout: TimeInterval = 8,
                     completion: @escaping (Result<Any?, LSPError>) -> Void) {
        guard process?.isRunning == true else {
            completion(.failure(LSPError(code: -1, message: "the language server isn't running"))); return
        }
        let id = nextID
        nextID += 1
        pending[id] = completion
        var msg: JSON = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        write(msg)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let cb = self.pending.removeValue(forKey: id) else { return }
            self.notify("$/cancelRequest", ["id": id])
            cb(.failure(LSPError(code: -2, message: "\(method) timed out")))
        }
    }

    /// async/await form. Waits (up to `timeout`) for the server to be ready first.
    func request(_ method: String, _ params: Any?, timeout: TimeInterval = 8) async -> Result<Any?, LSPError> {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                var done = false
                func finish(_ r: Result<Any?, LSPError>) {
                    guard !done else { return }
                    done = true
                    cont.resume(returning: r)
                }
                self.whenReady { self.sendRequest(method, params, timeout: timeout) { finish($0) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 1) {
                    finish(.failure(LSPError(code: -2, message: "the language server didn't answer")))
                }
            }
        }
    }

    private func write(_ msg: JSON) {
        guard let h = stdinHandle, process?.isRunning == true,
              let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var data = "Content-Length: \(body.count)\r\n\r\n".data(using: .ascii)!
        data.append(body)
        ioQueue.async {
            do { try h.write(contentsOf: data) } catch { NSLog("vanta lsp write failed: %@", "\(error)") }
        }
    }

    // MARK: receiving (io queue)

    private func received(_ d: Data) {
        buffer.append(d)
        while true {
            guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<sep.lowerBound], as: UTF8.self)
            var length = 0
            for line in head.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let start = sep.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(start, offsetBy: length)
            let body = buffer.subdata(in: start..<end)
            buffer.removeSubrange(buffer.startIndex..<end)
            buffer = Data(buffer)
            if let obj = try? JSONSerialization.jsonObject(with: body) as? JSON {
                DispatchQueue.main.async { [weak self] in self?.dispatch(obj) }
            }
        }
    }

    private func dispatch(_ msg: JSON) {
        if let id = msg["id"] as? Int, msg["method"] == nil {
            guard let cb = pending.removeValue(forKey: id) else { return }
            if let err = msg["error"] as? JSON {
                cb(.failure(LSPError(code: err["code"] as? Int ?? -1, message: err["message"] as? String ?? "error")))
            } else {
                let r = msg["result"]
                cb(.success(r is NSNull ? nil : r))
            }
        } else if let method = msg["method"] as? String {
            if let id = msg["id"] {                     // a request from the server: we support none
                write(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            }
            onNotification?(method, msg["params"] as? JSON ?? [:])
        }
    }
}
