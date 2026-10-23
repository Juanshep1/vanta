# Changelog

## 6.0

### Core language (interpreter and native builds alike; see docs/LANGUAGE_GUIDE.md, Page 6)
- **Module namespaces:** `import "geometry" as geo` then `geo.area(3)`, `new geo.Circle(2)`,
  `type Ball from geo.Circle`; `from "geometry" use area, Circle`. `private to helper()`,
  `private let x be ...` (also `fix`, `type`, `kind`) stay inside the module. Plain `import "x"` is
  unchanged (shares the global scope). Imports also find a file next to the importing file (after the
  usual places).
- **Kinds (enums):** `kind Color is red, green, blue` (or a block ending in `end`); `Color.red` prints
  as `red`, has `.name` and `.index`, compares by order, works in `when`, maps, sets, `is a Color`,
  and `for each c in Color`.
- **Generators:** `yield` inside a function makes it a generator — lazy in `for each`,
  comprehensions, `next(g)`, `next(g, fallback)`, `list(g)`. A type with `to each()` can be looped over.
  Native builds compile generators to resumable state machines (all state lives in the collected heap).
- **Operator methods:** `add subtract multiply divide remainder negate equals less_than index
  set_index length contains text` (or `show`) and `each` give your types `+ - * / % -x is < > <= >=
  [] length() in text() say for each`, and make `sort`, `min`, `max` work on them.
- **Sets:** `set([1, 2])`, `set()`, `add x to s`, `remove x from s`, `x is in s`, `union`,
  `intersection`, `difference`, `is_subset`, `is_set`, `length`, `for each`; list builtins (`sum`,
  `sort`, `max`, `join`, `map`, ...) accept sets. `remove x from` also works on lists and maps.
- **Patterns in `when`:** `[first, rest...]`, `[0, y]`, `{"name": n}`, `a Circle with radius`,
  `a number` / `a text` / ..., `_`, and guards: `when [x, y] if x > y`.
- **`using r be open_thing() ... end`** closes `r` (its `close()` method) however the block ends.
- **Optional type notes:** `to area(r: number) -> number`, `let name: text be ...`, `has age: number`;
  ignored when running; **`vanta check`** (vanta_tools/checker.py) reports undefined names (with
  suggestions), wrong argument counts/names, changing fixed names, missing module names, unknown kind
  values, and type mismatches against the notes.
- **Type-level members:** `shared to origin()` → `Point.origin()`; `shared count be 0` → `Point.count`
  (changeable, inherited). Inheritance chains, `super` and `is a` behave the same natively.
- **Big whole numbers natively:** overflowing 64 bits now promotes to an exact big number
  (`factorial(25)`, `2 ^ 100`, `1 << 70`) instead of a float, exactly like the interpreter.
- **Calls:** named values `greet(name: "Ana")` (also for constructors: `new Dog(name: "Rex", sound:
  "Woof")`), and collecting the rest: `to total(numbers...)`. Trailing commas allowed.
- **Formatting:** `"{price:.2}"`, `"{name:<10}"`, `"{n:,}"`, `"{x:08.3}"`, `"{255:x}"`, `"{r:.1%}"`,
  `"{v:e}"`, and `format(value, spec)`. Braces that don't hold an expression stay as text (JSON).
- **Smaller additions:** `//` (whole-number division) and `mod`; `1e3`, `2.5e-4`; chained comparisons
  `1 is under x is under 10`; lines continue after an open bracket, a trailing operator or comma;
  comprehensions over two names `{k: v for each k, v in m}`; `range(start, stop, step)`;
  `split(text, "")`; `merge(m)`; `say(x)` usable as a function; exact `/` for big whole numbers.
