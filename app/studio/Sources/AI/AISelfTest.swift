import AppKit

/// Headless checks and snapshot demos for the AI module. Run with the mock
/// provider so nothing touches the network or the Keychain:
///
///     VANTA_AI_SELFTEST_EXIT=1 "Vanta Studio" --snapshot /tmp/x.png --mock-ai --run ai.selftest --settle 60
///     "Vanta Studio" --snapshot out.png --mock-ai --workspace DIR --run ai.demo.agent --settle 12
enum AISelfTest {
    static func registerCommands(_ s: Services) {
        let c = s.commands
        func hidden(_ id: String, _ action: @escaping () -> Void) {
            c.register(id: id, title: id, category: .ai, inMenu: false, inPalette: false, action: action)
        }
        hidden("ai.selftest") { Task { @MainActor in await run() } }
        hidden("ai.demo.agent") {
            let vee = VeeAssistant.shared
            s.layout.auxVisible = true
            vee.mode = "agent"
            vee.send("Build a small calculator in calc.va with tests, run it, and fix anything that fails.")
        }
        hidden("ai.demo.chat") {
            s.layout.auxVisible = true
            VeeAssistant.shared.mode = "chat"
            if let ed = s.editor, ed.text.count > 20 {
                ed.selections = [NSRange(location: 0, length: min(60, (ed.text as NSString).length))]
                VeeAssistant.shared.addSelectionToChat()
            }
            VeeAssistant.shared.send("How do I give a function a default value? @book")
        }
        hidden("ai.demo.book") {
            s.layout.showSidebar(PanelID.book)
            BookReaderModel.shared.query = "default parameter values"
        }
        hidden("ai.demo.bookReader") {
            s.layout.showSidebar(PanelID.book)
            KnowledgeBase.shared.loadNow()
            if let d = KnowledgeBase.shared.documents.first(where: { $0.url.lastPathComponent.hasPrefix("21-") }) {
                BookReaderModel.shared.open(url: d.url, line: 0)
            }
        }
        hidden("ai.demo.askBook") {
            s.layout.auxVisible = true
            VeeAssistant.shared.mode = "book"
            VeeAssistant.shared.send("How do I write a test with expect?")
        }
        hidden("ai.demo.inline") {
            guard let ed = s.editor else { return }
            selectLines(ed, 1, 3)
            InlineEditController.shared.begin()
            InlineEditController.shared.prompt = "add a friendly comment and sparkle the output"
        }
        hidden("ai.demo.inlineDiff") {
            guard let ed = s.editor else { return }
            selectLines(ed, 1, 3)
            let ie = InlineEditController.shared
            ie.begin()
            ie.prompt = "add a friendly comment and sparkle the output"
            ie.submit()
        }
        hidden("ai.demo.lightbulb") {
            guard let ed = s.editor else { return }
            let line = min(4, max(0, ed.document.lines.count - 1))
            ed.scrollToLine(line, select: true)
            s.diagnostics.publish([Diagnostic(line: line, severity: .error, message: "'undefined_thing' is not defined", source: "vanta check")],
                                  for: ed.document.uri, source: "demo")
        }
        hidden("ai.demo.ghost") {
            guard let ed = s.editor else { return }
            let ns = ed.text as NSString
            if let r = ed.text.range(of: "to ") {
                let start = ed.text.distance(from: ed.text.startIndex, to: r.lowerBound)
                let lr = ns.lineRange(for: NSRange(location: start, length: 0))
                let end = lr.location + ns.substring(with: lr).trimmingCharacters(in: .newlines).utf16.count
                ed.selections = [NSRange(location: end, length: 0)]
                let prefix = ns.substring(to: end), suffix = ns.substring(from: end)
                Task { @MainActor in
                    if let g = await Autocomplete.shared.complete(prefix: prefix, suffix: suffix, uri: ed.document.uri) { ed.setGhostText(g, at: end) }
                }
            }
        }
        hidden("ai.demo.settings") {   // snapshot-only: show the AI settings tab in the right panel
            s.panels.register(id: PanelID.ai, title: "AI Settings", icon: "sparkles", location: .auxiliary, order: 0) { AISettingsView() }
            s.layout.auxVisible = true
            s.layout.auxWidth = 620
        }
        hidden("ai.demo.review") { ChangeTracker.shared.reviewExpanded = true }
        hidden("ai.demo.fix") {
            RunController.shared.console = "Oops! line 5: I don't know what 'undefined_thing' is yet\n  --> demo.va:5\n"
            RunController.shared.lastRunFailed = true
            VeeAssistant.shared.fixRunError()
        }
    }

