import Foundation

/// The agent's tools: definitions (JSON Schema, shared by both provider
/// formats) and their implementations against the workspace.
enum AgentTools {
    private static func obj(_ props: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

    static let definitions: [LLMTool] = [
        LLMTool(name: "list_files", description: "List files and folders in the workspace (paths relative to the workspace root). Folders end with '/'.",
                schema: obj(["path": str("Folder to list, relative to the workspace root. Default: the root."),
                             "recursive": bool("List sub-folders too (default true).")], required: [])),
        LLMTool(name: "read_file", description: "Read a text file. Lines are prefixed with their 1-based line number and a tab — the prefix is NOT part of the file (never include it in edit_file).",
                schema: obj(["path": str("File path relative to the workspace root."),
                             "start_line": int("First line to read (1-based, optional)."),
                             "end_line": int("Last line to read (inclusive, optional).")], required: ["path"])),
        LLMTool(name: "search", description: "Search file contents across the workspace (like grep). Returns path:line: text for each match.",
                schema: obj(["pattern": str("Text or regular expression to find."),
                             "regex": bool("Treat pattern as a regular expression (default false)."),
                             "path": str("Limit to this file or folder (optional)."),
                             "case_sensitive": bool("Default false.")], required: ["pattern"])),
        LLMTool(name: "codebase_search", description: "Semantic-ish (BM25) search over the workspace's code: finds the functions, types and passages most relevant to a natural-language query.",
                schema: obj(["query": str("What you are looking for, in words (e.g. 'where the score is saved').")], required: ["query"])),
        LLMTool(name: "book_search", description: "Search The Vanta Book and the Vanta docs for syntax, builtins and examples. Use it whenever you are unsure how something is written in Vanta 6.0.",
                schema: obj(["query": str("Topic or question, e.g. 'default parameter values' or 'read a json file'.")], required: ["query"])),
        LLMTool(name: "write_file", description: "Create a file or replace its whole content. Prefer edit_file for small changes to existing files.",
                schema: obj(["path": str("File path relative to the workspace root (folders are created)."),
                             "content": str("The complete new file content.")], required: ["path", "content"])),
        LLMTool(name: "edit_file", description: "Replace an exact snippet in a file. old_string must match the file exactly (including indentation) and be unique unless replace_all is true. Include a few surrounding lines to make it unique.",
                schema: obj(["path": str("File path relative to the workspace root."),
                             "old_string": str("Exact text to replace (no line-number prefixes)."),
                             "new_string": str("Replacement text."),
                             "replace_all": bool("Replace every occurrence (default false).")], required: ["path", "old_string", "new_string"])),
        LLMTool(name: "create_file", description: "Create a new file. Fails if it already exists.",
                schema: obj(["path": str("New file path relative to the workspace root."),
                             "content": str("File content.")], required: ["path", "content"])),
        LLMTool(name: "delete_file", description: "Delete a file.",
                schema: obj(["path": str("File path relative to the workspace root.")], required: ["path"])),
        LLMTool(name: "rename_file", description: "Rename or move a file.",
                schema: obj(["from": str("Current path."), "to": str("New path.")], required: ["from", "to"])),
        LLMTool(name: "run_program", description: "Run a Vanta program (vanta run) and return its output and exit code. Programs that use `ask` read their answers from `input`, one string per ask. Long-running programs are stopped after the timeout.",
                schema: obj(["path": str("The .va file to run, relative to the workspace root."),
                             "input": ["type": "array", "items": ["type": "string"], "description": "Answers to feed to `ask`, in order."],
                             "args": ["type": "array", "items": ["type": "string"], "description": "Command-line arguments (read with arguments())."],
                             "timeout": int("Seconds before stopping (default 15, max 60).")], required: ["path"])),
        LLMTool(name: "run_tests", description: "Run Vanta test blocks (vanta test). With no path it runs tests/ or the whole workspace. Exit code 1 means a test failed.",
                schema: obj(["path": str("A test file or folder (optional)."),
                             "filter": str("Only tests whose name contains this text (optional).")], required: [])),
        LLMTool(name: "check", description: "Check a Vanta file for syntax, name and type problems without running it (vanta check).",
                schema: obj(["path": str("The .va file (or several, space-separated).")], required: ["path"])),
        LLMTool(name: "format", description: "Format a Vanta file the standard way (vanta fmt) in place.",
                schema: obj(["path": str("The .va file to format.")], required: ["path"])),
        LLMTool(name: "read_problems", description: "Read the errors and warnings currently shown in the IDE's Problems panel.",
                schema: obj([:], required: [])),
        LLMTool(name: "ask_user", description: "Pause and ask the user a question when a decision is genuinely needed. Returns their answer.",
                schema: obj(["question": str("A short, specific question.")], required: ["question"])),
    ]

    static let writeTools: Set<String> = ["write_file", "edit_file", "create_file", "delete_file", "rename_file", "format"]

    /// One-line description of a call for the tool card header.
    static func summary(_ name: String, _ args: [String: Any]) -> String {
        func s(_ k: String) -> String { (args[k] as? String) ?? "" }
        switch name {
        case "list_files": return s("path").isEmpty ? "workspace" : s("path")
        case "read_file":
            if let a = args["start_line"] as? Int { return "\(s("path")):\(a)–\((args["end_line"] as? Int).map(String.init) ?? "")" }
            return s("path")
        case "search": return "“\(s("pattern"))”" + (s("path").isEmpty ? "" : " in \(s("path"))")
        case "codebase_search", "book_search": return "“\(s("query"))”"
        case "rename_file": return "\(s("from")) → \(s("to"))"
        case "run_tests": return s("path").isEmpty ? "all tests" : s("path")
        case "ask_user": return s("question")
        case "read_problems": return ""
        default: return s("path")
        }
    }

    static func title(_ name: String) -> String {
        switch name {
        case "list_files": return "List files"
        case "read_file": return "Read"
        case "search": return "Search"
        case "codebase_search": return "Search codebase"
        case "book_search": return "Search the book"
        case "write_file": return "Write"
        case "edit_file": return "Edit"
        case "create_file": return "Create"
        case "delete_file": return "Delete"
        case "rename_file": return "Rename"
        case "run_program": return "Run"
        case "run_tests": return "Run tests"
        case "check": return "Check"
        case "format": return "Format"
        case "read_problems": return "Read problems"
        case "ask_user": return "Question"
        default: return name
        }
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "list_files": return "folder"
        case "read_file": return "doc.text.magnifyingglass"
        case "search", "codebase_search": return "magnifyingglass"
        case "book_search": return "book"
        case "write_file", "create_file": return "doc.badge.plus"
        case "edit_file": return "pencil"
        case "delete_file": return "trash"
        case "rename_file": return "arrow.right.doc.on.clipboard"
        case "run_program": return "play.fill"
        case "run_tests": return "checkmark.seal"
        case "check": return "stethoscope"
        case "format": return "text.alignleft"
        case "read_problems": return "exclamationmark.triangle"
        case "ask_user": return "questionmark.bubble"
        default: return "wrench"
        }
    }