- **Fixes:** `let` over a `fix`ed name is an error; `increase`/`decrease` need numbers; `plus`,
  `minus`, `xor`, `true`, `false` (and `Yes/No/True/False/Nothing`) are reserved; `ask` at the end of
  input is a catchable error; an unknown escape like `"\d"` keeps its backslash; yes/no and 1/0 are
  different map keys and set items; recursion 10,000+ deep works, and runaway recursion is a catchable
  error with a line number (both runtimes); "the list is empty"; `'greet' takes 1 value, but got 2`;
  a missing `end` names the line where the block starts; top-level `give back` is an error.

### Tooling — the `vanta` command (see docs/TOOLS.md)
- **One clean command line:** `vanta run | repl | debug | build | test | check | fmt | doc | new | get |
  lsp | version | help [COMMAND]`, with detailed `vanta help COMMAND` pages and "did you mean" for
  mistyped commands. `vanta program.va`, `python3 vanta.py program.va` and plain `vanta` still work.
  `vanta.bat` falls back to `py -3`, then `python`, when `python3` isn't available.
- **Test blocks:** `test "adds numbers"` ... `end` with `expect A is B`, `is not`, any comparison,
  `contains`, `fails`, `fails with "text"`, or a plain condition; failures show the check and both
  values. `vanta test [paths] [--native] [-v] [--filter TEXT]` runs them with counts and timings
  (`--native` compiles the tests with the native compiler); `vanta run` skips them.
- **Formatter:** `vanta fmt [--check] [--diff]` — 4-space indentation, operator/comma/bracket spacing,
  blank lines around definitions, comments and strings kept; idempotent, and it proves the formatted
  program is the same program before writing.
- **Docs:** `vanta doc file.va [--html] [-o OUT]` turns `##` comments above functions, types, kinds and
  constants into Markdown or HTML.
- **Projects and packages:** `vanta new NAME [--cli|--game|--web|--os]` scaffolds a project with a
  `vanta.json` manifest; `vanta get SOURCE[@VERSION]` installs git/GitHub/local/index packages into
  `./packages` (or `~/.vanta/packages`), pins git tags, and writes `vanta.lock`; `vanta get` installs
  everything in `vanta.json`. `import "NAME"` finds project packages (interpreter and native builds).
- **REPL:** history and line editing, multi-line blocks until `end`, expression values shown,
  `:help :load :vars :doc :reset :quit`, tab completion.
- **Debugger:** `vanta debug file.va` — `break N`, `step`, `next`, `finish`, `continue`, `print EXPR`,
  `vars`, `where`, `list`.
