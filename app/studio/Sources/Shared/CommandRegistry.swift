import SwiftUI
import AppKit

// MARK: - Key shortcuts

/// A keyboard shortcut that can be shown in menus, matched against NSEvents
/// and rendered for the command palette ("⌘⇧P").
struct KeyShortcut: Hashable {
    struct Mods: OptionSet, Hashable {
        let rawValue: Int
        static let cmd = Mods(rawValue: 1)
        static let shift = Mods(rawValue: 2)
        static let opt = Mods(rawValue: 4)
        static let ctrl = Mods(rawValue: 8)
    }
    /// A single character ("p", "/", "\\", "]") or a named key:
    /// up down left right return tab escape delete space f1…f12.
    var key: String
    var mods: Mods

    init(_ key: String, _ mods: Mods = [.cmd]) { self.key = key.lowercased(); self.mods = mods }

    static func cmd(_ k: String) -> KeyShortcut { KeyShortcut(k, [.cmd]) }
    static func cmdShift(_ k: String) -> KeyShortcut { KeyShortcut(k, [.cmd, .shift]) }
    static func cmdOpt(_ k: String) -> KeyShortcut { KeyShortcut(k, [.cmd, .opt]) }
    static func ctrl(_ k: String) -> KeyShortcut { KeyShortcut(k, [.ctrl]) }
    static func opt(_ k: String) -> KeyShortcut { KeyShortcut(k, [.opt]) }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "delete": return .delete
        case "space": return .space
        default:
            if key.hasPrefix("f"), key.count > 1, let n = Int(key.dropFirst()), (1...20).contains(n),
               let scalar = UnicodeScalar(0xF703 + n) {          // NSF1FunctionKey = 0xF704
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let c = key.first else { return nil }
            return KeyEquivalent(c)
        }
    }

    var swiftUI: KeyboardShortcut? {
        guard let k = keyEquivalent else { return nil }
        var m: EventModifiers = []
        if mods.contains(.cmd) { m.insert(.command) }
        if mods.contains(.shift) { m.insert(.shift) }
        if mods.contains(.opt) { m.insert(.option) }
        if mods.contains(.ctrl) { m.insert(.control) }
        return KeyboardShortcut(k, modifiers: m)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: Mods = []
        if f.contains(.command) { m.insert(.cmd) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.opt) }
        if f.contains(.control) { m.insert(.ctrl) }
        guard m == mods else { return false }
        switch key {
        case "up": return event.keyCode == 126
        case "down": return event.keyCode == 125
        case "left": return event.keyCode == 123
        case "right": return event.keyCode == 124
        case "return": return event.keyCode == 36 || event.keyCode == 76
        case "tab": return event.keyCode == 48
        case "escape": return event.keyCode == 53
        case "delete": return event.keyCode == 51
        case "space": return event.keyCode == 49
        default:
            if key.hasPrefix("f"), key.count > 1, let n = Int(key.dropFirst()) {
                let fkeys: [Int: UInt16] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100,
                                            9: 101, 10: 109, 11: 103, 12: 111]
                return fkeys[n] == event.keyCode
            }
            // Compare ignoring shift/option transforms (⌘⇧] reports "}" in characters).
            let raw = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if raw == key { return true }
            if let chars = event.characters?.lowercased(), chars == key { return true }
            let shiftedPairs: [String: String] = ["{": "[", "}": "]", "|": "\\", "?": "/", "+": "=", "_": "-",
                                                  "<": ",", ">": ".", ":": ";", "\"": "'", "~": "`"]
            return shiftedPairs[raw] == key
        }
    }

    var display: String {
        var s = ""
        if mods.contains(.ctrl) { s += "⌃" }
        if mods.contains(.opt) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.cmd) { s += "⌘" }
        let names: [String: String] = ["up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩",
                                       "tab": "⇥", "escape": "⎋", "delete": "⌫", "space": "Space"]
        if let n = names[key] { s += n } else { s += key.uppercased() }
        return s
    }
}

// MARK: - Commands