    static func selectLines(_ ed: EditorController, _ from: Int, _ to: Int) {
        let lines = ed.document.lines
        let a = lines.start(of: min(from, lines.count - 1)), b = NSMaxRange(lines.range(of: min(to, lines.count - 1)))
        ed.selections = [NSRange(location: a, length: b - a)]
    }

    // MARK: the test run

    private static var failures = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)  \(detail())") }
    }

    @MainActor
    static func waitIdle(_ timeout: Double = 30) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 100_000_000)
        while VeeAssistant.shared.busy && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @MainActor
    static func run() async {
        failures = 0
        let vee = VeeAssistant.shared
        print("== Vee self-test (mock provider: \(vee.isMock), keychain sandboxed: \(KeyStore.shared.sandboxed)) ==")
        check("keychain untouched in tests", KeyStore.shared.sandboxed)
        unitTests()
        ragTests()
        await autocompleteTests()
        if vee.isMock {
            await chatTests()
            await agentTests()
            await inlineEditTests()
            await fixTests()
        } else {
            print("SKIP  live-provider flows (run with --mock-ai)")
        }
        print(failures == 0 ? "AI SELFTEST: ALL PASS" : "AI SELFTEST: \(failures) FAILED")
        if ProcessInfo.processInfo.environment["VANTA_AI_SELFTEST_EXIT"] == "1" { exit(failures == 0 ? 0 : 1) }
    }

    // MARK: units

    static func unitTests() {
        // <think> stripping across chunk boundaries
        var vis = "", hid = ""
        let sp = TagSplitter([.init(open: "<think>", close: "</think>")])
        for ch in ["Hel", "lo <thi", "nk>secret plan</th", "ink> world"] { sp.feed(ch, visible: { vis += $0 }, hiddenDelta: { _, s in hid += s }) }
        sp.flush(visible: { vis += $0 })
        check("reasoning <think> stripped while streaming", vis == "Hello  world" && hid == "secret plan", "\(vis.debugDescription) / \(hid.debugDescription)")

        // Anthropic SSE parsing: thinking + text + streamed tool input + usage
        var events: [LLMEvent] = []
        let ap = AnthropicStreamParser(model: "claude-sonnet-5-5", textTools: false) { events.append($0) }
        let sse: [(String, [String: Any])] = [
            ("message_start", ["message": ["usage": ["input_tokens": 100, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 0, "output_tokens": 1]]]),
            ("content_block_start", ["index": 0, "content_block": ["type": "thinking", "thinking": ""]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "thinking_delta", "thinking": "plan"]]),
            ("content_block_delta", ["index": 0, "delta": ["type": "signature_delta", "signature": "sig123"]]),
            ("content_block_start", ["index": 1, "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["index": 1, "delta": ["type": "text_delta", "text": "Let me read it."]]),
            ("content_block_start", ["index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "read_file", "input": [:]]]),
            ("content_block_delta", ["index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"path\": \"ca"]]),
            ("content_block_delta", ["index": 2, "delta": ["type": "input_json_delta", "partial_json": "lc.va\"}"]]),
            ("message_delta", ["delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 42]]),
        ]
        for (e, j) in sse { try? ap.handle(event: e, j) }
        ap.finish()
        let msg = events.compactMap { if case let .message(m) = $0 { return m }; return nil }.first
        let calls = msg?.toolCalls ?? []
        check("anthropic stream → tool call", calls.first?.name == "read_file" && calls.first?.args["path"] as? String == "calc.va")
        check("anthropic stream keeps thinking signature for replay",
              msg?.blocks.contains(where: { if case let .thinking(t, s) = $0 { return t == "plan" && s == "sig123" }; return false }) == true)
        let usage = events.compactMap { if case let .usage(u) = $0 { return u }; return nil }.first
        check("anthropic usage + cost", usage?.cacheRead == 9000 && usage?.output == 42 && (usage?.cost ?? 0) > 0, "\(String(describing: usage))")

        // OpenAI-compatible tool call deltas
        events = []
        let op = OpenAIStreamParser(model: "x", textTools: false) { events.append($0) }
        for j: [String: Any] in [
            ["choices": [["delta": ["content": "<think>hmm</think>Sure."]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_9", "function": ["name": "run_tests", "arguments": "{\"pa"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "th\": \"t.va\"}"]]]], "finish_reason": "tool_calls"]]],
            ["usage": ["prompt_tokens": 50, "completion_tokens": 7]],
        ] { try? op.handle(j) }
        op.finish()
        let om = events.compactMap { if case let .message(m) = $0 { return m }; return nil }.first
        check("openai stream → tool call + think stripped", om?.toolCalls.first?.args["path"] as? String == "t.va" && om?.text == "Sure.", "\(String(describing: om))")

        // text tool protocol for models without native tools
        let parsed = TextToolProtocol.parse([("<tool_call>", "{\"name\": \"check\", \"arguments\": {\"path\": \"a.va\"}}")])
        check("text tool protocol parses calls", parsed.first?.name == "check" && parsed.first?.args["path"] as? String == "a.va")

        // errors
        check("401 → bad key", AIClient.httpError(401, Data("{\"error\":{\"message\":\"invalid x-api-key\"}}".utf8), retryAfter: nil, hadTools: false) == .badKey("invalid x-api-key"))
        if case .rateLimited = AIClient.httpError(429, Data(), retryAfter: "3", hadTools: false) { check("429 → rate limited (retryable)", true) } else { check("429 → rate limited", false) }
        if case .toolsUnsupported = AIClient.httpError(400, Data("{\"error\":{\"message\":\"model does not support tools\"}}".utf8), retryAfter: nil, hadTools: true) {
            check("400 'tools unsupported' → text fallback", true)
        } else { check("400 'tools unsupported' → text fallback", false) }

        // request bodies
        let req = LLMRequest(model: "claude-sonnet-5-5", system: AISystemPrompt.system(for: "agent", cheatSheet: "CHEAT"),
                             messages: [.user("hi")], tools: AgentTools.definitions, purpose: .agent, cacheConversation: true)
        let body = AIClient.anthropicBody(req, textTools: false)
        let sys = body["system"] as? [[String: Any]] ?? []
        check("anthropic: cache_control on reference + rules", sys.filter { $0["cache_control"] != nil }.count == 2)
        let lastMsg = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        check("anthropic: cache breakpoint on the conversation tail", lastMsg?.last?["cache_control"] != nil)
        check("anthropic: tools stream eagerly", ((body["tools"] as? [[String: Any]])?.first?["eager_input_streaming"] as? Bool) == true)
        let fast = AIClient.anthropicBody(LLMRequest(model: "claude-haiku-5-5", system: [], messages: [.user("x")], purpose: .completion), textTools: false)
        check("haiku completions: thinking off, low effort", (fast["thinking"] as? [String: Any])?["type"] as? String == "disabled"
              && (fast["output_config"] as? [String: Any])?["effort"] as? String == "low")
        let oai = AIClient.openAIBody(req, textTools: false)
        check("openai body: function tools", ((oai["tools"] as? [[String: Any]])?.count ?? 0) == AgentTools.definitions.count)

        // diff hunks
        let base = "a\nb\nc\nd\n", new = "a\nB\nc\nd\ne\n"
        let hs = LineDiff.hunks(base, new)
        check("diff hunks", hs.count == 2, "\(hs)")
        if hs.count == 2 {
            check("reject one hunk", LineDiff.revert(hs[0], in: new) == "a\nb\nc\nd\ne\n")
            check("accept one hunk", LineDiff.apply(hs[1], to: base) == "a\nb\nc\nd\ne\n")
        }
        if let r = LineDiff.changedRegion(old: "x\ny\nz", new: "x\nY\nz") {
            check("changed region", ((("x\ny\nz") as NSString).replacingCharacters(in: r.range, with: r.replacement)) == "x\nY\nz")
        }
        if let r = LineDiff.changedRegion(old: "a\nb", new: "a\nb\nc") {
            check("changed region (append)", (("a\nb" as NSString).replacingCharacters(in: r.range, with: r.replacement)) == "a\nb\nc")
        }

        // structural apply
        let file = "to add(a, b)\n    give back a - b\nend\n\nsay add(1, 2)\n"
        let merged = CodeMerge.merge(snippet: "to add(a, b)\n    give back a + b\nend", into: file)
        check("apply merges a function by name", merged == "to add(a, b)\n    give back a + b\nend\n\nsay add(1, 2)\n", merged ?? "nil")
        check("apply refuses ambiguous loose snippets", CodeMerge.merge(snippet: "say 1", into: file) == nil)

        // autocomplete cleanup
        check("completion cleanup drops repeated line",
              Autocomplete.clean("to add(a, b)\n    give back a + b\nend", prefix: "to add(a, b)", suffix: "") == "\n    give back a + b\nend")

        let blocks = MarkdownBlocks.codeBlocks("Update calc.va:\n```vanta\nsay 1\n```\n")
        check("code block file hint", blocks.first?.fileHint == "calc.va")
        check("mentions", ContextBuilder.mentions(in: "fix @calc.va using @problems, please").map(\.name) == ["calc.va", "problems"])
    }

    // MARK: RAG

    static func ragTests() {
        let kb = KnowledgeBase.shared
        kb.loadNow()
        check("book loaded", kb.documents.count >= 30, "\(kb.documents.count) docs")
        check("cheat sheet from appendices", kb.cheatSheet.contains("give back") && kb.cheatSheet.contains("Built-in functions") && kb.cheatSheet.count > 8000,
              "\(kb.cheatSheet.count) chars")
        print("      book: \(kb.documents.count) docs, \(kb.chunks.count) chunks; cheat sheet \(kb.cheatSheet.count) chars (~\(kb.cheatSheet.count / 4) tokens), compact \(kb.compactCheatSheet.count) chars")
        let questions: [(String, String)] = [
            ("how do I give a function a default parameter value", "Functions"),
            ("read and write a json file", "Files"),
            ("make my own type with methods and inheritance", "Types"),
            ("loop over a map's keys and values", "Maps"),
            ("catch an error with attempt and rescue", "rror"),
            ("write a test with expect", "est"),
            ("draw a rectangle on the canvas in a game", "ame"),
            ("http server that serves json", "nternet"),
        ]
        var hitsTop3 = 0
        for (q, want) in questions {
            let t0 = Date()
            let hits = kb.search(q, k: 3)
            let ms = Date().timeIntervalSince(t0) * 1000
            print("  Q: \(q)  (\(String(format: "%.1f", ms)) ms)")
            for h in hits { print("     · [\(h.source.rawValue)] \(h.citation)") }
            if hits.contains(where: { $0.citation.contains(want) || $0.text.prefix(300).contains(want) }) { hitsTop3 += 1 }
        }
        check("RAG relevance: expected chapter in top 3 for ≥ 6/8 questions", hitsTop3 >= 6, "\(hitsTop3)/8")
    }

    // MARK: flows (mock provider)

    @MainActor
    static func autocompleteTests() async {
        guard VeeAssistant.shared.isMock else { return }
        let ac = Autocomplete.shared
        let uri = URL(fileURLWithPath: "/tmp/t.va")
        let a = await ac.complete(prefix: "to add(a, b)", suffix: "\n", uri: uri)
        check("autocomplete (mock) completes a function body", a == "\n    give back a + b\nend", a ?? "nil")
        let before = ac.hits
        _ = await ac.complete(prefix: "to add(a, b)", suffix: "\n", uri: uri)
        check("autocomplete cache hit", ac.hits == before + 1)
        let typed = await ac.complete(prefix: "to add(a, b)\n    give", suffix: "\n", uri: uri)
        check("autocomplete typed-through reuse", typed == " back a + b\nend", typed ?? "nil")
    }

    @MainActor
    static func chatTests() async {
        let vee = VeeAssistant.shared
        let store = ChatStore.shared
        store.newConversation()
        vee.mode = "chat"
        vee.send("How do default values work? @book")
        await waitIdle()
        let items = store.current.items
        let reply = items.last { $0.role == .assistant }
        check("chat streams a reply with a vanta block", reply?.text.contains("```vanta") == true, reply?.text ?? "nil")
        check("chat attaches book context", items.first?.refs.contains { $0.kind == .book } == true, "\(items.first?.refs.map(\.label) ?? [])")
        check("chat transcript alternates", store.current.transcript.map(\.role) == [.user, .assistant])
        check("usage recorded", store.current.usage.total > 0)
        // edit & resend
        if let u = items.first(where: { $0.role == .user }) {
            vee.beginEdit(u)
            vee.send("How do lambdas work?")
            await waitIdle()
            check("edit & resend replaces the turn", store.current.items.filter { $0.role == .user }.map(\.text) == ["How do lambdas work?"])
        }
        vee.mode = "book"
        vee.send("How do I write a test?")
        await waitIdle()
        check("ask the book cites sections", store.current.items.last?.text.contains("According to The Vanta Book") == true)
        vee.mode = "chat"
    }

    @MainActor
    static func agentTests() async {
        let vee = VeeAssistant.shared
        let s = Services.shared
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vee-agent-test-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        s.workspace.open(dir)
        ChatStore.shared.newConversation()
        vee.mode = "agent"
        vee.send("Build a small calculator in calc.va with tests, run it, and fix anything that fails.")
        await waitIdle(60)
        let items = ChatStore.shared.current.items
        let tools = items.compactMap(\.tool)
        print("      agent steps: " + tools.map { "\($0.name)=\($0.status.rawValue)" }.joined(separator: ", "))
        let file = (try? String(contentsOf: dir.appendingPathComponent("calc.va"), encoding: .utf8)) ?? ""
        check("agent wrote calc.va and fixed the bug", file.contains("give back a + b"), file)
        let testRuns = tools.filter { $0.name == "run_tests" }
        check("agent saw the failing test, then a passing one", testRuns.count == 2 && testRuns.first?.status == .failed && testRuns.last?.status == .done,
              testRuns.map { "\($0.status): \($0.result.prefix(120))" }.joined(separator: " | "))
        check("agent ran the program", tools.contains { $0.name == "run_program" && $0.result.contains("2 + 3 = 5") })
        check("agent finished with a summary", items.last?.role == .assistant && items.last?.text.contains("Done") == true)
        let pending = ChangeTracker.shared.pending
        check("changes staged for review", pending.count == 1 && pending.first?.baseline == nil)
        let tr = ChatStore.shared.current.transcript
        let toolUses = tr.flatMap(\.toolCalls).count
        let toolResults = tr.flatMap(\.blocks).filter { if case .toolResult = $0 { return true }; return false }.count
        check("every tool_use has a tool_result", toolUses == toolResults && toolUses >= 5, "\(toolUses) vs \(toolResults)")
        // checkpoint restore removes the created file
        if let cp = items.first(where: { $0.role == .user })?.checkpointID {
            vee.restoreCheckpoint(cp)
            check("restore checkpoint undoes the turn", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("calc.va").path)
                  && ChangeTracker.shared.pending.isEmpty)
        }
        // stop mid-run leaves a valid transcript
        ChatStore.shared.newConversation()
        MockAI.chunkDelay = 40_000_000
        vee.send("Build a small calculator in calc.va with tests.")
        try? await Task.sleep(nanoseconds: 300_000_000)
        vee.stop()
        await waitIdle(10)
        MockAI.chunkDelay = 6_000_000
        check("stop ends the agent", !vee.busy)
        let tr2 = ChatStore.shared.current.transcript
        check("stopped transcript stays valid", tr2.flatMap(\.toolCalls).count == tr2.flatMap(\.blocks).filter { if case .toolResult = $0 { return true }; return false }.count)
        ChangeTracker.shared.rejectAll()
        vee.mode = "chat"
    }

    @MainActor
    static func inlineEditTests() async {
        let s = Services.shared
        let d = s.documents.newUntitled(text: "say \"hi\"\nsay \"there\"\n", name: "inline.va")
        let pane = s.editors.open(document: d)
        pane.selections = [NSRange(location: 0, length: 8)]
        let ie = InlineEditController.shared
        ie.begin()
        check("⌘K opens the prompt on the selected lines", ie.phase == .prompting && ie.regionLabel == "line 1")
        ie.prompt = "make it exciting"
        ie.submit()
        let end = Date().addingTimeInterval(10)
        while ie.phase == .generating && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("⌘K streams into an inline diff", ie.phase == .reviewing && pane.hasInlineDiff)
        ie.accept()
        check("⌘K accept applies the rewrite", d.text.hasPrefix("# make it exciting\nsay \"✨ hi\"\nsay \"there\""), d.text)
        // generate on a blank line
        pane.setText("say 1\n\nsay 2\n")
        pane.selections = [NSRange(location: 6, length: 0)]
        ie.begin()
        check("⌘K on a blank line generates code", ie.isGenerate)
        ie.prompt = "a greeting function"
        ie.submit()
        while ie.phase == .generating && Date() < end.addingTimeInterval(5) { try? await Task.sleep(nanoseconds: 50_000_000) }
        ie.accept()
        check("⌘K generate inserts code", d.text.contains("to greet(name)"), d.text)
        // Apply from chat (structural merge → inline diff)
        pane.setText("to add(a, b)\n    give back a - b\nend\n\nsay add(2, 3)\n")
        VeeAssistant.shared.applyBlock("to add(a, b)\n    give back a + b\nend", fileHint: nil)
        check("Apply shows an inline diff", pane.hasInlineDiff)
        pane.acceptInlineDiff()
        check("Apply merges the function", pane.text == "to add(a, b)\n    give back a + b\nend\n\nsay add(2, 3)\n", pane.text)
    }

    @MainActor
    static func fixTests() async {
        let s = Services.shared
        let d = s.documents.newUntitled(text: "to add(a, b)\n    give back a - b\nend\nsay add(2, 3)\n", name: "fixme.va")
        let pane = s.editors.open(document: d)
        RunController.shared.console = "Oops! expected 5, got -1\n"
        RunController.shared.lastRunFailed = true
        VeeAssistant.shared.mode = "chat"
        VeeAssistant.shared.fixRunError()
        await waitIdle()
        check("Fix with Vee explains and proposes an inline diff", pane.hasInlineDiff
              && ChatStore.shared.current.items.last?.text.contains("What went wrong") == true)
        pane.acceptInlineDiff()
        check("Fix with Vee applies the fix", d.text.contains("a + b"), d.text)
        RunController.shared.lastRunFailed = false
    }
}
