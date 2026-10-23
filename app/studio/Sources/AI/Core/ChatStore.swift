import Foundation
import Combine

/// A piece of context that went into a request (shown as a chip under the message).
struct ContextRef: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case file, folder, selection, problems, console, book, docs, code, activeFile }
    var id: String { kind.rawValue + ":" + label }
    var kind: Kind
    var label: String
    var path: String? = nil
    var line: Int? = nil

    var icon: String {
        switch kind {
        case .file, .activeFile: return "doc.text"
        case .folder: return "folder"
        case .selection: return "selection.pin.in.out"
        case .problems: return "exclamationmark.triangle"
        case .console: return "terminal"
        case .book: return "book"
        case .docs: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Context the user attached explicitly (⌘L selection, "Explain this code").
struct ChatAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String          // "calc.va:3–9"
    var path: String?
    var text: String
    var startLine: Int = 0
}

struct ToolStep: Codable, Hashable {
    enum Status: String, Codable { case running, done, failed, waiting, denied }
    var callID: String
    var name: String
    var arguments: String
    var result: String = ""
    var status: Status = .running
    var durationMs: Int = 0
}

struct ChatItem: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, tool, notice }
    var id = UUID()
    var role: Role
    var text: String = ""
    var thinking: String = ""
    var refs: [ContextRef] = []
    var attachments: [ChatAttachment] = []
    var tool: ToolStep? = nil
    var usage: LLMUsage? = nil
    var isError = false
    /// For user items: index of their message in `Conversation.transcript` (edit & resend truncates here).
    var transcriptIndex: Int? = nil
    /// For user items in agent mode: the checkpoint taken before the turn.
    var checkpointID: UUID? = nil
    var date = Date()
    /// Agent mode this item was produced in ("chat" | "agent" | "book").
    var mode: String = "chat"
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "New chat"
    var created = Date()
    var updated = Date()
    var items: [ChatItem] = []
    /// The exact provider-neutral history sent to the model (append-only → cache-friendly).
    var transcript: [LLMMessage] = []
    var usage = LLMUsage()
    var titled = false

    static func == (a: Conversation, b: Conversation) -> Bool { a.id == b.id && a.updated == b.updated && a.items.count == b.items.count }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Chat history: several conversations, saved per workspace in
/// ~/Library/Application Support/Vanta Studio/AI/.
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    private var workspaceKey = "global"
    private var saveWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    var persist = true

    var current: Conversation {
        get { conversations.first { $0.id == currentID } ?? conversations.first ?? Conversation() }
    }

    func start() {
        persist = !Services.shared.isSnapshot
        Services.shared.workspace.$root
            .removeDuplicates()
            .sink { [weak self] root in self?.switchWorkspace(root) }
            .store(in: &bag)
    }

    func switchWorkspace(_ root: URL?) {
        if persist { saveNow() }
        workspaceKey = root.map { Self.hash($0.standardizedFileURL.path) } ?? "global"
        conversations = persist ? load() : []
        if conversations.isEmpty { conversations = [Conversation()] }
        currentID = conversations.sorted { $0.updated > $1.updated }.first?.id
    }

    /// Mutate the current conversation in place.
    func update(_ body: (inout Conversation) -> Void) {
        if conversations.isEmpty { conversations = [Conversation()] }
        guard let i = conversations.firstIndex(where: { $0.id == currentID }) ?? conversations.indices.first else { return }
        body(&conversations[i])
        conversations[i].updated = Date()
        scheduleSave()
    }

    func update(id: UUID, _ body: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[i])
        conversations[i].updated = Date()
        scheduleSave()
    }

    @discardableResult
    func newConversation() -> UUID {
        if let cur = conversations.first(where: { $0.id == currentID }), cur.items.isEmpty { return cur.id }
        let c = Conversation()
        conversations.insert(c, at: 0)
        currentID = c.id
        scheduleSave()
        return c.id
    }

    func select(_ id: UUID) { currentID = id }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id: id) { $0.title = t; $0.titled = true }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if currentID == id { currentID = conversations.sorted { $0.updated > $1.updated }.first?.id }
        scheduleSave()
    }

    var sorted: [Conversation] { conversations.sorted { $0.updated > $1.updated } }

    // MARK: persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vanta Studio/AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats-\(workspaceKey).json")
    }

    private func load() -> [Conversation] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Conversation].self, from: d)) ?? []
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    func saveNow() {
        guard persist else { return }
        let keep = conversations.filter { !$0.items.isEmpty }.sorted { $0.updated > $1.updated }.prefix(60)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Array(keep)) { try? d.write(to: fileURL, options: .atomic) }
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
