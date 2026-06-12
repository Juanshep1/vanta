# Changelog

## 3.8 — native macOS app
- **Vanta Studio.app** (`app/studio/`) — a real native macOS IDE in SwiftUI +
  AppKit (not a webview). Native code editor with Vanta syntax highlighting and
  a line-number gutter; **runs Vanta natively via python3** (fast, real files,
  streamed console, interactive `ask` input); file tabs/sidebar/open/save and
  bundled examples; menus + shortcuts (Cmd-R/Cmd-S/…). Includes **Vee**, a
  native AI panel (URLSession, so no browser CORS) supporting OpenRouter,
  Anthropic, Ollama Cloud, and NVIDIA, with one-click Apply of generated code.
  Build with XcodeGen (`cd app/studio && xcodegen generate`).

## 3.7.1
- Vanta Studio: Vee gained two more providers — **Ollama Cloud** and
  **NVIDIA NIM** (OpenAI-compatible), with a live **Ollama Cloud model picker**
  (bundled list + live refresh) and an editable **Base URL** (for local Ollama
  or a CORS proxy). Note: those two providers send no CORS headers, so direct
  browser calls are blocked unless you point Base URL at a local endpoint/proxy.

## 3.7 — Vanta Studio
- **Vanta Studio** (`ide/`) — a full browser IDE: multi-file projects with
  tabs and a file tree, Vanta syntax highlighting, console + canvas panes,
  templates, export/import, and a one-page cheatsheet
- **A canvas game API** provided by the Studio host: `canvas` `clear` `color`
  `rect` `circle` `line` `text_at` `key_down` `mouse_x` `mouse_y` `mouse_down`
  `stop_game`, plus an `on_frame()` game loop at 30 fps — Snake, Paint, and
  bouncing-ball demos ship as templates, all written in Vanta
- **Vee, an AI assistant** built into the Studio — bring your own **Claude or
  OpenRouter** key (OpenRouter lets you pick any model: GPT, Gemini, Llama,
  Claude). Vee knows the whole Vanta language and applies generated files
  straight into your project; a useful offline mode works without a key
- `reset_runtime()` host API in the interpreter so IDEs/REPLs can re-run
  programs cleanly
- Template smoke tests (`tools/ide_headless.py`) wired into the test suite

## 3.6
- Anonymous functions: `make x give x * 2`
- Proper lexical closures — a function (named or anonymous) captures the scope
  it was defined in, so you can build counters, multipliers, and the like
- Slice syntax: `list[1:3]`, `text[2:]`, `xs[:2]`, `xs[-2:]`
- Constants: `fix limit be 100` (can't be reassigned)
- New math builtins: `sin` `cos` `tan` `log` `exp` `sum` `product`
- A `random` library module: `shuffle` `choice` `sample` `roll` `chance`
- `math` library additions: `to_radians` `to_degrees` `hypotenuse`

## 3.5
- Inline conditional expression: `"big" if n is over 100 otherwise "small"`
- A `match` / `when` statement for testing a value against several cases
- Membership operators: `x is in collection`, `x is not in collection`
- Negative indexing: `list[-1]` is the last item
- `*` repeats text and lists: `"ab" * 3`, `[0] * 4`
- Two-name loops: `for each key, value in map` (and `index, item` over lists/text)
- `increase X by N` / `decrease X by N`

## 3.4
- A **browser playground** (`playground/`) — run Vanta and play the emulator in
  the browser via Pyodide; hostable on GitHub Pages
- A **CHIP-8 emulator written entirely in Vanta** (`emulator/chip8.va`) that
  loads and runs real `.ch8` ROMs, with opcode unit tests and an IBM-logo
  golden-image test (`tools/chip8_headless.py`)
- A **macOS app** (`app/macos/`) — a thin Swift WKWebView shell around the
  playground
- A **Game Boy CPU foundation** (`gameboy/cpu.va`) — registers, flags, cartridge
  header parsing, and an opcode subset (work in progress; not playable)
- New builtins: `read_bytes`; bitwise `band` `bor` `bxor` `bnot` `shift_left`
  `shift_right`; `chr` / `code`; and a `call_vanta` host bridge

## 3.3
- A `vanta` command-line tool: `vanta run`, `vanta repl`, `vanta version`,
  `vanta help` (plus `vanta program.va` and the old `python3 vanta.py`)
- A module search path: `import "name"` finds the bundled library in `lib/`
  and installed packages in `~/.vanta/packages/`; modules load at most once
- A standard library written in Vanta: `text`, `lists`, and `math` modules

## 3.2
- `super` calls so an overriding method can reach the parent's version
- Multiple assignment and swapping (`let a, b be [1, 2]`, `change a, b to b, a`)
- Map comprehensions (`{ n: n * n for each n in nums }`)

## 3.1
- Type inheritance with `type Child from Parent`, method override, and the
  `is a` / `is an` type check (plus an `is_a` builtin)
- List comprehensions: `[n * n for each n in nums if n is over 2]`
- Regular expressions: `matches`, `find_all`, `replace_all`
- Date and time helpers: `today`, `clock`
- Math constants `pi` and `e`

## 3.0
- User-defined types with fields (`has`), methods (`to`), the `me` reference,
  a `setup` constructor, and a `show` method for printing
- Error handling with `attempt` / `rescue`, plus `fail` and `assert`
- First-class functions: builtins and user functions are values you can pass
- Higher-order functions: `map`, `keep`, `reduce`, `each`, `count_where`,
  `find_where`, `sort_by`
- Default arguments (`to greet(who, greeting be "Hi")`)
- String interpolation (`"hi {name}"`), with `{{` / `}}` for literal braces
- Nested assignment (`change data["user"]["scores"][0] to 99`)
- Power operator `^`, plus `sqrt`, `power`, `pad_left`, `pad_right`, `values`,
  `push`, `pop`, and the `type_of` / `is_*` inspection helpers
- Inline comments (a `#` after code on the same line)
- An automated test suite (`tests/` + `run_tests.py`)

## 2.0
- Functions with parameters, return values (`give back`), and recursion
- Lists and maps, with indexing, `for each`, and in-place updates
- Logical operators (`and`, `or`, `not`) and `otherwise if` chains
- Modules via `import`
- File access (`read_file`, `write_file`) and shell commands (`run`, `shell`)
- JSON (`to_json`, `from_json`) and directory helpers
- Command-line `arguments()` and environment access via `env`
- String escapes (`\n`, `\t`, `\"`, `\\`)
- A much larger standard library (text, number, and list helpers)
- Interactive REPL

## 1.0
- First version: variables, math (words or symbols), `if`/`otherwise`,
  `repeat` and `while` loops, input, comments, and friendly error messages.
