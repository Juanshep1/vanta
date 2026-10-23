# Vanta Studio 2 — Architecture

The contract for everyone extending the app. **Rule: each Phase-2 module only
adds/edits files in its own folder.** Every module already has a `register(_:)`
function that `App/Modules.swift` calls once at launch — put your registrations
there; you never need to touch another folder.

| Folder | Owner | Registration function |
|---|---|---|
| `App/` | shell | `Modules.registerAll`, `Bootstrap`, menus, `--snapshot` |
| `Shared/` | shell | contracts only (protocols, registries, theme, settings) |
| `Workspace/` | shell | `Document`, `DocumentStore`, `Workspace`, `ProjectSearch` |
| `Editor/` | shell | `EditorModule.register` (`Editor/EditorModule.swift`) |
| `Shell/` | shell | `ShellModule.register` (`Shell/ShellModule.swift`) |
| `Language/` | **Language agent** | `LanguageModule.register` (`Language/LanguageModule.swift`) |
| `Run/` | **Run agent** | `RunModule.register` (`Run/RunController.swift` — split into more files freely) |
| `AI/` | **AI agent** | `AIModule.register` (`AI/AIModule.swift`) |

Registration order: Shell → Editor → Language → Run → AI. Registering an id
that already exists **replaces** it, so a later module can take over anything.

## Services (`Shared/Services.swift`)

`Services.shared` (also passed to `register(_:)`) holds everything:

```swift
s.workspace        // Workspace: root URL, file tree, fileIndex, gitBranch, filesChanged publisher
s.documents        // DocumentStore: open documents, save/saveAs/saveAll, autosave, external changes
s.editors          // EditorGroups: groups/tabs, open(url) / open(location:), split, activePane
s.editor           // EditorController? — the focused editor (nil if none)
s.activeEditorChanged  // PassthroughSubject<EditorController?, Never>
s.layout           // LayoutState: showSidebar(id), showBottom(id), auxVisible, openQuickPick(">")
s.settings         // StudioSettings (Editor/Appearance/Run prefs, persisted)
s.commands  s.panels  s.statusBar  s.language  s.diagnostics  s.breakpoints
s.register(obj) / s.resolve(Type.self)   // share your module's singletons
s.flash("Saved")                          // transient status-bar message
s.isSnapshot                               // true under --snapshot: don't prompt/persist
```

All APIs are main-thread. Positions are **0-based** line / UTF-16 column
(`TextPosition`, `TextRange`) exactly like LSP; offsets are UTF-16 indices.

## Commands (`Shared/CommandRegistry.swift`)

Every menu item, shortcut and palette entry is a `Command`.

```swift
s.commands.register(id: "run.debug", title: "Start Debugging", category: .debug,
                    shortcut: KeyShortcut("f5", []), group: 0, order: 0,
                    isEnabled: { s.editor != nil }) { DebugController.shared.start() }
```

- `category` picks the menu: File, Edit, Selection, View(+Source Control), Go,
  Run(+Debug, Test, Terminal), AI, Help. `group` = divider sections, `order` within.
- `inMenu: false` / `inPalette: false` to hide. `editorKey: true` makes the text
  view handle the shortcut itself before NSTextView eats it (needed for ⌥-arrows etc.).
