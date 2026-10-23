import Foundation

// MARK: - Settings

/// Vee's preferences. API keys are NOT stored here — they live in the Keychain
/// (`KeyStore`), one per provider.
struct AISettings: Codable, Equatable {
    var provider: String = "anthropic"          // anthropic | openrouter | ollama-cloud | nvidia
    var smartModel: String = "claude-sonnet-5-5" // chat, agent, ⌘K, Fix with Vee
    var fastModel: String = "claude-haiku-5-5"   // Tab autocomplete
    var baseURL: String = ""                     // optional override (proxy / local Ollama / any OpenAI-compatible server)
    var autocomplete: Bool = true
    var autocompleteDelayMs: Int = 300
    var agentAutoApply: Bool = false
    var agentStepLimit: Int = 30
    var useBookKnowledge: Bool = true            // retrieve Vanta Book chunks into every request
    var indexCodebase: Bool = true               // retrieve workspace code into chat / agent
    var nextEditPrediction: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case provider, smartModel, fastModel, baseURL, autocomplete, autocompleteDelayMs, agentAutoApply,
             agentStepLimit, useBookKnowledge, indexCodebase, nextEditPrediction
        case legacyModel = "model", legacyKey = "apiKey"
    }

    /// The API key found in a Studio 1/Phase-1 settings blob (migrated to the Keychain once).
    var legacyAPIKey: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        let legacyModel = try c.decodeIfPresent(String.self, forKey: .legacyModel)
        smartModel = try c.decodeIfPresent(String.self, forKey: .smartModel) ?? legacyModel ?? AIProvider.defaultSmartModel(provider)
        fastModel = try c.decodeIfPresent(String.self, forKey: .fastModel) ?? AIProvider.defaultFastModel(provider)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        autocomplete = try c.decodeIfPresent(Bool.self, forKey: .autocomplete) ?? true
        autocompleteDelayMs = try c.decodeIfPresent(Int.self, forKey: .autocompleteDelayMs) ?? d.autocompleteDelayMs
        agentAutoApply = try c.decodeIfPresent(Bool.self, forKey: .agentAutoApply) ?? false
        agentStepLimit = try c.decodeIfPresent(Int.self, forKey: .agentStepLimit) ?? d.agentStepLimit
        useBookKnowledge = try c.decodeIfPresent(Bool.self, forKey: .useBookKnowledge) ?? true
        indexCodebase = try c.decodeIfPresent(Bool.self, forKey: .indexCodebase) ?? true
        nextEditPrediction = try c.decodeIfPresent(Bool.self, forKey: .nextEditPrediction) ?? true
        if let k = try c.decodeIfPresent(String.self, forKey: .legacyKey), !k.isEmpty { legacyAPIKey = k }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(smartModel, forKey: .smartModel)
        try c.encode(fastModel, forKey: .fastModel)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(autocomplete, forKey: .autocomplete)
        try c.encode(autocompleteDelayMs, forKey: .autocompleteDelayMs)
        try c.encode(agentAutoApply, forKey: .agentAutoApply)
        try c.encode(agentStepLimit, forKey: .agentStepLimit)
        try c.encode(useBookKnowledge, forKey: .useBookKnowledge)
        try c.encode(indexCodebase, forKey: .indexCodebase)
        try c.encode(nextEditPrediction, forKey: .nextEditPrediction)
    }

    static func == (a: AISettings, b: AISettings) -> Bool {
        a.provider == b.provider && a.smartModel == b.smartModel && a.fastModel == b.fastModel && a.baseURL == b.baseURL
            && a.autocomplete == b.autocomplete && a.autocompleteDelayMs == b.autocompleteDelayMs
            && a.agentAutoApply == b.agentAutoApply && a.agentStepLimit == b.agentStepLimit
            && a.useBookKnowledge == b.useBookKnowledge && a.indexCodebase == b.indexCodebase
            && a.nextEditPrediction == b.nextEditPrediction
    }
}

