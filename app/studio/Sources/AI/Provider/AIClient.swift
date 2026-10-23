import Foundation

/// The provider layer: streaming (SSE) for the Anthropic Messages API and
/// OpenAI-compatible chat completions, native tool calling for both (with a
/// text fallback for models without tools), retries with backoff, clear
/// errors, Anthropic prompt caching, usage/cost, and reasoning-model handling.
///
///     for try await ev in AIClient.stream(req, settings: s, apiKey: key) { … }
///
/// Cancel by cancelling the consuming Task — the HTTP request is torn down.
enum AIClient {
    /// Set by VeeAssistant: route every request to the offline scripted provider.
    static var useMock = false

    /// Models that rejected native tools this session — they get the text protocol.
    private static var noToolModels = Set<String>()
    private static let lock = NSLock()

    static func stream(_ req: LLMRequest, settings: AISettings, apiKey: String) -> AsyncThrowingStream<LLMEvent, Error> {
        if useMock { return MockAI.stream(req) }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await run(req, settings: settings, apiKey: apiKey, emit: { cont.yield($0) })
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience: collect the whole reply.
    static func send(_ req: LLMRequest, settings: AISettings, apiKey: String,
                     onText: ((String) -> Void)? = nil) async throws -> LLMResponse {
        var r = LLMResponse()
        for try await ev in stream(req, settings: settings, apiKey: apiKey) {
            switch ev {
            case let .text(t): r.text += t; onText?(t)
            case let .thinking(t): r.thinking += t
            case let .toolCall(c): r.toolCalls.append(c)
            case let .message(m): r.message = m
            case let .usage(u): r.usage = u
            case let .stop(s): r.stopReason = s
            default: break
            }
        }
        return r
    }

    // MARK: run with retries

    private static func run(_ req: LLMRequest, settings: AISettings, apiKey: String,
                            emit: @escaping (LLMEvent) -> Void) async throws {
        guard !apiKey.isEmpty else { throw AIError.noKey }
        var textMode = false
        lock.lock(); if !req.tools.isEmpty && noToolModels.contains(req.model) { textMode = true }; lock.unlock()
        var attempt = 0
        while true {
            var emitted = false
            let tracking: (LLMEvent) -> Void = { ev in
                if case .status = ev {} else { emitted = true }
                emit(ev)
            }
            do {
                if AIProvider.isAnthropicFormat(settings.provider) {
                    try await anthropic(req, settings: settings, apiKey: apiKey, textTools: textMode, emit: tracking)
                } else {
                    try await openAI(req, settings: settings, apiKey: apiKey, textTools: textMode, emit: tracking)
                }
                return
            } catch let e as AIError {
                if case .toolsUnsupported = e, !textMode, !emitted {
                    lock.lock(); noToolModels.insert(req.model); lock.unlock()
                    textMode = true
                    emit(.status("This model has no native tools — using the text protocol"))
                    continue
                }
                guard e.isRetryable, !emitted, attempt < 3, !Task.isCancelled else { throw e }
                let delay = retryDelay(e, attempt: attempt)
                emit(.status("\(e.shortLabel) — retrying in \(Int(delay.rounded()))s…"))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                let err = AIError.network(e.localizedDescription)
                guard !emitted, attempt < 3, !Task.isCancelled else { throw err }
                let delay = retryDelay(err, attempt: attempt)
                emit(.status("Network hiccup — retrying in \(Int(delay.rounded()))s…"))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private static func retryDelay(_ e: AIError, attempt: Int) -> Double {
        if case let .rateLimited(m) = e, let s = Double(m.components(separatedBy: "retry-after:").last?
            .trimmingCharacters(in: .whitespaces) ?? ""), s > 0 { return min(s, 30) }
        return min(1.5 * pow(2, Double(attempt)), 12)
    }

    // MARK: HTTP

    static func base(_ s: AISettings) -> String {
        let b = s.baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? AIProvider.defaultBase(s.provider) : s.baseURL
        return b.hasSuffix("/") ? String(b.dropLast()) : b
    }

    private static func post(_ url: String, body: [String: Any], headers: [String: String]) async throws -> URLSession.AsyncBytes {
        guard let u = URL(string: url) else { throw AIError.message("Bad base URL: \(url)") }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        if status >= 400 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 65536 { break } }
            let retryAfter = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            throw httpError(status, data, retryAfter: retryAfter, hadTools: (body["tools"] as? [Any])?.isEmpty == false)
        }
        return bytes
    }

    static func httpError(_ status: Int, _ data: Data, retryAfter: String?, hadTools: Bool) -> AIError {
        var msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = json["error"] as? [String: Any], let m = e["message"] as? String { msg = m }
            else if let m = json["error"] as? String { msg = m }
            else if let m = json["message"] as? String { msg = m }
            else if let m = json["detail"] as? String { msg = m }
        }
        if msg.count > 400 { msg = String(msg.prefix(400)) + "…" }
        let lower = msg.lowercased()
        switch status {
        case 401, 403: return .badKey(msg.isEmpty ? "HTTP \(status)" : msg)
        case 429: return .rateLimited(msg + (retryAfter.map { " retry-after: \($0)" } ?? ""))
        case 529, 503: return .overloaded(msg)
        case 400, 404, 422:
            if hadTools && (lower.contains("tool") || lower.contains("function")) && !lower.contains("tool_use_id")
                && !lower.contains("tool_result") { return .toolsUnsupported(msg) }
            if lower.contains("credit") || lower.contains("billing") { return .message("Billing problem: \(msg)") }
            return .server(status, msg)
        default: return .server(status, msg)
        }
    }

    // MARK: Anthropic Messages

    /// Claude models that take `thinking: adaptive` + `output_config.effort`.
    static func isModernClaude(_ model: String) -> Bool {
        let m = model.lowercased().replacingOccurrences(of: ".", with: "-")
        return ["opus-5", "sonnet-5", "haiku-5", "fable", "mythos", "opus-4-6", "opus-4-7", "opus-4-8", "sonnet-4-6"]
            .contains { m.contains($0) }
    }
    static func isGen5Claude(_ model: String) -> Bool {
        let m = model.lowercased().replacingOccurrences(of: ".", with: "-")
        return ["opus-5", "sonnet-5", "haiku-5", "fable", "mythos"].contains { m.contains($0) }
    }

    static func anthropicBody(_ req: LLMRequest, textTools: Bool) -> [String: Any] {
        var system: [[String: Any]] = []
        var parts = req.system
        if textTools && !req.tools.isEmpty { parts.append(SystemPart(text: TextToolProtocol.instructions(req.tools))) }
        for p in parts where !p.text.isEmpty {
            var b: [String: Any] = ["type": "text", "text": p.text]
            if p.cache { b["cache_control"] = ["type": "ephemeral"] }
            system.append(b)
        }
        var messages: [[String: Any]] = req.messages.map { anthropicMessage($0, textTools: textTools) }
        messages = messages.filter { ($0["content"] as? [Any])?.isEmpty == false }
        if req.cacheConversation, var last = messages.last, var content = last["content"] as? [[String: Any]], !content.isEmpty {
            content[content.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = content
            messages[messages.count - 1] = last
        }
        var body: [String: Any] = ["model": req.model, "max_tokens": req.maxTokens, "stream": true,
                                   "system": system, "messages": messages]
        if !req.tools.isEmpty && !textTools {
            body["tools"] = req.tools.map { t in
                ["name": t.name, "description": t.description, "input_schema": t.schema, "eager_input_streaming": true] as [String: Any]
            }
        }
        if !req.stop.isEmpty { body["stop_sequences"] = req.stop }
        let m = req.model.lowercased()
        if isModernClaude(req.model) {
            let effort: String
            switch req.purpose {
            case .agent: effort = "medium"
            case .chat: effort = m.contains("opus") ? "medium" : "low"
            case .edit, .completion, .utility: effort = "low"
            }
            body["output_config"] = ["effort": effort]
            if req.purpose == .completion {
                // Fast ghost text: as little thinking as the model allows.
                if m.contains("haiku-5") { body["thinking"] = ["type": "disabled"] }
                else if m.contains("sonnet-5-5") { body["thinking"] = ["type": "between_tools"] }
            } else if isGen5Claude(req.model) && (req.purpose == .chat || req.purpose == .agent) {
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
            }
        }
        return body
    }

    private static func anthropicMessage(_ m: LLMMessage, textTools: Bool) -> [String: Any] {
        var content: [[String: Any]] = []
        for b in m.blocks {
            switch b {
            case let .text(t):
                if !t.isEmpty { content.append(["type": "text", "text": t]) }
            case let .thinking(t, sig):
                if !textTools && !sig.isEmpty { content.append(["type": "thinking", "thinking": t, "signature": sig]) }
            case let .redactedThinking(d):
                if !textTools { content.append(["type": "redacted_thinking", "data": d]) }
            case let .toolUse(c):
                if textTools { content.append(["type": "text", "text": TextToolProtocol.render(c)]) }
                else { content.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.args]) }
            case let .toolResult(id, text, isErr):
                if textTools {
                    content.append(["type": "text", "text": "<tool_result id=\"\(id)\"\(isErr ? " error=\"true\"" : "")>\n\(text)\n</tool_result>"])
                } else {
                    content.append(["type": "tool_result", "tool_use_id": id, "content": text.isEmpty ? "(empty)" : text, "is_error": isErr])
                }
            }
        }
        return ["role": m.role.rawValue, "content": content]
    }

    private static func anthropic(_ req: LLMRequest, settings: AISettings, apiKey: String, textTools: Bool,
                                  emit: @escaping (LLMEvent) -> Void) async throws {
        let body = anthropicBody(req, textTools: textTools)
        let bytes = try await post(base(settings) + "/messages", body: body,
                                   headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"])
        let parser = AnthropicStreamParser(model: req.model, textTools: textTools && !req.tools.isEmpty, emit: emit)
        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            try parser.handle(event: (json["type"] as? String) ?? event, json)
        }
        parser.finish()
    }

    // MARK: OpenAI-compatible chat completions

    static func openAIBody(_ req: LLMRequest, textTools: Bool) -> [String: Any] {
        var sys = req.system.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if textTools && !req.tools.isEmpty { sys += "\n\n" + TextToolProtocol.instructions(req.tools) }
        var messages: [[String: Any]] = [["role": "system", "content": sys]]
        for m in req.messages {
            switch m.role {
            case .assistant:
                var text = ""
                var calls: [[String: Any]] = []
                for b in m.blocks {
                    switch b {
                    case let .text(t): text += t
                    case let .toolUse(c):
                        if textTools { text += "\n" + TextToolProtocol.render(c) }
                        else { calls.append(["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments]]) }
                    default: break
                    }
                }
                var msg: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { msg["tool_calls"] = calls }
                messages.append(msg)
            case .user:
                var text = ""
                for b in m.blocks {
                    switch b {
                    case let .text(t): text += t
                    case let .toolResult(id, content, isErr):
                        if textTools {
                            text += "<tool_result id=\"\(id)\"\(isErr ? " error=\"true\"" : "")>\n\(content)\n</tool_result>\n"
                        } else {
                            messages.append(["role": "tool", "tool_call_id": id, "content": (isErr ? "ERROR: " : "") + content])
                        }
                    default: break
                    }
                }
                if !text.isEmpty { messages.append(["role": "user", "content": text]) }
            }
        }
        var body: [String: Any] = ["model": req.model, "max_tokens": req.maxTokens, "stream": true,
                                   "stream_options": ["include_usage": true], "messages": messages]
        if !req.tools.isEmpty && !textTools {
            body["tools"] = req.tools.map { t in
                ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": t.schema]] as [String: Any]
            }
        }
        if !req.stop.isEmpty { body["stop"] = Array(req.stop.prefix(4)) }
        if req.purpose == .completion || req.purpose == .edit { body["temperature"] = 0.2 }
        return body
    }

    private static func openAI(_ req: LLMRequest, settings: AISettings, apiKey: String, textTools: Bool,
                               emit: @escaping (LLMEvent) -> Void) async throws {
        let body = openAIBody(req, textTools: textTools)
        var headers = ["Authorization": "Bearer \(apiKey)"]
        if settings.provider == "openrouter" {
            headers["HTTP-Referer"] = "https://vanta-lang.dev/studio"
            headers["X-Title"] = "Vanta Studio"
        }
        let bytes = try await post(base(settings) + "/chat/completions", body: body, headers: headers)
        let parser = OpenAIStreamParser(model: req.model, textTools: textTools && !req.tools.isEmpty, emit: emit)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else {
                // Some servers ignore stream=true and send one JSON body.
                if line.hasPrefix("{"), let d = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { try parser.handleWhole(json) }
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            try parser.handle(json)
        }
        parser.finish()
    }

    // MARK: model catalog

    static func fetchModels(settings: AISettings, apiKey: String) async throws -> [String] {
        if useMock { return ["mock-smart", "mock-fast"] }
        guard let url = URL(string: base(settings) + "/models") else { throw AIError.message("Bad base URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if AIProvider.isAnthropicFormat(settings.provider) {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.url = URL(string: base(settings) + "/models?limit=100")
        } else {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        if status >= 400 { throw httpError(status, data, retryAfter: nil, hadTools: false) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let arr = json?["data"] as? [[String: Any]] {
            let ids = arr.compactMap { $0["id"] as? String }
            if !ids.isEmpty { return ids.sorted() }
        }
        throw AIError.message("No models returned")
    }
}

extension AIError {
    var shortLabel: String {
        switch self {
        case .rateLimited: return "Rate limited"
        case .overloaded: return "Provider overloaded"
        case .network: return "Network hiccup"
        case let .server(c, _): return "Server error \(c)"
        default: return "Error"
        }
    }
}

// MARK: - Stream parsers

/// Splits streamed text into visible text and "hidden" spans between tags
/// (`<think>…</think>` from reasoning models, `<tool_call>…</tool_call>` in the
/// text tool protocol), holding back a partial tag across chunk boundaries.
final class TagSplitter {
    struct Span { let open: String; let close: String }
    private let spans: [Span]
    private var buffer = ""
    private var inside: Span?
    private(set) var hidden: [(tag: String, text: String)] = []
    private var current = ""

    init(_ spans: [Span]) { self.spans = spans }

    /// Feed a chunk; returns (visible text, hidden text that just completed or grew, tag).
    func feed(_ chunk: String, visible: (String) -> Void, hiddenDelta: (String, String) -> Void) {
        buffer += chunk
        while !buffer.isEmpty {
            if let span = inside {
                if let r = buffer.range(of: span.close) {
                    let part = String(buffer[..<r.lowerBound])
                    current += part
                    if !part.isEmpty { hiddenDelta(span.open, part) }
                    hidden.append((span.open, current))
                    current = ""
                    inside = nil
                    buffer = String(buffer[r.upperBound...])
                } else {
                    let keep = partialSuffix(buffer, span.close)
                    let part = String(buffer.dropLast(keep))
                    current += part
                    if !part.isEmpty { hiddenDelta(span.open, part) }
                    buffer = String(buffer.suffix(keep))
                    return
                }
            } else {
                var best: (Range<String.Index>, Span)?
                for s in spans { if let r = buffer.range(of: s.open), best == nil || r.lowerBound < best!.0.lowerBound { best = (r, s) } }
                if let (r, s) = best {
                    let before = String(buffer[..<r.lowerBound])
                    if !before.isEmpty { visible(before) }
                    inside = s
                    buffer = String(buffer[r.upperBound...])
                } else {
                    let keep = spans.map { partialSuffix(buffer, $0.open) }.max() ?? 0
                    let out = String(buffer.dropLast(keep))
                    if !out.isEmpty { visible(out) }
                    buffer = String(buffer.suffix(keep))
                    return
                }
            }
        }
    }

    /// Flush at end of stream. An unterminated hidden span (e.g. `<think>` never closed) is completed.
    func flush(visible: (String) -> Void) {
        if let s = inside {
            current += buffer
            hidden.append((s.open, current))
        } else if !buffer.isEmpty {
            visible(buffer)
        }
        buffer = ""; inside = nil; current = ""
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `tag`.
    private func partialSuffix(_ s: String, _ tag: String) -> Int {
        let n = min(s.count, tag.count - 1)
        guard n > 0 else { return 0 }
        for k in stride(from: n, to: 0, by: -1) where tag.hasPrefix(String(s.suffix(k))) { return k }
        return 0
    }
}

private let reasoningSpans = [TagSplitter.Span(open: "<think>", close: "</think>"),
                              TagSplitter.Span(open: "<thinking>", close: "</thinking>")]
private let toolSpan = TagSplitter.Span(open: "<tool_call>", close: "</tool_call>")

final class AnthropicStreamParser {
    private let model: String
    private let emit: (LLMEvent) -> Void
    private let textTools: Bool
    private var blocks: [Int: [String: Any]] = [:]
    private var jsonBuf: [Int: String] = [:]
    private var usage = LLMUsage()
    private var stopReason = ""
    private let splitter: TagSplitter
    private var visibleText = ""

    init(model: String, textTools: Bool, emit: @escaping (LLMEvent) -> Void) {
        self.model = model; self.emit = emit; self.textTools = textTools
        splitter = TagSplitter(textTools ? [toolSpan] + reasoningSpans : reasoningSpans)
    }

    func handle(event: String, _ json: [String: Any]) throws {
        switch event {
        case "message_start":
            if let u = (json["message"] as? [String: Any])?["usage"] as? [String: Any] { readUsage(u) }
        case "content_block_start":
            guard let i = json["index"] as? Int, let b = json["content_block"] as? [String: Any] else { return }
            blocks[i] = b
            if b["type"] as? String == "tool_use" {
                jsonBuf[i] = ""
                emit(.toolCallStarted(id: b["id"] as? String ?? "", name: b["name"] as? String ?? ""))
            }
        case "content_block_delta":
            guard let i = json["index"] as? Int, let d = json["delta"] as? [String: Any] else { return }
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                let prev = blocks[i]?["text"] as? String ?? ""
                blocks[i]?["text"] = prev + t
                splitter.feed(t, visible: { self.visibleText += $0; self.emit(.text($0)) },
                              hiddenDelta: { tag, s in if tag != toolSpan.open { self.emit(.thinking(s)) } })
            case "thinking_delta":
                let t = d["thinking"] as? String ?? ""
                let prev = blocks[i]?["thinking"] as? String ?? ""
                blocks[i]?["thinking"] = prev + t
                if !t.isEmpty { emit(.thinking(t)) }
            case "signature_delta":
                let prev = blocks[i]?["signature"] as? String ?? ""
                blocks[i]?["signature"] = prev + (d["signature"] as? String ?? "")
            case "input_json_delta":
                jsonBuf[i, default: ""] += d["partial_json"] as? String ?? ""
            default: break
            }
        case "message_delta":
            if let d = json["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stopReason = s }
            if let u = json["usage"] as? [String: Any] { readUsage(u) }
        case "error":
            let e = json["error"] as? [String: Any]
            let type = e?["type"] as? String ?? ""
            let msg = e?["message"] as? String ?? "stream error"
            if type == "overloaded_error" { throw AIError.overloaded(msg) }
            if type == "rate_limit_error" { throw AIError.rateLimited(msg) }
            throw AIError.server(500, msg)
        default: break
        }
    }

    private func readUsage(_ u: [String: Any]) {
        if let v = u["input_tokens"] as? Int { usage.input = v }
        if let v = u["output_tokens"] as? Int { usage.output = v }
        if let v = u["cache_read_input_tokens"] as? Int { usage.cacheRead = v }
        if let v = u["cache_creation_input_tokens"] as? Int { usage.cacheWrite = v }
    }

    func finish() {
        splitter.flush(visible: { self.visibleText += $0; self.emit(.text($0)) })
        var out: [LLMBlock] = []
        for i in blocks.keys.sorted() {
            guard let b = blocks[i] else { continue }
            switch b["type"] as? String {
            case "text":
                let t = b["text"] as? String ?? ""
                if textTools {
                    // keep only visible text; tool calls become real blocks below
                    out.append(.text(TextToolProtocol.strip(t)))
                } else {
                    out.append(.text(t))
                }
            case "thinking":
                out.append(.thinking(text: b["thinking"] as? String ?? "", signature: b["signature"] as? String ?? ""))
            case "redacted_thinking":
                out.append(.redactedThinking(b["data"] as? String ?? ""))
            case "tool_use":
                let raw = jsonBuf[i] ?? ""
                let args = Self.validJSON(raw)
                let c = LLMToolCall(id: b["id"] as? String ?? UUID().uuidString, name: b["name"] as? String ?? "", arguments: args)
                out.append(.toolUse(c))
                emit(.toolCall(c))
            default: break
            }
        }
        if textTools {
            for c in TextToolProtocol.parse(splitter.hidden) { out.append(.toolUse(c)); emit(.toolCall(c)) }
        }
        emit(.message(LLMMessage(role: .assistant, blocks: out)))
        emit(.usage(usage.priced(model)))
        emit(.stop(stopReason))
    }

    /// Eagerly streamed tool input may be truncated/invalid — keep it only if it parses.
    static func validJSON(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "{}" }
        if (try? JSONSerialization.jsonObject(with: Data(t.utf8))) is [String: Any] { return t }
        return "{\"__invalid_json\": true}"
    }
}

final class OpenAIStreamParser {
    private let model: String
    private let emit: (LLMEvent) -> Void
    private let textTools: Bool
    private var text = ""
    private var calls: [Int: (id: String, name: String, args: String)] = [:]
    private var usage = LLMUsage()
    private var stopReason = ""
    private let splitter: TagSplitter

    init(model: String, textTools: Bool, emit: @escaping (LLMEvent) -> Void) {
        self.model = model; self.emit = emit; self.textTools = textTools
        splitter = TagSplitter(textTools ? [toolSpan] + reasoningSpans : reasoningSpans)
    }

    func handle(_ json: [String: Any]) throws {
        if let e = json["error"] as? [String: Any] {
            throw AIError.server(e["code"] as? Int ?? 500, e["message"] as? String ?? "stream error")
        }
        if let u = json["usage"] as? [String: Any] { readUsage(u) }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return }
        if let f = choice["finish_reason"] as? String { stopReason = f }
        guard let d = choice["delta"] as? [String: Any] else { return }
        for key in ["reasoning_content", "reasoning"] {
            if let r = d[key] as? String, !r.isEmpty { emit(.thinking(r)) }
        }
        if let c = d["content"] as? String, !c.isEmpty { feedText(c) }
        if let tcs = d["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                let i = tc["index"] as? Int ?? 0
                var cur = calls[i] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                if let f = tc["function"] as? [String: Any] {
                    if let n = f["name"] as? String, !n.isEmpty {
                        let isNew = cur.name.isEmpty
                        cur.name += n
                        if isNew { emit(.toolCallStarted(id: cur.id, name: n)) }
                    }
                    if let a = f["arguments"] as? String { cur.args += a }
                }
                calls[i] = cur
            }
        }
    }

    /// A non-streamed JSON reply.
    func handleWhole(_ json: [String: Any]) throws {
        if let e = json["error"] as? [String: Any] { throw AIError.server(500, e["message"] as? String ?? "error") }
        if let u = json["usage"] as? [String: Any] { readUsage(u) }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else { return }
        stopReason = choice["finish_reason"] as? String ?? ""
        if let r = (msg["reasoning_content"] ?? msg["reasoning"]) as? String, !r.isEmpty { emit(.thinking(r)) }
        if let c = msg["content"] as? String { feedText(c) }
        if let tcs = msg["tool_calls"] as? [[String: Any]] {
            for (i, tc) in tcs.enumerated() {
                let f = tc["function"] as? [String: Any]
                calls[i] = (id: tc["id"] as? String ?? "call_\(i)", name: f?["name"] as? String ?? "",
                            args: f?["arguments"] as? String ?? "{}")
            }
        }
    }

    private func feedText(_ c: String) {
        splitter.feed(c, visible: { self.text += $0; self.emit(.text($0)) },
                      hiddenDelta: { tag, s in if tag != toolSpan.open { self.emit(.thinking(s)) } })
    }

    private func readUsage(_ u: [String: Any]) {
        let prompt = u["prompt_tokens"] as? Int ?? 0
        let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        usage.input = max(0, prompt - cached)
        usage.cacheRead = cached
        usage.output = u["completion_tokens"] as? Int ?? usage.output
    }

    func finish() {
        splitter.flush(visible: { self.text += $0; self.emit(.text($0)) })
        var blocks: [LLMBlock] = []
        let visible = textTools ? TextToolProtocol.strip(text) : text
        if !visible.isEmpty { blocks.append(.text(visible)) }
        var all: [LLMToolCall] = []
        for i in calls.keys.sorted() {
            guard let c = calls[i], !c.name.isEmpty else { continue }
            all.append(LLMToolCall(id: c.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : c.id, name: c.name,
                                   arguments: AnthropicStreamParser.validJSON(c.args)))
        }
        if textTools { all += TextToolProtocol.parse(splitter.hidden) }
        for c in all { blocks.append(.toolUse(c)); emit(.toolCall(c)) }
        emit(.message(LLMMessage(role: .assistant, blocks: blocks)))
        emit(.usage(usage.priced(model)))
        emit(.stop(stopReason == "tool_calls" ? "tool_use" : stopReason))
    }
}

// MARK: - Text tool protocol (models without native tools)

enum TextToolProtocol {
    static func instructions(_ tools: [LLMTool]) -> String {
        var s = """
        TOOLS: You can call tools. To call one, write a block exactly like this (JSON inside), then STOP and wait for the result:
        <tool_call>{"name": "TOOL_NAME", "arguments": {...}}</tool_call>
        You may make several calls in one reply. Results come back as <tool_result id="…">…</tool_result>. When you are finished, reply normally without any <tool_call>.
        Available tools:
        """
        for t in tools {
            let schema = (try? JSONSerialization.data(withJSONObject: t.schema, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            s += "\n- \(t.name): \(t.description)\n  arguments schema: \(schema)"
        }
        return s
    }

    static func render(_ c: LLMToolCall) -> String {
        "<tool_call>{\"name\": \"\(c.name)\", \"arguments\": \(c.arguments)}</tool_call>"
    }

    static func parse(_ hidden: [(tag: String, text: String)]) -> [LLMToolCall] {
        hidden.filter { $0.tag == "<tool_call>" }.compactMap { h in
            let t = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any],
                  let name = obj["name"] as? String else { return nil }
            let args = obj["arguments"] ?? obj["input"] ?? [String: Any]()
            let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
            return LLMToolCall(id: "call_" + UUID().uuidString.prefix(8).lowercased(), name: name,
                               arguments: String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    static func strip(_ text: String) -> String {
        var t = text
        while let o = t.range(of: "<tool_call>") {
            if let c = t.range(of: "</tool_call>", range: o.upperBound..<t.endIndex) { t.removeSubrange(o.lowerBound..<c.upperBound) }
            else { t.removeSubrange(o.lowerBound..<t.endIndex) }
        }
        return t
    }
}
