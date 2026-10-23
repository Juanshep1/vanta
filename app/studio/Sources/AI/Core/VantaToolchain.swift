import Foundation

/// Runs the Vanta 6.0 command line (`run`, `test`, `check`, `fmt`) headlessly
/// for the agent and Fix with Vee: captures output, feeds `ask` input on stdin,
/// enforces a timeout, and never touches the user's own Run session.
enum VantaToolchain {
    struct Result {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
        var failed: Bool { exitCode != 0 && !timedOut }
    }

    /// The vanta.py to use: $VANTA_PY, then the bundled runtime if it is 6.x,
    /// then the Vanta source checkout on this Mac, then the bundled runtime anyway.
    static let vantaPy: URL? = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["VANTA_PY"], fm.fileExists(atPath: env) { return URL(fileURLWithPath: env) }
        let bundled = Bundle.main.url(forResource: "vanta", withExtension: "py", subdirectory: "runtime")
        if let b = bundled, version(of: b) >= 6 { return b }
        let dev = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta/vanta.py")
        if fm.fileExists(atPath: dev.path) { return dev }
        return bundled
    }()

    static func version(of url: URL) -> Double {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 8000),
              let s = String(data: d, encoding: .utf8),
              let r = s.range(of: #"VERSION = "([0-9.]+)""#, options: .regularExpression) else { return 0 }
        let v = s[r].split(separator: "\"").dropFirst().first.map(String.init) ?? "0"
        return Double(v.split(separator: ".").prefix(2).joined(separator: ".")) ?? 0
    }

    /// python3 (Settings › Run override first). Kept here so the AI module doesn't depend on Run internals.
    static func findPython() -> String? {
        let custom = StudioSettings.shared.prefs.pythonPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty && FileManager.default.isExecutableFile(atPath: custom) { return custom }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                  "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static var isAvailable: Bool { vantaPy != nil && findPython() != nil }

    /// Run `vanta <args>` in `cwd`. `input` lines are written to stdin up front (answers for `ask`).
    static func run(_ args: [String], cwd: URL?, input: [String] = [], timeout: Double = 20,
                    onOutput: ((String) -> Void)? = nil) async -> Result {
        guard let vpy = vantaPy else { return Result(output: "Vanta runtime (vanta.py) not found.", exitCode: 127, timedOut: false) }
        guard let py = findPython() else { return Result(output: "python3 not found on this Mac.", exitCode: 127, timedOut: false) }
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = [vpy.path] + args
            proc.currentDirectoryURL = cwd ?? vpy.deletingLastPathComponent()
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["NO_COLOR"] = "1"
            env["VANTA_NO_COLOR"] = "1"
            proc.environment = env
            let out = Pipe(), inp = Pipe()
            proc.standardOutput = out
            proc.standardError = out
            proc.standardInput = inp
            let lock = NSLock()
            var buffer = Data()
            var finished = false
            var timedOut = false
            func finish(_ code: Int32) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let rest = out.fileHandleForReading.readDataToEndOfFileSafely()
                buffer.append(rest)
                var text = String(decoding: buffer, as: UTF8.self)
                lock.unlock()
                if text.count > 24000 { text = String(text.prefix(12000)) + "\n…(output truncated)…\n" + String(text.suffix(8000)) }
                if timedOut { text += "\n[stopped after \(Int(timeout))s — still running (a server, a game loop, or waiting for more input)]" }
                cont.resume(returning: Result(output: text, exitCode: code, timedOut: timedOut))
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                lock.lock(); buffer.append(d); let fin = finished; lock.unlock()
                if !fin, let s = String(data: d, encoding: .utf8) { onOutput?(s) }
            }
            proc.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                finish(p.terminationStatus)
            }
            do { try proc.run() } catch {
                cont.resume(returning: Result(output: "Couldn't start python3: \(error.localizedDescription)", exitCode: 127, timedOut: false))
                return
            }
            if !input.isEmpty {
                let data = Data((input.joined(separator: "\n") + "\n").utf8)
                try? inp.fileHandleForWriting.write(contentsOf: data)
            }
            try? inp.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lock.lock(); let fin = finished; lock.unlock()
                if !fin && proc.isRunning { timedOut = true; proc.terminate() }
            }
        }
    }

    // MARK: diagnostics parsing

    /// `vanta check` prints "file.va:5: message"; runtime errors print "--> file.va:5".
    static func diagnostics(from output: String, defaultFile: URL?) -> [(file: String, line: Int, message: String)] {
        var out: [(String, Int, String)] = []
        let lines = output.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            if let r = l.range(of: #"^([^\s:]+\.va):(\d+):\s*(.*)$"#, options: .regularExpression) {
                let parts = String(l[r]).split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3, let n = Int(parts[1]) { out.append((parts[0], n, parts[2].trimmingCharacters(in: .whitespaces))) }
            } else if l.hasPrefix("Oops!") {
                var file = defaultFile?.lastPathComponent ?? ""
                var line = 0
                if let m = l.range(of: #"line (\d+)"#, options: .regularExpression) {
                    line = Int(l[m].dropFirst(5)) ?? 0
                }
                if i + 1 < lines.count, let a = lines[i + 1].range(of: #"--> (.+):(\d+)"#, options: .regularExpression) {
                    let s = String(lines[i + 1][a].dropFirst(4))
                    let p = s.split(separator: ":")
                    if p.count >= 2 { file = String(p[0]); line = Int(p[1]) ?? line }
                }
                out.append((file, line, String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }
}

private extension FileHandle {
    func readDataToEndOfFileSafely() -> Data {
        (try? readToEnd()) ?? Data()
    }
}