// MARK: - Providers

enum AIProvider {
    static let all: [(id: String, name: String)] = [
        ("anthropic", "Anthropic (Claude)"),
        ("openrouter", "OpenRouter (any model)"),
        ("ollama-cloud", "Ollama Cloud"),
        ("nvidia", "NVIDIA NIM"),
    ]

    static func name(_ id: String) -> String {
        if id == "mock" { return "Mock (offline)" }
        return all.first { $0.id == id }?.name ?? id
    }

    static func defaultBase(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "https://api.anthropic.com/v1"
        case "ollama-cloud": return "https://ollama.com/v1"
        case "nvidia": return "https://integrate.api.nvidia.com/v1"
        default: return "https://openrouter.ai/api/v1"
        }
    }

    static func defaultSmartModel(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-sonnet-5-5"
        case "ollama-cloud": return "qwen3-coder:480b"
        case "nvidia": return "qwen/qwen3-coder-480b-a35b-instruct"
        default: return "anthropic/claude-sonnet-5.5"
        }
    }

    static func defaultFastModel(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "claude-haiku-5-5"
        case "ollama-cloud": return "gpt-oss:20b"
        case "nvidia": return "meta/llama-3.3-70b-instruct"
        default: return "anthropic/claude-haiku-5.5"
        }
    }

    /// A short, known-good starter list per provider (the refresh button pulls the live catalog).
    static func curatedModels(_ provider: String) -> [String] {
        switch provider {
        case "anthropic":
            return ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        case "ollama-cloud":
            return ["qwen3-coder:480b", "gpt-oss:120b", "gpt-oss:20b", "deepseek-v3.1:671b"]
        case "nvidia":
            return ["qwen/qwen3-coder-480b-a35b-instruct", "meta/llama-3.3-70b-instruct",
                    "nvidia/llama-3.3-nemotron-super-49b-v1.5"]
        default:
            return ["anthropic/claude-sonnet-5.5", "anthropic/claude-opus-5.5", "anthropic/claude-haiku-5.5",
                    "openai/gpt-5", "google/gemini-2.5-pro", "qwen/qwen3-coder"]
        }
    }

    static func keyHelp(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "Key from console.anthropic.com → API Keys."
        case "ollama-cloud": return "Key from ollama.com/settings/keys."
        case "nvidia": return "Key from build.nvidia.com (free tier available)."
        default: return "Key from openrouter.ai/keys — any model slug from openrouter.ai/models."
        }
    }

    static func isAnthropicFormat(_ provider: String) -> Bool { provider == "anthropic" }
}

// MARK: - Pricing (USD per million tokens)

struct ModelPrice { let input: Double; let output: Double; let cacheRead: Double; let cacheWrite: Double }

enum Pricing {
    static func price(for model: String) -> ModelPrice? {
        let m = model.lowercased().replacingOccurrences(of: ".", with: "-")
        func p(_ i: Double, _ o: Double, read: Double? = nil) -> ModelPrice {
            ModelPrice(input: i, output: o, cacheRead: read ?? i * 0.1, cacheWrite: i * 1.25)
        }
        if m.contains("fable") || m.contains("mythos") { return p(10, 50, read: 0.25) }
        if m.contains("opus-5-5") { return p(4, 20, read: 0.20) }
        if m.contains("opus-5") || m.contains("opus-4-8") || m.contains("opus-4-7") || m.contains("opus-4-6") { return p(5, 25) }
        if m.contains("sonnet-5") { return p(2, 10, read: 0.20) }
        if m.contains("sonnet-4") { return p(3, 15) }
        if m.contains("haiku-5") { return p(0.10, 0.50, read: 0.01) }
        if m.contains("haiku-4") { return p(1, 5) }
        return nil
    }
}