- **Friendlier errors:** file and line, the source line with a caret under the problem, hints ("did you
  mean 'total'?", ranked: your names, then common words, then the rest), and the Vanta call stack.
- **Editor support:** `vanta lsp` (diagnostics, completion, hover docs, go-to-definition, outline,
  formatting), a VS Code extension in `editors/vscode`, a Pygments lexer (`tools/vanta_lexer.py`) and a
  highlight.js grammar (`tools/highlight-vanta.js`).

### Bare metal — write an operating system in Vanta (see docs/KERNEL.md)
- **`vantac.py kernel.va --kernel -o out/kernel.elf [--arch x86|arm64] [--iso out/os.iso]`** compiles a
  Vanta program into a kernel that boots with no operating system underneath:
  `qemu-system-x86_64 -kernel out/kernel.elf`. The whole language works (closures, types, lists, maps,
  `attempt`/`rescue`, the garbage collector); builtins that need an OS (disk files, processes, networking,
  ...) are refused at compile time, naming each one.
- **Freestanding runtime** (`native/runtime/kernel/`): Multiboot header and 32→64-bit boot code, GDT/IDT,
  PIC, a 1000 Hz PIT timer, PS/2 keyboard, COM1 serial, VGA text mode with colors and cursor, Bochs/QEMU
  framebuffer graphics with a built-in 8×16 font, the real-time clock, a physical page allocator and heap,
  and a small libc (exact `printf` of decimals, `strtod`, x87-accurate math, `setjmp`/`longjmp`).
- **Kernel builtins:** screen (`clear_screen`, `print_at`, `set_color`, `set_cursor`, `keep_top_rows`, ...),
  keyboard (`read_key`, `poll_key`, `key_pressed`; `ask` has line editing and history), time (`ticks`,
  `uptime`, `sleep_ms`, `every`, `stop_timer`), interrupts (`on_interrupt(irq, fn)` — Vanta handlers run
  deferred at the next safe point, so they're ordinary functions), hardware (`port_in8/16/32`,
  `port_out8/16/32`, `peek8/16/32`, `poke8/16/32` — a bad address is a catchable error), system (`halt`,
  `reboot`, `power_off`, `memory_info`, `system_info`, `beep`), graphics (`graphics_mode`, `put_pixel`,
  `fill_rect`, `draw_line`, `fill_circle`, `draw_text`, `double_buffer`, ...) and a ram file system
  (`write_to_file`, `read_from_file`, `list_files`, `delete_file`, ...).
- **`--iso`** makes a hybrid CD/USB image with Limine that boots on BIOS (text mode) and UEFI (framebuffer)
  PCs. **`--arch arm64`** targets QEMU's `virt` board (PL011 serial console, generic timer).
- **Examples:** `examples/os/hello_kernel.va` (the book's first OS chapter) and `examples/os/vantaos.va` — a
  colorful banner, a status bar, and a shell with `help`, `ls`/`cat`/`write`/`rm`, `mem`, `uptime`, `date`,
  `calc`, `color`, `snake`, `tasks` (cooperative multitasking on the timer), `gfx`, `reboot`, `halt`.
- **`tools/kernel_headless.py`** boots both in QEMU with no window, types through the QEMU monitor and checks
  the serial output (part of `run_tests.py`; skipped if QEMU or the LLVM tools are missing).

### Batteries included — concurrency, networking, system, data (see docs/STDLIB.md, docs/LANGUAGE_GUIDE.md Page 7)
Every function below works in the interpreter **and** in native builds; `vantac` links only the runtime pieces a
program uses (`vrt_thread.c`, `vrt_net.c`, `vrt_http.c` + libcurl, `vrt_sys.c`, `vrt_data.c`, `vrt_regex.c`,
`vrt_zlib.c` + zlib, `vrt_sqlite.c` + SQLite).
- **Tasks and channels:** `let t be start fetch(url)` / `spawn(fn, args...)`, `wait for t` / `wait(t, [timeout])`
  (also a list of tasks, or a process), `is_done(t)`; `channel([capacity])`, `send x to ch`, `receive from ch` /
  `receive(ch, [timeout])`, `close(ch)`; waiting on a channel when nothing else runs is an error, not a hang.
  `lock` / `lock guard` blocks (re-entrant, released on errors and early exits) with `new_lock()`.
  `run_parallel(fn, items, [workers])` uses worker processes for CPU work on every core.
  Native builds use real threads with a global lock that is released while a thread sleeps or waits on I/O, a
  process, a channel, a lock or a task, and handed over every ~2 ms at safepoints; each parked thread's GC roots
  are saved and marked, so the collector stays precise. Programs that never start a task pay nothing.
- **Networking:** `tcp_connect(host, port, [timeout])`, `tcp_listen(port, [host])`, `accept(server, [timeout])`,
  `set_timeout`, `socket_info`, `udp_open`, `udp_send`, `udp_receive`, `dns_lookup`; generic `send`, `receive`,
  `receive_bytes`, `read_line`, `read_all`, `write_to`, `close` work on sockets, files, processes, channels.
  **WebSockets:** `ws_connect("ws://...")` and `"WS /path"` routes.
- **HTTP server with routes:** `serve(port, {"GET /users/:id": show, "POST /items": add, "GET /static/*": "public"})`
  — path parameters, wildcard, static folders (no `..`), and a richer request (`params`, `json`, `form`, `client`);
  `start_server(port, handler)` runs it in the background (`server_port`, `stop_server`); `json_response`,
  `redirect`. The server and the HTTP client (`http_get`, `http_post`, `http_request`, `download`, via libcurl) are
  now native too.
- **System:** `run_process(cmd, {input, dir, env, timeout})` → `{output, error, code}` (text runs in the shell, a list
  runs the program directly); `open_process` for streaming (`write_to`, `read_line`, `read_all`, `close_input`,
  `process_errors`, `wait`, `kill_process`, `process_id`); `set_env`, `env_vars`, `env(name, [fallback])`,
  `on_signal`, `send_signal`, `exit`; file handles `open_file(path, [mode])`, `read_chunk`, `read_chunk_bytes`,
  `seek`, `tell` (they work with `using`); `walk_dir`, `glob` (with `**`), `matches_pattern`, `temp_file`,
  `temp_dir`, `absolute_path`, `current_dir`, `change_dir`. `run`, `shell`, `path_join`, `dirname`, `basename`,
  `extname`, `home_dir`, `copy_path`, `move_path`, `file_mtime`, `today`, `my_pid` are native now.
- **Data:** `csv_parse`, `csv_format`, `csv_read`, `csv_write`, `csv_read_maps`, `csv_write_maps`;
  `to_json(value, indent)`; dates with time zones — `format_date`/`parse_date` take a zone, `date_parts`,
  `make_date`, `days`/`hours`/`minutes`, `format_duration`, `timezone`; regular expressions natively (a
  backtracking engine with Python `re` semantics: groups, lazy quantifiers, lookaround, backrefs, named groups,
  inline flags) plus `regex_search`, `regex_split`, `regex_escape`; `compress`/`decompress` (zlib), `gzip`/
  `gunzip`, `bytes_to_text`; `sha1`, `hmac`, `uuid` (and native `md5`, `sha256`, base64, hex, url and html
  helpers); `random_seed` — the interpreter now uses the same xorshift generator as native builds, so seeded
  runs print the same numbers; `gcd`, `lcm`, `factorial`, `isqrt`, `mean`, `median`, `mode`, `variance`,
  `stdev`; SQLite: `db_open`, `db_query` (rows as maps, `?` or `:name` parameters), `db_execute`, `db_last_id`.
- **Modules in `lib/`:** `collections` (Stack, Queue, Deque, Heap, PriorityQueue, `count_items`, `group_by`),
  `strings` (wrap, center, truncate, dedent, slugify, snake/kebab/camel case, fill_template, ...), `cli`
  (`parse_args`, `arg_usage`), `log` (leveled, timestamped, to a file, task-safe).
- **docs/STDLIB.md:** a reference of every builtin — signature, one-line description, example, and whether it
  works in native builds.
- **Native parity fixes:** `read_file` turns `\r\n` into `\n` like the interpreter; `env(name)` gives `""` when
  unset (was nothing); `ask` and `sleep` let other tasks run. Interpreter fixes: `replace_all` with an unknown
  group name is a Vanta error, not a crash. Tests: `tests/concurrency.va`, `net.va` (localhost only),
  `system.va`, `data.va`, `sqlite.va`, `regex.va`, `json_random.va`, `libs.va`.

### Graphics, games and apps — the canvas (see docs/GRAPHICS.md)
A complete 2D API for games and desktop apps, next to the GBA-style video chip (which is unchanged):
`native/runtime/vcanvas.c` (software-rendered, so it draws identically with or without a window) plus the
public-domain/MIT stb libraries vendored in `native/runtime/stb/` (PNG/JPG/BMP/GIF loading and saving, TrueType
fonts, Ogg Vorbis), compiled once into `~/.cache/vanta`.
- **Window and loop:** `window(w, h, [title], [options])` (resizable, scaled to fit, high-DPI, F11 / Alt+Enter full
  screen; options `pixel_art`, `follow` (canvas = window size, for apps), `scale`, `fullscreen`, `resizable`,
  `hidpi`). Define `on_frame()` — or `update(dt)` and `draw()` — and they run at a steady 60 fps after the
  top-level code (the compiler adds the loop); `next_frame()` for your own loop, `run_game`, `stop_game`,
  `frame_rate`, `fps`, `frame_count`, `delta_time`, `game_time`, `screen_width`/`height`, `window_title`,
  `fullscreen`, `screenshot` (PNG/BMP/JPG/TGA).
- **Drawing:** colours by CSS name, `#rgb[a]`/`#rrggbb[aa]`, lists or `rgb`/`rgba`/`hsv`/`mix_color`/`with_alpha`;
  `clear`, `color`, `rect`/`fill_rect`, `outline_rect`, `round_rect`, `circle`, `ellipse`, `line`, `polyline`,
  `triangle`, `polygon`, `arc`, `pie` (+ `outline_` versions), `pixel`, `get_pixel` — antialiased, with alpha
  blending, `line_width`, `antialias`; `clip`/`no_clip`; `camera(x, y, [zoom])`, `camera_center`, `no_camera`,
  `mouse_world_x/y`.
- **Text:** a built-in 8x8 pixel font (sizes 8, 16, 24...) and TrueType fonts (`load_font(path)` or
  `font("sans" | "serif" | "mono" | "bold")` for a system font): `draw_text` (top-left), `text_at` (baseline,
  like Vanta Studio), `text_width`, `text_height`, `text_align`, multi-line text.
- **Images:** `load_image`, `make_image`, `image_from_rows` (pixel art written as text with a palette),
  `draw_image` with scale/size/rotation/origin/flip/alpha/tint/region (rotated images smoothed unless
  `pixel_art`), `sprite_sheet` + `draw_frame`, `draw_tilemap` (lists or text grids, only visible tiles drawn),
  off-screen drawing with `draw_to(image)`/`draw_to_screen()`, `copy_screen`, `save_image`, `image_pixel`.
- **Input:** `key_down`/`key_pressed`/`key_released`/`key_repeated` by name, `last_key`, `text_input`; mouse
  position, buttons (`mouse_down/pressed/released`), wheel, `show_mouse`; game controllers (`pad_down`,
  `pad_pressed`, `pad_axis`, up to 4 players); touch (`touches`, `touch_x/y`) with an on-screen D-pad + 2 buttons
  on iPhone/iPad that act as the arrow keys, space and enter (`touch_controls`), `show_keyboard`.
- **Sound:** a 32-voice mixer: `load_sound` (WAV, OGG), `play_sound(sound, volume, pan, pitch, loop)`,
  `stop_sound`, `play_music` (looping), volumes, `make_tone` / `beep` (sine, square, triangle, saw, noise),
  `make_sound` from samples.
- **Headless and testing:** `VANTA_HEADLESS=1` never opens a window or sound device; `VANTA_FRAMES`,
  `VANTA_SHOT` / `VANTA_SHOT_FRAME` / `VANTA_SHOT_EVERY` screenshots (PNG), scripted input with `VANTA_INPUT`
  (`"10 press space; 20 click 100 200; 30 type hi"`) or `test_input(...)` from Vanta, `VANTA_SOUND_DUMP=out.wav`,
  `VANTA_DENSITY=2`. `tools/canvas_headless.py` (in `run_tests.py`) checks the API pixel by pixel
  (`tests/canvas/api_check.va`), every example, and the GBA mode.
- **`vanta run` on a canvas program** builds it natively and runs it (with a one-line note); canvas programs also
  build for iPhone/iPad with `--ios`. `vanta check` knows the canvas builtins.
- **`lib/game.va`:** `Vec` vectors, `Rect` and collisions (`overlap`, `rects_overlap`, `circles_overlap`,
  `circle_rect_overlap`, `hit_side`), `Body` physics (`apply_gravity`, `move_and_collide` with `on_ground`),
  `lerp`/`approach`/`wrap`/`smooth_follow`, easing + `tween`, `timer`, `animation`, scenes (`add_scene`,
  `go_to_scene`), random helpers, `particles`.
- **`lib/gui.va`:** immediate-mode widgets drawn on the canvas — `button`, `accent_button`, `label`, `checkbox`,
  `slider`, `text_field` (+ `submitted`, `focus`), `list_box`, `progress_bar`, `panel`, `separator` — with
  `layout`/`row`/`cell` grids, dark and light themes, and `"text##id"` labels.
- **Examples (`examples/games/`):** `pong`, `snake` (also runs in Vanta Studio), `platformer` (pixel art and
  tiles drawn in code, physics, camera, parallax, enemies, particles), `breakout`, `paint`, `calculator` and
  `todo` (gui apps), `showcase` (the whole drawing API).

## 5.2 (in progress) — features the Emerald port needed
- **`when` with several values** — `when 2, 3, 5` matches any of them (like several `case`s sharing a body).
- **Faster native builds with many constants** — `fix NAME be <whole number>` at the top of a module is
  compiled straight into each use, so programs with thousands of constants build in seconds.
- **Big programs build in parallel** — a large program's C is split into pieces compiled on every core at
  once, and unchanged pieces are reused: the 40-module Emerald build went from ~2 minutes to ~18 s
  (4 s when nothing changed).
- **iPhone/iPad builds** — `vantac.py game.va --ios -o Game.app [--name N] [--bundle-id ID] [--resources dirs]
  [--icon png]` compiles a game for iOS, links SDL2 for iOS, writes and signs the app bundle (development
  identity + provisioning profile). On a phone the game fills the screen with on-screen controls (D-pad,
  A/B, L/R, Start/Select; multi-touch, slide across the D-pad), a paired game controller works too, the
  app's Documents folder shows in the Files app for data files, and it adopts the UIScene lifecycle that
  iOS 26+ requires. `VANTA_TOUCH=1` shows the on-screen controls on a computer.
- **`list_dir`, `make_dir`, `remove_path`** now work in native builds too.
- **Errors name the file** — a native runtime error in an imported module says which `.va` file it's in.
- **All-caps `TRUE`/`FALSE`** are ordinary names now (so ported C code can define them as 1/0);
  `yes`/`no`/`true`/`false` (lowercase or Capitalized) are still the booleans.
- **Fix:** native programs that don't use the game runtime link again (the game builtins register
  themselves at startup instead of relying on a weak symbol, which macOS's linker rejected).

## 5.1 — native builds + bits and bytes (the game-framework groundwork)
Vanta programs can now be compiled into real native executables:

- **`vanta build program.va`** — compiles the program to C and builds a native binary
  (`native/vantac.py` + the C runtime in `native/runtime/`). It uses the interpreter's own parser,
  so it accepts exactly the same language: functions, closures, types with inheritance and `super`,
  `attempt`/`rescue`, `match`, comprehensions, `import`. Output and error messages match the
  interpreter's — `python3 native/test_native.py` checks every test and example both ways.
  About 70× faster than the interpreter on the benchmark (fib(27) + a 300k loop: 2.2 s → 0.03 s).
  Web, process and memory-editing builtins are interpreter-only for now; the compiler names any it meets.
- **Number literals** — `0xFF`, `0b1010`, `0o17`, and digit separators: `1_000_000`, `0xFF_FF`.
- **Bit operators** — `&`, `|`, `xor`, `<<`, `>>` and `~`, with C-like precedence (shifts, then `&`,
  then `xor`, then `|`, all looser than `+ -` and tighter than comparisons). `^` is still power.
- **`bytes`** — a compact byte array for game data and file formats: `bytes(n)`, `bytes([1, 2])`,
  `bytes("text")`, `read_binary(path)`, `write_binary(path, b)`, indexing/slicing/`for each`, and
  little-endian readers/writers `u8 s8 u16 s16 u32 s32`, `put_u8 put_u16 put_u32`.

## 5.0 — stdlib completeness + Vanta Pocket (the iOS IDE)
The everyday helpers that were missing are now built in — no more writing
`unique` yourself:

- **lists** — `unique`, `zip`, `flatten`, `index_of`, `last_index_of`,
  `insert_at`, `shuffle`, `pick` (random element), `chunk(xs, n)`,
  `any_where(fn, xs)`, `all_where(fn, xs)`, and `sort(xs, "desc")`.
- **maps** — `get(m, key, fallback)`, `has_key`, `remove_key`, `merge`,
  `entries` (a map as `[[key, value], ...]`).
- **text** — `repeat_text`, `title_case`, `capitalize`,
  `format_number(n, digits)` with thousands separators.
- **numbers** — `clamp(x, low, high)`, `sign`, `round(x, digits)`,
  `asin`, `acos`, `atan`, `atan2`, `random_float()`.
- **dates** — `format_date(stamp, pattern)` and `parse_date(text, pattern)`
  (strftime-style patterns; both have sensible defaults).

And the headline: **[Vanta Pocket](app/ios/)** — a native iOS IDE for Vanta,
built with SwiftUI. Multi-file projects, a syntax-highlighted editor with a
Vanta keyboard toolbar, a console that supports `ask`, examples, and offline
execution (the WebAssembly build of Vanta runs on the phone — no server, no
Python). It also ships **vcode**, the Vanta coding agent, as a chat panel:
add your Anthropic or OpenRouter key and it writes projects right on your phone.

## 4.9 — input & global hotkeys (on/off keys for your trainers)
Trainers can now have toggle keys like the Python ones. New builtins:
- **`on_hotkey(key, fn)`** — run a function every time a key is pressed, even while
  the game has focus (returns an id; `clear_hotkey(id)` to stop). e.g.
  `on_hotkey("f1", toggle_health)`.
- **`key_pressed(key)`** — is a key held right now · **`wait_key(key)`** — block until pressed.
- **`press_key(key)`**, **`key_down`/`key_up`** (hold), **`type_text(text)`**.
- **`mouse_move(x,y)`**, **`mouse_click(["right"])`**, **`mouse_pos()`** → `{x,y}`.

Cross-platform: macOS (CoreGraphics), Windows (user32), Linux (xdotool). On macOS,
grant your terminal **Accessibility / Input-Monitoring** permission the first time
(System Settings → Privacy). Updated `examples/trainer.va` shows the F1-toggle pattern.

## 4.8 — game cheats: read & write another program's memory
You can now write game trainers in Vanta as easily as a pymem script or Cheat
Engine — find a value in a running game's memory, then change or freeze it. Pure
stdlib, cross-platform (macOS via mach, Linux via `/proc/<pid>/mem`, Windows via
`ReadProcessMemory`).

```
let pid be find_pid("MyGame")        # find the game
let hits be mem_scan(pid, 100)       # all addresses holding 100 (your health)
change hits to mem_next(pid, hits, 80)   # narrow as it changes, until one is left
write_int(pid, hits[0], 999)         # set health to 999
freeze(pid, hits[0], 999)            # ...or lock it forever (infinite health)
```

New builtins: `process_list()`, `find_pid(name)`, `my_pid()`, `read_int`/`write_int`,
`read_float`/`write_float`, `read_mem`/`write_mem` (raw bytes), `mem_regions`,
`mem_scan(pid, value [, "float"])`, `mem_next` (the Cheat-Engine narrow-down),
`freeze`/`unfreeze`. See `examples/trainer.va`.

Editing your **own** process works freely (great for learning/testing — `my_pid()`).
Editing **another** program needs privileges (`sudo` / Administrator), and on macOS
System Integrity Protection may block it. For single-player / offline games — online
games run anti-cheat and editing them breaks their terms of service.

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
