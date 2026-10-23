import Foundation

/// The offline provider used by tests (`--mock-ai` or VANTA_STUDIO_MOCK_AI=1).
/// It streams scripted replies through the same event pipeline as the real
/// providers — text deltas, tool calls, usage — so chat, ⌘K, autocomplete and
/// the full agent loop can be exercised headlessly without a key.
enum MockAI {
    static var chunkDelay: UInt64 = 6_000_000      // ns between streamed chunks

    static func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (text, calls) = script(req)
                    try await emit(text, calls: calls, model: req.model, inputSize: req.messages.reduce(0) { $0 + $1.text.count }, cont: cont)
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private static func emit(_ text: String, calls: [LLMToolCall], model: String, inputSize: Int,
                             cont: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        var i = text.startIndex
        while i < text.endIndex {
            try Task.checkCancellation()
            let j = text.index(i, offsetBy: 6, limitedBy: text.endIndex) ?? text.endIndex
            cont.yield(.text(String(text[i..<j])))
            i = j
            if chunkDelay > 0 { try await Task.sleep(nanoseconds: chunkDelay) }
        }
        for c in calls {
            cont.yield(.toolCallStarted(id: c.id, name: c.name))
            cont.yield(.toolCall(c))
        }
        var blocks: [LLMBlock] = text.isEmpty ? [] : [.text(text)]
        blocks += calls.map { .toolUse($0) }
        cont.yield(.message(LLMMessage(role: .assistant, blocks: blocks)))
        let usage = LLMUsage(input: 400 + inputSize / 4, output: max(1, text.count / 4) + calls.count * 40,
                             cacheRead: 9000, cacheWrite: 0).priced(model.hasPrefix("mock") ? "claude-sonnet-5-5" : model)
        cont.yield(.usage(usage))
        cont.yield(.stop(calls.isEmpty ? "end_turn" : "tool_use"))
    }

    private static func call(_ name: String, _ args: [String: Any]) -> LLMToolCall {
        let d = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        return LLMToolCall(id: "toolu_mock_\(UUID().uuidString.prefix(8).lowercased())", name: name,
                           arguments: String(data: d, encoding: .utf8) ?? "{}")
    }

    // MARK: scripts

    static func script(_ req: LLMRequest) -> (String, [LLMToolCall]) {
        let system = req.system.map(\.text).joined(separator: "\n")
        let lastUser = req.messages.last(where: { $0.role == .user })?.text ?? ""
        switch req.purpose {
        case .completion: return (completion(lastUser), [])
        case .edit: return (edit(lastUser), [])
        case .agent: return agent(req)
        default:
            if system.contains("MODE: Fix with Vee") { return (fix(lastUser), []) }
            if system.contains("MODE: Ask the Book") { return (book(lastUser), []) }
            return (chat(lastUser), [])
        }
    }

    static let buggyCalc = """
    # calc.va — a tiny calculator, written by Vee
    to add(a, b)
        give back a - b
    end

    to average(numbers)
        give back sum(numbers) / length(numbers)
    end

    say "2 + 3 = {add(2, 3)}"
    say "average of [2, 4, 9] = {average([2, 4, 9])}"

    test "add works"
        expect add(2, 3) is 5
        expect add(-1, 1) is 0
    end

    test "average works"
        expect average([2, 4, 9]) is 5
    end

    """

    /// The agent script reacts to the latest tool result, like a real model would.
    static func agent(_ req: LLMRequest) -> (String, [LLMToolCall]) {
        let results: [(name: String, content: String, isError: Bool)] = req.messages.flatMap { m -> [(String, String, Bool)] in
            m.blocks.compactMap { b in
                if case let .toolResult(id, content, err) = b {
                    let name = req.messages.flatMap(\.toolCalls).first { $0.id == id }?.name ?? ""
                    return (name, content, err)
                }
                return nil
            }
        }
        guard let last = results.last else {
            return ("I'll build a small calculator with tests:\n- write `calc.va` with `add` and `average`\n- run the tests and fix anything that fails\n- run the program to check the output",
                    [call("write_file", ["path": "calc.va", "content": buggyCalc])])
        }
        switch last.name {
        case "write_file":
            return ("Now let's run the tests.", [call("run_tests", ["path": "calc.va"])])
        case "run_tests":
            if last.isError || last.content.contains("FAIL") {
                if results.contains(where: { $0.name == "edit_file" }) {
                    return ("The tests still fail — I'll stop here so you can take a look.", [])
                }
                return ("`add works` failed: `add(2, 3)` gave back -1, so `add` subtracts. Let me look at it.",
                        [call("read_file", ["path": "calc.va", "start_line": 1, "end_line": 4])])
            }
            return ("All tests pass. Let me run the program too.", [call("run_program", ["path": "calc.va"])])
        case "read_file":
            return ("Line 3 uses `-` instead of `+`. Fixing it:",
                    [call("edit_file", ["path": "calc.va", "old_string": "    give back a - b", "new_string": "    give back a + b"])])
        case "edit_file":
            return ("", [call("run_tests", ["path": "calc.va"])])
        case "run_program":
            return ("Done! ✅\n\n- Created **calc.va** with `add` and `average` plus two tests.\n- The first test run caught a bug (`add` subtracted); I fixed line 3.\n- Tests pass and the program prints:\n```\n\(last.content.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))\n```", [])
        default:
            return ("Done.", [])
        }
    }

