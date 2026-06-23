# Changelog

## 4.7 — images: download, binary serving, and HTML→PNG/PDF
Vanta can now handle real binary/image work end-to-end, so apps like a card maker can
fetch AI art, save it, render designs, and serve them:
- **`download(url, dest [, headers])`** — binary-safe fetch (writes raw bytes to a file,
  no text decoding) for images / PDFs / any binary.
- **`base64_to_bytes(s)` / `bytes_to_base64(list)`** — binary base64 (e.g. decode a
  base64 PNG to bytes, or build a `data:` URI).
- **`serve()` can return binary** — a handler may give back `{"file": "/path.png",
  "type": "image/png"}` to stream a file straight off disk (add `"download": yes` for an
  attachment), or `{"bytes": [...], "type": ...}` for a raw byte body. Text/JSON replies
  are unchanged.
- **`render_html(input, out [, width, height [, mode]])`** — rasterizes an HTML file/URL
  with headless Chrome: `"png"` → a screenshot at width×height, `"pdf"` → a printed PDF.

## 4.6 — open_url works on phones
`open_url(...)` now opens pages on **Android (Termux)** and **iPhone (iSH)**, not just
desktops. On Termux it uses `termux-open-url` / `termux-open` (install `termux-api` for
auto-open); everywhere it also **prints the address** so it's tappable if no launcher
exists. Combined with `serve()` — which is pure Python sockets and already runs
on-device — you can now build a web app on your phone and open it in the phone's
browser straight from the terminal. Desktop behavior is unchanged (still honors
`$BROWSER`, e.g. a chromeless app window).

## 4.5 — triple-quoted strings (write HTML the easy way)
The biggest day-to-day pain in Vanta was building a web page: you had to glue an
HTML string together line-by-line (`change html to html + "..."`) and double every
literal `{`/`}` as `{{`/`}}` so it wouldn't be read as interpolation. Now there's a
better way, borrowed from Python:

- **`"""..."""` triple-quoted strings.** They span multiple lines and are **raw** —
  braces are literal (no `{{`/`}}`), so you paste CSS/JS exactly as written:

  ```
  let page be """<!doctype html><html><head><style>
  body { margin:0; color:#0a84ff }
  .card { border-radius:12px }
  </style></head><body>
    <h1>hello</h1>
  </body></html>"""
  write_file("app.html", page)
  ```

  For dynamic values, just close the block and concatenate:
  `"""<h1>""" + title + """</h1>"""`. Regular single-line `"...{name}..."` strings
  still interpolate exactly as before (and still use `{{`/`}}` for literal braces),
  so every existing program keeps working.
- Implemented as a source pre-pass (`expand_triple_strings`) that collapses a block
  into a single-line literal while preserving line numbers for error messages; the
  rest of the line-based pipeline is unchanged. String splitting is now escape-aware.
- Reminder of what Vanta already had (and people forget): **`#` comments** (whole-line
  or trailing) and **`{expr}` string interpolation**.

## 4.2 — a real compiler (3.2× faster again)
Vanta no longer re-reads the syntax tree every time it runs a line. It now
**compiles each program once into nested Python closures** — every operator,
variable, and call is resolved at compile time, so the per-line "what does this
mean?" cost (the biggest tax of the old tree-walker) is gone.

- On the benchmark (`fib(27)` + a 300k loop), wall-clock went from **7.1s →
  2.2s** — about **3.2× faster than where this started**, ~1.6× faster than 4.1.
- How: a `compile_expr`/`compile_stmt`/`compile_block` pass builds the closures;
  `Function` caches its compiled body. The common operations are specialised at
  compile time — number `+ - *`, comparisons, and variable lookups are inlined
  rather than dispatched.
- **Control flow no longer raises exceptions on the hot path.** `give back`,
  `stop`, and `skip` used to raise a Python exception every time (every single
  function call raised one); they now travel as lightweight return signals that
  blocks and loops pass upward. Verified against nested-loop returns,
  break/continue, and `return` inside `attempt`.
- Behaviour is unchanged — the same 34-check suite passes. The old tree-walker
  stays as the engine for a few rare statements, so nothing lost coverage.