/// Which menu a command lives in (and its palette category label).
struct CommandCategory: Hashable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ raw: String) { self.rawValue = raw }

    static let file = CommandCategory("File")
    static let edit = CommandCategory("Edit")
    static let selection = CommandCategory("Selection")
    static let view = CommandCategory("View")
    static let go = CommandCategory("Go")
    static let run = CommandCategory("Run")
    static let debug = CommandCategory("Debug")
    static let terminal = CommandCategory("Terminal")
    static let git = CommandCategory("Source Control")
    static let test = CommandCategory("Test")
    static let ai = CommandCategory("AI")
    static let help = CommandCategory("Help")
}

final class Command: Identifiable {
    let id: String
    var title: String
    var category: CommandCategory
    var shortcut: KeyShortcut?
    /// Show in the menu bar (under `category`'s menu). Palette always lists it
    /// unless `inPalette` is false.
    var inMenu: Bool
    var inPalette: Bool
    /// Menu ordering: commands are sorted by `group` then `order`; a divider is
    /// drawn between groups.
    var group: Int
    var order: Int
    /// When true the editor's text view handles this shortcut itself (before the
    /// menu bar sees it). Use for editing keys like ⌥↑ that NSTextView would
    /// otherwise swallow.
    var editorKey: Bool
    let action: () -> Void
    let isEnabled: () -> Bool

    init(id: String, title: String, category: CommandCategory, shortcut: KeyShortcut? = nil,
         inMenu: Bool = true, inPalette: Bool = true, group: Int = 0, order: Int = 0,
         editorKey: Bool = false, isEnabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.category = category; self.shortcut = shortcut
        self.inMenu = inMenu; self.inPalette = inPalette; self.group = group; self.order = order
        self.editorKey = editorKey; self.isEnabled = isEnabled; self.action = action
    }
}

/// Every menu item, shortcut and palette entry goes through here.
///
///     Services.shared.commands.register(id: "run.start", title: "Run Program",
///         category: .run, shortcut: .cmd("r")) { RunController.shared.run() }
///
/// Registering an id that already exists replaces it (so a Phase-2 module can
/// take over a placeholder command).
final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()
    @Published private(set) var all: [Command] = []
    private var byID: [String: Int] = [:]
    /// ids run most recently first (for the palette's "recently used").
    private(set) var recent: [String] = []

    func register(_ c: Command) {
        if let i = byID[c.id] { all[i] = c } else { byID[c.id] = all.count; all.append(c) }
    }

    @discardableResult
    func register(id: String, title: String, category: CommandCategory, shortcut: KeyShortcut? = nil,
                  inMenu: Bool = true, inPalette: Bool = true, group: Int = 0, order: Int = 0,
                  editorKey: Bool = false, isEnabled: @escaping () -> Bool = { true },
                  action: @escaping () -> Void) -> Command {
        let c = Command(id: id, title: title, category: category, shortcut: shortcut, inMenu: inMenu,
                        inPalette: inPalette, group: group, order: order, editorKey: editorKey,
                        isEnabled: isEnabled, action: action)
        register(c)
        return c
    }

    func command(_ id: String) -> Command? { byID[id].map { all[$0] } }

    func run(_ id: String) {
        guard let c = command(id), c.isEnabled() else { NSSound.beep(); return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 30 { recent.removeLast() }
        c.action()
    }

    /// The command (if any) whose shortcut matches this key event.
    func command(matching event: NSEvent, editorKeysOnly: Bool = false) -> Command? {
        all.first { ($0.editorKey || !editorKeysOnly) && $0.shortcut?.matches(event) == true }
    }

    func menuCommands(_ cat: CommandCategory) -> [[Command]] {
        let items = all.filter { $0.category == cat && $0.inMenu }
            .sorted { ($0.group, $0.order) < ($1.group, $1.order) }
        var groups: [[Command]] = []
        var lastGroup: Int?
        for c in items {
            if c.group != lastGroup { groups.append([]); lastGroup = c.group }
            groups[groups.count - 1].append(c)
        }
        return groups
    }
}
