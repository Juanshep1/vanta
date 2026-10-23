import Foundation
import Darwin

/// Spawns a child process in its own process group (so Stop also ends anything
/// it started — a native build's compiler or the built program), streams its
/// merged stdout/stderr, feeds stdin, and reports the exit code.
final class ProcessRunner {
    private(set) var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var generation = 0
    private let queue = DispatchQueue(label: "vanta.run.process")

    var isRunning: Bool { pid > 0 }

    /// - Parameters:
    ///   - onOutput: called on the main thread with each chunk (valid UTF-8, split safely).
    ///   - onFinish: called on the main thread with the exit code (128+signal when killed).
    func start(executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String] = [:],
               onOutput: @escaping (String) -> Void, onFinish: @escaping (Int32) -> Void) {
        stop()
        generation += 1
        let gen = generation

        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            onOutput("⚠️  Couldn't create pipes.\n"); onFinish(-1); return
        }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 2)
        for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1]] { posix_spawn_file_actions_addclose(&fa, fd) }
        if let cwd = workingDirectory?.path { posix_spawn_file_actions_addchdir_np(&fa, cwd) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var allSignals = sigset_t(), noSignals = sigset_t()
        sigfillset(&allSignals); sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        if env["TERM"] == nil || env["TERM"] == "dumb" { env["TERM"] = "xterm-256color" }
        env["COLORTERM"] = "truecolor"
        for (k, v) in environment { env[k] = v }
        let argv = [executable] + arguments
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }; cEnv.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &fa, &attr, &cArgs, &cEnv)
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0])
            onOutput("⚠️  Couldn't launch \(executable): \(String(cString: strerror(rc)))\n")
            onFinish(-1)
            return
        }
        pid = child
        stdinFD = inPipe[1]
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        let outFD = outPipe[0]

        // Output: read on a background queue, decode UTF-8 without splitting characters.
        var pending = Data()
        let src = DispatchSource.makeReadSource(fileDescriptor: outFD, queue: queue)
        let outputDone = DispatchSemaphore(value: 0)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(outFD, &buf, buf.count)
            if n <= 0 { src.cancel(); return }
            pending.append(contentsOf: buf[0..<n])
            let text = Self.takeValidUTF8(&pending)
            if !text.isEmpty { DispatchQueue.main.async { onOutput(text) } }
        }
        src.setCancelHandler {
            if !pending.isEmpty {
                let rest = String(decoding: pending, as: UTF8.self)
                DispatchQueue.main.async { onOutput(rest) }
            }
            close(outFD)
            outputDone.signal()
        }
        readSource = src
        src.resume()

        // Exit: wait on a separate thread, then let the output drain before reporting.
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            _ = outputDone.wait(timeout: .now() + 2)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }   // stopped or replaced
                self.cleanup()
                onFinish(code)
            }
        }
    }

    /// Split off the longest valid UTF-8 prefix (keeps a partial trailing character for later).
    static func takeValidUTF8(_ data: inout Data) -> String {
        var cut = data.count
        // back up over at most 3 continuation bytes of an unfinished sequence
        var i = data.count - 1, back = 0
        while i >= 0 && back < 4 {
            let b = data[data.startIndex + i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
            let need = b & 0x80 == 0 ? 1 : b & 0xE0 == 0xC0 ? 2 : b & 0xF0 == 0xE0 ? 3 : b & 0xF8 == 0xF0 ? 4 : 1
            if data.count - i < need { cut = i }
            break
        }
        let head = data.prefix(cut)
        data = Data(data.suffix(from: data.startIndex + cut))
        return String(decoding: head, as: UTF8.self)
    }

    func write(_ text: String) {
        guard stdinFD >= 0 else { return }
        let fd = stdinFD
        let bytes = Array(text.utf8)
        queue.async { _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) } }
    }

    /// Close the program's stdin (EOF for `ask`).
    func closeInput() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    func signal(_ sig: Int32) {
        guard pid > 0 else { return }
        kill(-pid, sig)
    }

    /// SIGTERM the whole process group, SIGKILL it if it hasn't gone a moment later.
    func stop() {
        guard pid > 0 else { return }
        let p = pid
        kill(-p, SIGTERM)
        kill(p, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            if kill(p, 0) == 0 { kill(-p, SIGKILL); kill(p, SIGKILL) }
        }
        generation += 1          // the old run's finish callback is dropped
        cleanup()
    }

    private func cleanup() {
        pid = 0
        closeInput()
        readSource = nil
    }
}

/// Finds python3 (kept under this name for Studio 1 compatibility).
enum PythonRunner {
    static func findPython() -> String? {
        let custom = StudioSettings.shared.prefs.pythonPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty && FileManager.default.isExecutableFile(atPath: custom) { return custom }
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
}