    static func chat(_ msg: String) -> String {
        let q = msg.components(separatedBy: "</context>").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? msg
        return """
        Here's a friendly way to do that in Vanta — a function with a **default value**, called with and without a named value:

        greet.va:
        ```vanta
        to greet(name, greeting be "Hello")
            give back "{greeting}, {name}!"
        end

        say greet("Ana")
        say greet("Ben", greeting: "Hi")
        ```

        - `to … end` defines the function; `give back` hands the result back.
        - `greeting be "Hello"` makes the second parameter optional.
        - Text in `{braces}` is filled in when the line runs.

        _(Mock reply to: “\(q.prefix(80))”)_
        """
    }

    static func book(_ msg: String) -> String {
        let titles = msg.components(separatedBy: "title=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        let cites = titles.prefix(3).map { "*\($0)*" }.joined(separator: ", ")
        return """
        According to The Vanta Book (\(cites.isEmpty ? "no matching section" : cites)):

        A function is defined with `to`, and `give back` returns its result:

        ```vanta
        to square(n)
            give back n * n
        end
        say square(4)
        ```
        """
    }

    static func fix(_ msg: String) -> String {
        var file = ""
        if let a = msg.range(of: "<active_file"), let s = msg.range(of: ">\n", range: a.upperBound..<msg.endIndex),
           let e = msg.range(of: "\n</active_file>", range: s.upperBound..<msg.endIndex) {
            file = String(msg[s.upperBound..<e.lowerBound])
        }
        let fixed = file.replacingOccurrences(of: "a - b", with: "a + b").replacingOccurrences(of: "undefined_thing", with: "\"something\"")
        return """
        **What went wrong** — line 3 uses `-`, so `add(2, 3)` gives back `-1` instead of `5`.

        **The fix**
        ```vanta
        \(fixed)
        ```

        **Remember** — when a test fails, compare the *expected* and *got* values: they usually point straight at the line.
        """
    }

    static func edit(_ msg: String) -> String {
        if msg.contains("Merge the SNIPPET"), let f = between(msg, "\">\n", "\n</file>"), let s = between(msg, "<snippet>\n", "\n</snippet>") {
            return f + "\n\n" + s + "\n"
        }
        let region = between(msg, "<region>\n", "</region>") ?? ""
        let instruction = msg.components(separatedBy: "Instruction: ").last?.components(separatedBy: "\n").first
            ?? msg.components(separatedBy: "instruction:\n").last?.components(separatedBy: "\n").first ?? "edit"
        if msg.contains("marks the cursor on an empty line") {
            return "to greet(name)\n    say \"Hello, {name}!\"\nend\n"
        }
        let indent = String(region.prefix { $0 == " " })
        var out = region.replacingOccurrences(of: "say \"", with: "say \"✨ ")
        if out == region { out = region.replacingOccurrences(of: "give back", with: "give back") }
        return "\(indent)# \(instruction.trimmingCharacters(in: .whitespaces))\n" + out
    }

    static func completion(_ msg: String) -> String {
        let prefix = between(msg, "<prefix>", "</prefix>") ?? ""
        let lastLine = prefix.components(separatedBy: "\n").last ?? ""
        let t = lastLine.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("to "), let open = t.firstIndex(of: "("), let close = t.firstIndex(of: ")") {
            let params = t[t.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let body = params.count >= 2 ? "\(params[0]) + \(params[1])" : (params.first ?? "nothing")
            return "\n    give back \(body)\nend"
        }
        if t.hasPrefix("say \"") { return "Hello from Vanta!\"" }
        if t.hasPrefix("for each") { return "\n    say item\nend" }
        return "\nsay \"done\""
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }
}