Still honest: this is the practical ceiling for interpreting Vanta in Python —
~3× is what compiling-to-closures buys. A further large jump (toward 10×) would
mean translating Vanta to Python/machine code or a C core, which is a separate,
much bigger project, not more tuning. For I/O work (servers, scripts, APIs) none
of this was ever the bottleneck anyway.

## 4.1 — faster, and servers that handle real traffic
- **~1.7× faster interpreter.** A focused pass on the hottest code paths (no
  behaviour change — all 34 tests still pass). On the benchmark (`fib(27)` plus
  a 300k-iteration loop) wall-clock dropped from **7.1s to ~4.3s**. What changed:
  - The expression and statement dispatchers now check the most common node
    types first (`arith`, `cmp`, `call`, `index`, `if`, `return`, `assign`)
    instead of walking a long `if/elif` chain every time.
  - A fast path for number math and comparisons skips the `isinstance` churn for
    the common case of two plain numbers.
  - Function calls got cheaper: no per-call error-label string, parameters are
    written straight into the new scope, and a call frame no longer allocates an
    empty set for constants until something is actually `fix`ed.
  - `tools/benchmark.py` makes the number reproducible.
- **Web servers now handle concurrent connections.** `serve` uses a threading
  server, so one slow client (or a browser's parallel connections) no longer
  blocks everything. The Vanta handler still runs under a lock — the interpreter
  shares one global scope, so your request code runs one-at-a-time and never
  races. Verified with 20 simultaneous requests in the test run.

Honest note: this is a tree-walking interpreter, so it's still slower per
operation than C/Rust/V8. ~1.7× is what surgical tuning buys; a big further jump
would mean compiling to bytecode (a much larger project), not micro-tuning.

## 4.0 — Vanta goes full-stack (the web)
Vanta can now build the things Python, JavaScript, or Go can — real web
servers and API clients, not just console scripts. New builtins:
- **`serve(port, handler)`** — run a real HTTP server. The handler is an
  ordinary Vanta function that takes a request map
  (`{"method","path","query","headers","body"}`) and gives back either an HTML
  string or a map `{"status","body","type","headers"}`. Return a map/list as
  the body and it's sent as JSON automatically. You route by checking
  `req["path"]`. Runs until you stop it.
- **`http_get`, `http_post`, `http_request`** — call any API/URL. You get back
  `{"status","body","headers"}`; pass a map/list body and it's sent as JSON.
- **`url_encode` / `url_decode`**, **`html_escape`** (escape user input before
  putting it in a page), and **`sleep(seconds)`**.
- In **Vanta Studio** (native app), Vee now knows all of this — ask it (or
  Agent mode) to "build a web page" or "make a JSON API" and press Run; the
  built-in console shows the `http://localhost:…` address. Agent mode treats a
  server that stays up as success instead of waiting forever.
- The interpreter version string is now `4.0` (it had lagged at `3.3`).
- The native app's sidebar drops the bundled "Examples" list — every Vanta
  feature works out of the box, so you start from a clean file.

Tested end to end: a Vanta web server serving HTML + JSON, hit by Vanta's own
`http_get` (`tools/server_headless.py`, in the test suite — now 34 checks).

## 3.9 — Vanta Studio goes Cursor-style
- **⌘K inline edit** — select code (or just put the cursor on a line), press ⌘K,
  describe the change in plain English, and Vee rewrites just that snippet. You
  get a real line-by-line diff to **Accept (⏎)** or **Reject (Esc)** before
  anything touches your file.
- **Agent mode** — toggle "Agent" in the Vee panel and give it a goal. Vee writes
  a complete program, **runs it natively**, reads the output, and if it hits an
  error it fixes itself and runs again — looping (up to 4 rounds) until the code
  runs clean. This is the native app's superpower: it actually executes Vanta, so
  the AI can close the write→run→fix loop on its own.
- **AI tab-autocomplete** — ghost-text suggestions appear as you type at the end
  of a line; press **Tab** to accept, Esc to dismiss. Toggle it in AI Settings.

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