struct LLMUsage: Codable, Hashable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost: Double = 0          // USD, 0 when the model's price is unknown

    var total: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ u: LLMUsage) {
        input += u.input; output += u.output; cacheRead += u.cacheRead; cacheWrite += u.cacheWrite; cost += u.cost
    }

    func priced(_ model: String) -> LLMUsage {
        var u = self
        if let p = Pricing.price(for: model) {
            u.cost = (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.cacheRead
                      + Double(cacheWrite) * p.cacheWrite) / 1_000_000
        }
        return u
    }

    var summary: String {
        let tok = Self.short(input + cacheRead + cacheWrite) + " in · " + Self.short(output) + " out"
        let cache = cacheRead > 0 ? " · \(Int(Double(cacheRead) / Double(max(1, input + cacheRead + cacheWrite)) * 100))% cached" : ""
        return tok + cache + (cost > 0 ? String(format: " · $%.4f", cost) : "")
    }

    static func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Conversation wire types (provider-neutral)

struct LLMToolCall: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var arguments: String           // JSON object text

    var args: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    }
}

enum LLMBlock: Codable, Equatable {
    case text(String)
    case thinking(text: String, signature: String)
    case redactedThinking(String)
    case toolUse(LLMToolCall)
    case toolResult(id: String, content: String, isError: Bool)
}

struct LLMMessage: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var blocks: [LLMBlock]

    static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, blocks: [.text(text)]) }
    static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: .assistant, blocks: [.text(text)]) }

    var text: String {
        blocks.compactMap { if case let .text(t) = $0 { return t }; return nil }.joined()
    }
    var toolCalls: [LLMToolCall] {
        blocks.compactMap { if case let .toolUse(c) = $0 { return c }; return nil }
    }
}

struct LLMTool {
    let name: String
    let description: String
    /// JSON Schema for the input object.
    let schema: [String: Any]
}

/// One part of the system prompt. `cache` marks an Anthropic prompt-cache breakpoint.
struct SystemPart {
    var text: String
    var cache: Bool = false
}

enum LLMPurpose { case chat, agent, edit, completion, utility }

struct LLMRequest {
    var model: String
    var system: [SystemPart]
    var messages: [LLMMessage]
    var tools: [LLMTool] = []
    var maxTokens: Int = 8192
    var purpose: LLMPurpose = .chat
    /// Anthropic: also put a cache breakpoint on the last message (multi-turn chat / agent loops).
    var cacheConversation: Bool = false
    var stop: [String] = []
}

enum LLMEvent {
    case text(String)
    case thinking(String)
    /// A tool call has started streaming (name known, arguments still arriving).
    case toolCallStarted(id: String, name: String)
    case toolCall(LLMToolCall)
    /// The assistant turn exactly as it must be replayed (thinking signatures etc.).
    case message(LLMMessage)
    case usage(LLMUsage)
    case stop(String)
    /// Informational (e.g. "rate limited — retrying in 4s").
    case status(String)
}

struct LLMResponse {
    var text: String = ""
    var thinking: String = ""
    var toolCalls: [LLMToolCall] = []
    var message: LLMMessage?
    var usage = LLMUsage()
    var stopReason = ""
}

enum AIError: LocalizedError, Equatable {
    case noKey
    case badKey(String)
    case rateLimited(String)
    case overloaded(String)
    case server(Int, String)
    case network(String)
    case toolsUnsupported(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add an API key in Settings › AI so Vee can think."
        case let .badKey(m): return "The API key was rejected — check it in Settings › AI. (\(m))"
        case let .rateLimited(m): return "Rate limited by the provider — wait a moment and try again. (\(m))"
        case let .overloaded(m): return "The provider is overloaded right now — try again shortly. (\(m))"
        case let .server(code, m): return "Provider error \(code): \(m)"
        case let .network(m): return "Network problem: \(m)"
        case let .toolsUnsupported(m): return "This model doesn't support tools: \(m)"
        case let .message(m): return m
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case let .server(code, _): return code >= 500
        default: return false
        }
    }
}
