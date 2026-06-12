import Foundation

struct AISettings: Codable, Equatable {
    var provider: String = "openrouter"   // openrouter | anthropic | ollama-cloud | nvidia
    var apiKey: String = ""
    var model: String = "anthropic/claude-sonnet-4.6"
    var baseURL: String = ""               // optional override (local Ollama / proxy)
    var autocomplete: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey { case provider, apiKey, model, baseURL, autocomplete }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "openrouter"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "anthropic/claude-sonnet-4.6"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        autocomplete = try c.decodeIfPresent(Bool.self, forKey: .autocomplete) ?? true
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
        if let choices = json?["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String { return content }
        throw AIError.message("empty response")
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
