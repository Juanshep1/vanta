import Foundation

struct AISettings: Codable, Equatable {
    var provider: String = "openrouter"   // openrouter | anthropic | ollama-cloud | nvidia
    var apiKey: String = ""               // the ACTIVE provider's key
    var model: String = "anthropic/claude-sonnet-4.6"
    var baseURL: String = ""               // optional override (local Ollama / proxy)
    var autocomplete: Bool = true
    // Each provider keeps its own key and last-used model, so switching
    // providers never sends one service's key to another.
    var keys: [String: String] = [:]
    var models: [String: String] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case provider, apiKey, model, baseURL, autocomplete, keys, models }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "openrouter"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "anthropic/claude-sonnet-4.6"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        autocomplete = try c.decodeIfPresent(Bool.self, forKey: .autocomplete) ?? true
        keys = try c.decodeIfPresent([String: String].self, forKey: .keys) ?? [:]
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        // Migrate a pre-existing single key to the per-provider store.
        if keys[provider] == nil, !apiKey.isEmpty { keys[provider] = apiKey }
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

enum AIClient {
    static func defaultBase(for provider: String) -> String {
        switch provider {
        case "anthropic": return "https://api.anthropic.com/v1"
        case "ollama-cloud": return "https://ollama.com/v1"
        case "nvidia": return "https://integrate.api.nvidia.com/v1"
        default: return "https://openrouter.ai/api/v1"
        }
    }

    static func defaultModel(for provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-sonnet-4-6"
        case "ollama-cloud": return "qwen3-coder:480b"
        case "nvidia": return "nvidia/llama-3.3-nemotron-super-49b-v1.5"
        default: return "anthropic/claude-sonnet-4.6"
        }
    }

    private static func base(_ s: AISettings) -> String {
        let b = s.baseURL.isEmpty ? defaultBase(for: s.provider) : s.baseURL
        return b.hasSuffix("/") ? String(b.dropLast()) : b
    }

    // A short, known-good starter list per provider, shown in the dropdown
    // before (or instead of) a live fetch. Press the refresh button to pull the
    // provider's full live catalog.
    static func curatedModels(for provider: String) -> [String] {
        switch provider {
        case "anthropic":
            return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case "ollama-cloud":
            return ["qwen3-coder:480b", "gpt-oss:120b", "deepseek-v3.1:671b"]
        case "nvidia":
            return ["nvidia/llama-3.3-nemotron-super-49b-v1.5", "meta/llama-3.3-70b-instruct"]
        default:
            return ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.8",
                    "openai/gpt-4o", "google/gemini-2.5-flash"]
        }
    }

    // Pull the provider's live model list (every provider here exposes a
    // GET /models endpoint). Returns the model ids, sorted.
    static func fetchModels(settings: AISettings) async throws -> [String] {
        guard let url = URL(string: base(settings) + "/models") else { throw AIError.message("bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if settings.provider == "anthropic" {
            req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !settings.apiKey.isEmpty {
            // OpenRouter's /models is public; only send auth when we have a key.
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? [String: Any], let m = err["message"] as? String {
            throw AIError.message(m)
        }
        if let arr = json?["data"] as? [[String: Any]] {
            let ids = arr.compactMap { $0["id"] as? String }
            if !ids.isEmpty { return ids.sorted() }
        }
        throw AIError.message("no models returned")
    }

    static func chat(system: String, history: [[String: String]], settings: AISettings, maxTokens: Int = 4096) async throws -> String {
        if settings.provider == "anthropic" {
            return try await anthropic(system: system, history: history, settings: settings, maxTokens: maxTokens)
        }
        return try await openAICompatible(system: system, history: history, settings: settings, maxTokens: maxTokens)
    }

    // Short single-shot completion for ghost-text autocomplete.
    static func complete(prefix: String, suffix: String, settings: AISettings) async throws -> String {
        let sys = "You are an autocomplete engine for the Vanta programming language. Given the code before and after the cursor, output ONLY the raw text to insert at the cursor — the natural continuation. No explanations, no markdown fences. Usually just finish the current line or add a couple of lines. Vanta uses plain-English syntax: say, let X be, change X to, if/otherwise/end, for each X in, to NAME(...)/give back/end, repeat N times/end."
        let user = "CODE BEFORE CURSOR:\n\(prefix)\n\nCODE AFTER CURSOR:\n\(suffix)\n\nText to insert at the cursor:"
        var out = try await chat(system: sys, history: [["role": "user", "content": user]], settings: settings, maxTokens: 90)
        out = stripFences(out)
        return out
    }

    // Reasoning models (qwen3, deepseek-r1, ...) may emit <think>...</think>
    // before the answer; drop it so code extraction sees only the reply.
    static func stripThinking(_ s: String) -> String {
        var t = s
        while let open = t.range(of: "<think>"),
              let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripFences(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "```") {
            t.removeSubrange(t.startIndex..<r.upperBound)
            if let firstNL = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNL)...]) }
            if let close = t.range(of: "```", options: .backwards) { t = String(t[..<close.lowerBound]) }
        }
        return t
    }

    private static func openAICompatible(system: String, history: [[String: String]], settings: AISettings, maxTokens: Int) async throws -> String {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages.append(contentsOf: history)
        let body: [String: Any] = ["model": settings.model, "max_tokens": maxTokens, "messages": messages]

        guard let url = URL(string: base(settings) + "/chat/completions") else { throw AIError.message("bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? [String: Any], let m = err["message"] as? String { throw AIError.message(m) }
        if let text = messageText(json) { return text }
        throw AIError.message("empty response")
    }

    // Pull the assistant's text out of an OpenAI-style reply, tolerating the
    // shapes capable/reasoning models actually use: content as a string, content
    // as an array of parts, or (for reasoning models like gpt-oss / deepseek)
    // the text sitting in a reasoning field when content came back empty.
    private static func messageText(_ json: [String: Any]?) -> String? {
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if let parts = msg["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return joined }
        }
        for key in ["reasoning_content", "reasoning"] {
            if let r = msg[key] as? String,
               !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return r
            }
        }
        return nil
    }

    private static func anthropic(system: String, history: [[String: String]], settings: AISettings, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": settings.model.isEmpty ? "claude-sonnet-4-6" : settings.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": history,
        ]
        guard let url = URL(string: base(settings) + "/messages") else { throw AIError.message("bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? [String: Any], let m = err["message"] as? String { throw AIError.message(m) }
        if let content = json?["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw AIError.message("empty response")
    }
}