- `s.commands.run(id)` runs a command (also how buttons should trigger things).
- Taken shortcuts: ⌘N ⌘O ⌘S ⌘⇧S ⌘⌥S ⌘W ⌘P ⌘⇧P ⌘B ⌘J ⌘L ⌘I ⌘\ ⌘1 ⌘2 ⌘⇧[ ⌘⇧] ⌘⇧E
  ⌘⇧F ⌘⇧H ⌘⇧M ⌘⇧Y ⌃G ⌘⇧O ⌘F ⌘⌥F ⌘G ⌘⇧G ⌘E ⌘/ ⌘] ⌘[ ⌥⇧F ⌘⌥[ ⌘⌥] ⌘⌥⇧[ ⌘⌥⇧] ⌃Space
  ⌥↑ ⌥↓ ⌘⇧D ⌘D ⌘⇧L ⌘⌥↑ ⌘⌥↓ F12 ⌥Z ⌘= ⌘- ⌘0 ⌘R ⌘. ⌘K.

## Panels (`Shared/PanelRegistry.swift`)

```swift
s.panels.register(id: PanelID.terminal, title: "Terminal", icon: "terminal",
                  location: .bottom, order: 10) { TerminalView() }
```

- `location`: `.sidebar` (activity bar item + left sidebar), `.bottom` (panel
  tab), `.auxiliary` (right panel; first one wins — the AI panel).
- `badge: { "3" }` shows a count on the activity-bar icon / panel tab.
- Well-known ids in `PanelID` — **re-register the same id to replace a Phase-1 placeholder**:
  - Run agent: `PanelID.terminal`, `.debugConsole`, `.sourceControl`, `.runDebug` (and `.console` if you rebuild it)
  - Language agent: `PanelID.tests`, `.testResults`, optionally `.problems`
  - AI agent: `PanelID.ai`
- `registerOverlay(id:)` — a floating view over the editor area (the ⌘K prompt).
- `registerToolbarItem(id:)` — a control in the title row (Run/Stop). Ids
  starting with `console.` appear in the Console panel header instead ("Fix with Vee").
- `registerSettingsSection(id:title:icon:order:)` — a tab in the Settings window (AI uses this).
- Sidebar views should start with `SidebarHeader("Title") { IconButton(...) }`;
  empty states use `PlaceholderPanel`. Colours come from `Theme` (dynamic dark/light).

## Status bar

```swift
s.statusBar.register(id: "status.git", alignment: .left, priority: 100) { GitStatus() }
```
Existing ids: left `status.git` (branch from .git/HEAD), `status.problems`,
`status.run`; right `status.cursor`, `status.language`, `status.ai`. Use
`StatusLabel(icon:text:help:action:)` for consistent styling.

## Language features (`Shared/LanguageProviders.swift`)

```swift
s.language.symbolProvider = MyLSPSymbols()               // single slot (outline, ⌘⇧O, go-to-def fallback)
s.language.formattingProvider = VantaFmt()               // single slot (⌥⇧F "Format Document")
s.language.register(completion: LSPCompletion())         // combined with others
s.language.removeCompletionProvider(id: "keywords")      // drop Phase-1 default if you supersede it
s.language.register(hover: LSPHover())
s.language.register(definition: LSPDefinition())         // ⌘-click / F12
s.language.inlineCompletionProvider = ...                // AI ghost text (AI owns this slot)
```

Protocols: `CompletionProvider` (`triggerCharacters`, `completions(ctx, prefix:)`
async), `HoverProvider`, `SymbolProvider`, `DefinitionProvider`,
`FormattingProvider`, `InlineCompletionProvider`. All get a `DocumentContext`
(uri, text snapshot, languageID, offset, position). Phase 1 defaults (in
`Language/`): `RegexSymbolProvider` (id `regex-symbols`) and
`KeywordCompletionProvider` (id `keywords`).

**Diagnostics** — publish per (uri, source); the editor squiggles, gutter icons,
hover text, Problems panel and status counts all update automatically:

```swift
s.diagnostics.publish([Diagnostic(range: r, severity: .error, message: "…", source: "vanta check")],
                      for: doc.uri, source: "vanta check")
s.diagnostics.clear(source: "vanta check")
```

## Documents & the editor

- `Document` (`Workspace/Document.swift`): one per open file; owns the shared
  `NSTextStorage`, `undoManager`, `lines` (`LineIndex`), highlighter, `uri`
  (file URL or `untitled:` URL), `isDirty`, `changes` publisher (`TextChange`),
  `blocks` (Vanta `to…end` structure), `save()`, `reloadFromDisk()`.
- `EditorController` (`Shared/EditorController.swift`, implemented by
  `Editor/EditorPane.swift`) — the API for the focused editor:
  `text`, `url`, `selections` get/set (multi-cursor), `selectedText`,
  `cursorPosition`, `offset(of:)`/`position(of:)`, `replace(_:with:)` and
  `replace(edits:)` (one undo step), `insertAtCursor`, `setText` (minimal diff,
  undoable), `scrollToLine(_:select:)`, `reveal`, `visibleLines`, `focus()`,
  `setDiagnostics`, `setGhostText(_:at:)` (Tab accepts, Esc dismisses),
  `showInlineDiff(range:newText:onAccept:onReject:)` / `dismissInlineDiff()` /
  `hasInlineDiff` (⌘↩ accept, Esc reject), `highlightLine(_:)` (debugger),
  `breakpoints` (also `BreakpointStore.shared`, published per uri; lines shift
  with edits), `textChanges`, `selectionChanges`.
- Open things: `s.editors.open(url)`, `s.editors.open(location: Location(uri:range:))`,
  `s.editors.open(document:)`; `s.documents.newUntitled(text:name:)`.
- Split views of one file share the storage/undo; each pane has its own layout
  manager (own selection, scroll, folds).

## Run (Phase 1 state, for the Run agent)

`RunController.shared` (`Run/RunController.swift`): `run()`, `stop()`,
`sendInput`, `console`, `isRunning`, `lastRunFailed`, and
`runAndCapture(code, streaming:timeout:)` (used by the AI agent loop).
`PythonRunner` runs `python3 Resources/runtime/vanta.py file.va [args]` with the
file's folder as cwd. Debugger: read `BreakpointStore.shared`, drive
`s.editor?.highlightLine(_:)`, open frames with `s.editors.open(location:)`.

## AI (Phase 1 state, for the AI agent)

`VeeAssistant.shared` (`AI/VeeAssistant.swift`) is Studio 1's logic ported
onto these APIs: chat, ⌘K (`beginInlineEdit` → prompt overlay → `showInlineDiff`),
agent build-run-fix, Fix with Vee, ghost text (it is the
`inlineCompletionProvider`). `AIClient`, `AISystemPrompt`, `LineDiff` are unchanged.

## Testing without showing windows

```bash
APP=".../Vanta Studio.app/Contents/MacOS/Vanta Studio"
"$APP" --snapshot out.png [--workspace DIR] [--open FILE]… [--size 1440x900]
       [--appearance dark|light] [--line N] [--run COMMAND_ID]…
       [--demo decorations|fold|diff|find|completion|multicursor]… [--settings]
"$APP" --bench big.va      # load/highlight/keystroke timings
```
The window is never ordered on screen; nothing is persisted. Add your own
`--demo` cases in `App/SnapshotRunner.swift` only if you own App/ — otherwise use
`--run <your command id>` to put your UI into the state you want to see.
