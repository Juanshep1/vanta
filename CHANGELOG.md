# Changelog

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
