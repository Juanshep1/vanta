import Foundation

// Runs a Vanta program natively by spawning python3 on the bundled vanta.py.
// Streams stdout/stderr back, and supports feeding stdin (for `ask`).
final class PythonRunner {
    private var process: Process?
    private var stdinPipe: Pipe?

    static func findPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func run(vantaPy: URL, sourceFile: URL,
             onOutput: @escaping (String) -> Void,
             onFinish: @escaping (Int32) -> Void) {
        stop()
        guard let py = Self.findPython() else {
            onOutput("⚠️  Couldn't find python3 on this Mac.\n")
            onFinish(-1)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = [vantaPy.path, sourceFile.path]
        proc.currentDirectoryURL = vantaPy.deletingLastPathComponent()

        let outPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.standardInput = inPipe
        stdinPipe = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { onOutput(s) }
        }
        proc.terminationHandler = { p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { onFinish(p.terminationStatus) }
        }
        process = proc
        do {
            try proc.run()
        } catch {
            onOutput("⚠️  Failed to launch python3: \(error.localizedDescription)\n")
            onFinish(-1)
        }
    }

    func sendInput(_ line: String) {
        guard let pipe = stdinPipe else { return }
        if let data = (line + "\n").data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    func stop() {
        if let p = process {
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
        stdinPipe = nil
    }
}
