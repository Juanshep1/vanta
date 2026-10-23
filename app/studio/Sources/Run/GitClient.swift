import Foundation

/// Runs a command to completion off the main thread and collects its output.
enum ShellCommand {
    struct Output {
        let code: Int32
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var ok: Bool { code == 0 }
        /// stdout + stderr, trimmed — for showing to the user.
        var combined: String {
            (text + (stderr.isEmpty ? "" : (text.isEmpty ? "" : "\n") + stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Synchronous: call from a background queue.
    static func run(_ executable: String, _ args: [String], cwd: URL?, env: [String: String] = [:], input: Data? = nil) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch {
            return Output(code: -1, stdout: Data(), stderr: "couldn't run \(executable): \(error.localizedDescription)")
        }
        if let input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return Output(code: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// One changed path from `git status`.
struct GitChange: Identifiable, Hashable {
    enum Area: String { case staged, unstaged, untracked, conflicted }
    var id: String { area.rawValue + ":" + path }
    let path: String            // relative to the repo root
    let origPath: String?       // renames
    let area: Area
    /// One letter: M A D R C U ?
    let code: Character

    var label: String {
        switch code {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "U": return "Conflict"
        case "?": return "Untracked"
        default: return String(code)
        }
    }
    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct GitStatus: Equatable {
    var branch: String?          // nil = detached
    var head: String?            // commit oid
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [GitChange] = []
}

struct GitCommit: Identifiable, Hashable {
    var id: String { hash }
    let hash: String
    let author: String
    let date: Date
    let subject: String
    let refs: String
}

/// Thin, synchronous wrapper over the git CLI (call from a background queue).
struct GitClient {
    let root: URL

    static var gitPath: String? {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// The repo containing `dir`, if any.
    static func repoRoot(for dir: URL) -> URL? {
        guard let git = gitPath else { return nil }
        let r = ShellCommand.run(git, ["rev-parse", "--show-toplevel"], cwd: dir)
        guard r.ok else { return nil }
        let p = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : URL(fileURLWithPath: p).standardizedFileURL
    }

    @discardableResult
    func git(_ args: [String], input: Data? = nil) -> ShellCommand.Output {
        guard let g = Self.gitPath else { return ShellCommand.Output(code: -1, stdout: Data(), stderr: "git isn't installed") }
        // never block on a credential prompt; keep output stable
        return ShellCommand.run(g, ["-c", "core.quotepath=off", "-c", "color.ui=never"] + args, cwd: root,
                                env: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"], input: input)
    }

    func status() -> GitStatus {
        let r = git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        return Self.parseStatus(r.stdout)
    }

    static func parseStatus(_ data: Data) -> GitStatus {
        var st = GitStatus()
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            if f.isEmpty { continue }
            if f.hasPrefix("# ") {
                let parts = f.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": st.head = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": st.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": st.upstream = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2 { st.ahead = Int(ab[0].dropFirst()) ?? 0; st.behind = Int(ab[1].dropFirst()) ?? 0 }
                default: break
                }
                continue
            }
            let kind = f.first!
            switch kind {
            case "1", "2":
                // 1 XY sub mH mI mW hH hI path   |   2 XY sub mH mI mW hH hI Xscore path \0 orig
                let n = kind == "1" ? 8 : 9
                let parts = f.split(separator: " ", maxSplits: n, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == n + 1 else { continue }
                let xy = Array(parts[1])
                let path = parts[n]
                var orig: String?
                if kind == "2", i < fields.count { orig = fields[i]; i += 1 }
                if xy[0] != "." { st.changes.append(GitChange(path: path, origPath: orig, area: .staged, code: xy[0])) }
                if xy[1] != "." { st.changes.append(GitChange(path: path, origPath: orig, area: .unstaged, code: xy[1])) }
            case "u":
                let parts = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 11 { st.changes.append(GitChange(path: parts[10], origPath: nil, area: .conflicted, code: "U")) }
            case "?":
                st.changes.append(GitChange(path: String(f.dropFirst(2)), origPath: nil, area: .untracked, code: "?"))
            default: break
            }
        }
        return st
    }

    func branches() -> [String] {
        git(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"]).text
            .split(separator: "\n").map(String.init)
    }

    func remoteBranches() -> [String] {
        git(["for-each-ref", "--format=%(refname:short)", "refs/remotes"]).text
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    func log(limit: Int = 100) -> [GitCommit] {
        let r = git(["log", "-n", "\(limit)", "--date=unix", "--pretty=format:%H%x1f%an%x1f%ad%x1f%D%x1f%s%x1e"])
        guard r.ok else { return [] }
        return r.text.split(separator: "\u{1e}").compactMap { rec in
            let p = rec.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard p.count == 5 else { return nil }
            return GitCommit(hash: p[0], author: p[1], date: Date(timeIntervalSince1970: Double(p[2]) ?? 0), subject: p[4], refs: p[3])
        }
    }

    /// The file's contents at HEAD (nil when it's new).
    func headContents(_ path: String) -> String? {
        let r = git(["show", "HEAD:\(path)"])
        return r.ok ? String(decoding: r.stdout, as: UTF8.self) : nil
    }

    /// The staged (index) contents of a file.
    func indexContents(_ path: String) -> String? {
        let r = git(["show", ":\(path)"])
        return r.ok ? String(decoding: r.stdout, as: UTF8.self) : nil
    }

    func stage(_ paths: [String]) -> ShellCommand.Output { git(["add", "-A", "--"] + paths) }
    func unstage(_ paths: [String], hasHead: Bool) -> ShellCommand.Output {
        hasHead ? git(["reset", "-q", "HEAD", "--"] + paths) : git(["rm", "--cached", "-q", "-r", "--"] + paths)
    }
    func discard(_ paths: [String]) -> ShellCommand.Output { git(["checkout", "--"] + paths) }
    func commit(message: String, amend: Bool = false) -> ShellCommand.Output {
        git(["commit", "-F", "-"] + (amend ? ["--amend"] : []), input: message.data(using: .utf8))
    }
    func checkout(_ branch: String) -> ShellCommand.Output { git(["checkout", branch]) }
    func createBranch(_ name: String) -> ShellCommand.Output { git(["checkout", "-b", name]) }
    func push(setUpstream branch: String?) -> ShellCommand.Output {
        if let branch { return git(["push", "-u", "origin", branch]) }
        return git(["push"])
    }
    func pull() -> ShellCommand.Output { git(["pull", "--ff-only"]) }
    func fetch() -> ShellCommand.Output { git(["fetch", "--quiet"]) }
}