    // MARK: execution

    struct Output { var text: String; var isError: Bool }

    static func execute(_ call: LLMToolCall, tracker: ChangeTracker,
                        askUser: @escaping (String) async -> String) async -> Output {
        let a = call.args
        if a["__invalid_json"] != nil {
            return Output(text: "INVALID_JSON: the tool arguments were cut off or not valid JSON. Call the tool again with complete arguments.", isError: true)
        }
        func s(_ k: String) -> String? { a[k] as? String }
        func need(_ k: String) throws -> String {
            guard let v = s(k), !v.isEmpty else { throw AIError.message("Missing required argument '\(k)'.") }
            return v
        }
        do {
            switch call.name {
            case "list_files":
                return await MainActor.run { listFiles(s("path") ?? "", recursive: (a["recursive"] as? Bool) ?? true) }
            case "read_file":
                let path = try need("path")
                return try await MainActor.run { try readFile(path, start: a["start_line"] as? Int, end: a["end_line"] as? Int) }
            case "search":
                let pat = try need("pattern")
                return try await MainActor.run { try search(pat, regex: (a["regex"] as? Bool) ?? false, path: s("path"),
                                                            caseSensitive: (a["case_sensitive"] as? Bool) ?? false) }
            case "codebase_search":
                let q = try need("query")
                return await MainActor.run {
                    let hits = CodebaseIndex.shared.search(q, k: 6)
                    if hits.isEmpty { return Output(text: "No matches (the workspace may be empty).", isError: false) }
                    return Output(text: hits.map { "── \($0.docTitle):\($0.line + 1) (\($0.heading))\n\(ContextBuilder.clip($0.text, 2500))" }
                        .joined(separator: "\n\n"), isError: false)
                }
            case "book_search":
                let q = try need("query")
                let hits = KnowledgeBase.shared.search(q, k: 4)
                return Output(text: hits.isEmpty ? "Nothing found in the book for that." : KnowledgeBase.render(hits, maxChars: 10000), isError: false)
            case "write_file", "create_file":
                let path = try need("path")
                let content = s("content") ?? ""
                return try await MainActor.run {
                    let url = try WorkspaceFS.resolve(path)
                    if call.name == "create_file" && WorkspaceFS.exists(url) { throw AIError.message("\(path) already exists — use edit_file or write_file.") }
                    if WorkspaceFS.isDirectory(url) { throw AIError.message("\(path) is a folder.") }
                    let existed = WorkspaceFS.exists(url)
                    tracker.willModify(url)
                    try WorkspaceFS.write(url, content)
                    tracker.didModify(url)
                    CodebaseIndex.shared.reindex(url: url, text: content)
                    return Output(text: "\(existed ? "Updated" : "Created") \(WorkspaceFS.relative(url)) (\(content.components(separatedBy: "\n").count) lines).", isError: false)
                }
            case "edit_file":
                let path = try need("path")
                guard let old = s("old_string"), let new = s("new_string") else { throw AIError.message("Missing old_string/new_string.") }
                return try await MainActor.run { try editFile(path, old: old, new: new, all: (a["replace_all"] as? Bool) ?? false, tracker: tracker) }
            case "delete_file":
                let path = try need("path")
                return try await MainActor.run {
                    let url = try WorkspaceFS.resolve(path)
                    guard FileManager.default.fileExists(atPath: url.path), !WorkspaceFS.isDirectory(url) else { throw AIError.message("No file at \(path).") }
                    tracker.willModify(url)
                    try WorkspaceFS.delete(url)
                    tracker.didModify(url)
                    return Output(text: "Deleted \(path).", isError: false)
                }
            case "rename_file":
                let from = try need("from"), to = try need("to")
                return try await MainActor.run {
                    let f = try WorkspaceFS.resolve(from), t = try WorkspaceFS.resolve(to)
                    guard FileManager.default.fileExists(atPath: f.path) else { throw AIError.message("No file at \(from).") }
                    guard !FileManager.default.fileExists(atPath: t.path) else { throw AIError.message("\(to) already exists.") }
                    tracker.willModify(f); tracker.willModify(t)
                    try WorkspaceFS.rename(f, t)
                    tracker.didModify(t)
                    return Output(text: "Renamed \(from) → \(to).", isError: false)
                }
            case "run_program":
                let path = try need("path")
                let url = try await MainActor.run { () throws -> URL in
                    let u = try WorkspaceFS.resolve(path)
                    guard FileManager.default.fileExists(atPath: u.path) else { throw AIError.message("No file at \(path).") }
                    saveIfDirty(u)
                    return u
                }
                let input = (a["input"] as? [Any])?.map { "\($0)" } ?? []
                let args = (a["args"] as? [Any])?.map { "\($0)" } ?? []
                let timeout = min(60, max(2, Double((a["timeout"] as? Int) ?? 15)))
                let r = await VantaToolchain.run(["run", url.path] + args, cwd: url.deletingLastPathComponent(), input: input, timeout: timeout)
                let status = r.timedOut ? "timed out (treated as still running)" : "exit code \(r.exitCode)"
                return Output(text: "[\(status)]\n" + (r.output.isEmpty ? "(no output)" : r.output), isError: r.failed)
            case "run_tests":
                let root = await MainActor.run { WorkspaceFS.root }
                var args = ["test"]
                if let p = s("path"), !p.isEmpty {
                    let u = try await MainActor.run { () throws -> URL in let u = try WorkspaceFS.resolve(p); saveIfDirty(u); return u }
                    args.append(u.path)
                } else {
                    await MainActor.run { Services.shared.documents.dirtyDocuments.filter { $0.url != nil }.forEach { _ = $0.save() } }
                    if let root, !FileManager.default.fileExists(atPath: root.appendingPathComponent("tests").path) { args.append(root.path) }
                }
                if let f = s("filter"), !f.isEmpty { args += ["--filter", f] }
                args.append("--no-color")
                let r = await VantaToolchain.run(args, cwd: root, timeout: 60)
                var out = r.output
                if out.contains("0 passed, 0 failed") || out.lowercased().contains("no test") { out += "\n(no test blocks found — write some with test \"name\" … expect … end)" }
                return Output(text: "[exit code \(r.exitCode)]\n" + out, isError: r.failed)
            case "check":
                let path = try need("path")
                let urls = try await MainActor.run { () throws -> [URL] in
                    try path.split(separator: " ").map { let u = try WorkspaceFS.resolve(String($0)); saveIfDirty(u); return u }
                }
                let root = await MainActor.run { WorkspaceFS.root }
                let r = await VantaToolchain.run(["check"] + urls.map(\.path), cwd: root, timeout: 30)
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return Output(text: r.exitCode == 0 ? (out.isEmpty ? "No problems found." : out) : out, isError: r.failed)
            case "format":
                let path = try need("path")
                let url = try await MainActor.run { () throws -> URL in
                    let u = try WorkspaceFS.resolve(path); saveIfDirty(u); tracker.willModify(u); return u
                }
                let before = await MainActor.run { WorkspaceFS.read(url) ?? "" }
                let r = await VantaToolchain.run(["fmt", url.path], cwd: url.deletingLastPathComponent(), timeout: 30)
                return await MainActor.run {
                    if let d = Services.shared.documents.document(for: url) { d.reloadFromDisk() }
                    tracker.didModify(url)
                    let after = WorkspaceFS.read(url) ?? ""
                    let st = LineDiff.stats(before, after)
                    return Output(text: (r.exitCode == 0 ? (before == after ? "Already formatted." : "Formatted (+\(st.added) −\(st.removed) lines).") : r.output), isError: r.failed)
                }
            case "read_problems":
                return await MainActor.run {
                    let all = DiagnosticsStore.shared.all.filter { !$0.1.isEmpty }
                    if all.isEmpty { return Output(text: "No problems.", isError: false) }
                    var lines: [String] = []
                    for (uri, ds) in all { for d in ds.prefix(40) {
                        lines.append("\(WorkspaceFS.relative(uri)):\(d.range.start.line + 1):\(d.range.start.column + 1): \(d.severity == .error ? "error" : d.severity == .warning ? "warning" : "info"): \(d.message) [\(d.source)]")
                    } }
                    return Output(text: lines.joined(separator: "\n"), isError: false)
                }
            case "ask_user":
                let q = try need("question")
                let answer = await askUser(q)
                return Output(text: answer.isEmpty ? "(the user didn't answer — use your best judgement)" : "The user answered: \(answer)", isError: false)
            default:
                return Output(text: "Unknown tool '\(call.name)'.", isError: true)
            }
        } catch {
            return Output(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: implementations

    private static func saveIfDirty(_ url: URL) {
        if let d = Services.shared.documents.document(for: url), d.isDirty, d.url != nil { _ = d.save() }
    }

    static func listFiles(_ path: String, recursive: Bool) -> Output {
        guard let dir = try? WorkspaceFS.resolve(path), WorkspaceFS.isDirectory(dir) else {
            return Output(text: "'\(path)' is not a folder in the workspace.", isError: true)
        }
        var out: [String] = []
        let fm = FileManager.default
        func walk(_ u: URL, depth: Int) {
            let items = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { !Workspace.ignoredNames.contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for i in items {
                if out.count >= 400 { return }
                if WorkspaceFS.isDirectory(i) {
                    out.append(WorkspaceFS.relative(i) + "/")
                    if recursive && depth < 8 { walk(i, depth: depth + 1) }
                } else {
                    out.append(WorkspaceFS.relative(i))
                }
            }
        }
        walk(dir, depth: 0)
        if out.isEmpty { return Output(text: "(empty folder)", isError: false) }
        return Output(text: out.joined(separator: "\n") + (out.count >= 400 ? "\n…(more files not shown)" : ""), isError: false)
    }

    static func readFile(_ path: String, start: Int?, end: Int?) throws -> Output {
        let url = try WorkspaceFS.resolve(path)
        guard !WorkspaceFS.isDirectory(url) else { return listFiles(path, recursive: false) }
        guard let text = WorkspaceFS.read(url) else { throw AIError.message("No file at \(path).") }
        let lines = text.components(separatedBy: "\n")
        let lo = max(1, start ?? 1), hi = min(lines.count, end ?? lines.count)
        guard lo <= hi else { return Output(text: "(file has \(lines.count) lines)", isError: false) }
        let slice = lines[(lo - 1)..<hi].prefix(2000)
        var out = slice.enumerated().map { String(format: "%5d\t", lo + $0.offset) + $0.element }.joined(separator: "\n")
        if out.count > 60000 { out = String(out.prefix(60000)) + "\n…(truncated)" }
        if hi - lo + 1 > 2000 { out += "\n…(showing 2000 of \(hi - lo + 1) lines; use start_line/end_line)" }
        return Output(text: text.isEmpty ? "(empty file)" : out, isError: false)
    }

    static func search(_ pattern: String, regex: Bool, path: String?, caseSensitive: Bool) throws -> Output {
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        let re = try NSRegularExpression(pattern: regex ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: opts)
        let base = try WorkspaceFS.resolve(path ?? "")
        var files: [URL] = []
        if WorkspaceFS.isDirectory(base) {
            if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let f as URL in e {
                    if Workspace.ignoredNames.contains(f.lastPathComponent) { e.skipDescendants(); continue }
                    if CodebaseIndex.textExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                    if files.count > 3000 { break }
                }
            }
        } else { files = [base] }
        var out: [String] = []
        for f in files {
            guard let text = WorkspaceFS.read(f) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let ns = line as NSString
                if re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                    out.append("\(WorkspaceFS.relative(f)):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
                    if out.count >= 100 { break }
                }
            }
            if out.count >= 100 { break }
        }
        return Output(text: out.isEmpty ? "No matches." : out.joined(separator: "\n") + (out.count >= 100 ? "\n…(more matches not shown)" : ""), isError: false)
    }

    static func editFile(_ path: String, old: String, new: String, all: Bool, tracker: ChangeTracker) throws -> Output {
        let url = try WorkspaceFS.resolve(path)
        guard let text = WorkspaceFS.read(url) else { throw AIError.message("No file at \(path). Use write_file to create it.") }
        guard !old.isEmpty else { throw AIError.message("old_string is empty — use write_file for whole-file content.") }
        let count = text.components(separatedBy: old).count - 1
        if count == 0 {
            // help the model: whitespace-insensitive near miss?
            let squash: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            let hint = squash(text).contains(squash(old)) ? " The text exists but the whitespace/indentation differs — read_file and copy it exactly." : " Read the file again and copy the exact text."
            throw AIError.message("old_string was not found in \(path).\(hint)")
        }
        if count > 1 && !all { throw AIError.message("old_string appears \(count) times in \(path). Include more surrounding lines to make it unique, or set replace_all.") }
        let updated = all ? text.replacingOccurrences(of: old, with: new) : text.replacingCharacters(in: text.range(of: old)!, with: new)
        tracker.willModify(url)
        try WorkspaceFS.write(url, updated)
        tracker.didModify(url)
        CodebaseIndex.shared.reindex(url: url, text: updated)
        let st = LineDiff.stats(text, updated)
        return Output(text: "Edited \(WorkspaceFS.relative(url))\(all && count > 1 ? " (\(count) places)" : "") (+\(st.added) −\(st.removed) lines).", isError: false)
    }
}
