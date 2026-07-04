<p align="center">
  <img src="assets/logo.png" alt="Vanta" width="170">
</p>

<h1 align="center">Vanta</h1>

<p align="center">A small programming language that reads like plain English.</p>

---

Vanta is a programming language I built from scratch to answer a simple question:
how close can code get to ordinary English and still be a real, general-purpose
language? The whole thing is a single Python file (`vanta.py`) — a tokenizer, a
parser, and a tree-walking interpreter — and you can read the entire language in
an afternoon.

It started as a toy. It isn't one anymore. Vanta has functions with default
arguments and recursion, first-class and higher-order functions, user-defined
types with inheritance, error handling, lists and maps, list comprehensions,
string interpolation, regular expressions, file and system access, modules, an
interactive REPL, and a standard library of around seventy functions. There's a
test suite in `tests/`. If you can write it in a scripting language, you can
mostly write it in Vanta.

Here's what it looks like:

```
let name be "Juan"
let age be 25

if age is at least 18
    say name + " can vote."
otherwise
    say name + " is too young."
end

to factorial(n)
    if n is at most 1
        give back 1
    end
    give back n * factorial(n minus 1)
end

say "5! = " + factorial(5)
```

```
$ python3 vanta.py hello.va
Juan can vote.
5! = 120
```

No semicolons, no curly braces, no `console.log`. You comment a block with `end`
instead of guessing about indentation. `>=` is spelled `is at least` if you
want it to be (the symbols still work too).

## Getting started

You need Python 3.8+ and nothing else — no packages to install.

```bash
git clone https://github.com/Juanshep1/vanta.git
cd vanta
./vanta run examples/hello.va     # run a program
./vanta repl                      # start the interactive REPL
./vanta version                   # 5.0
```

`./vanta program.va` works too, and so does `python3 vanta.py program.va` if you
don't want to use the launcher. Put the `vanta` directory on your `PATH` and you
can just type `vanta` anywhere (`vanta.bat` is there for Windows).

## Vanta Studio — the IDE

[**Vanta Studio**](ide/) is a full IDE for Vanta that runs in your browser:
multi-file projects, syntax highlighting, a console, and a **canvas with a game
API** (`rect`, `circle`, `key_down`, an `on_frame()` loop at 30 fps) so you can
write and play games in Vanta — a complete Snake ships as a template, written
entirely in Vanta. It also has **Vee**, a built-in AI assistant: add your own
**Claude or OpenRouter** API key in settings and Vee writes whole Vanta
projects straight into your editor — with OpenRouter you can point it at any
model (GPT, Gemini, Llama, Claude). It works as an offline helper without a key.

Live: **https://juanshep1.github.io/vanta/ide/** — or locally:

```bash
python3 -m http.server 8000     # from the repo root
# open http://localhost:8000/ide/
```

## Vanta Pocket — the iOS app

[**Vanta Pocket**](app/ios/) is a native iPhone/iPad IDE for Vanta, written in
SwiftUI: multi-file projects, a syntax-highlighted editor with a Vanta keyboard
bar, a live console (`ask` pops a native input dialog), bundled examples — and
**vcode**, the Vanta coding agent, as a chat panel that writes, runs, and fixes
programs right on your phone. Programs execute entirely on-device: the real
`vanta.py` runs inside CPython-on-WebAssembly bundled with the app, so it works
in airplane mode. Build it with Xcode — see [app/ios/README.md](app/ios/README.md).

## The playground

There's also a simpler [playground](playground/) that runs the *actual*
`vanta.py` in the browser (via Pyodide — CPython compiled to WebAssembly). It
has two modes: write and run Vanta code, or load a `.ch8` ROM into a **CHIP-8
emulator that is itself written in Vanta** (`emulator/chip8.va`). It plays real
ROMs — the IBM logo, Breakout, and your own. To run it locally:

```bash
python3 -m http.server 8000     # from the repo root
# open http://localhost:8000/playground/
```

There's also a small [macOS app](app/macos/) that wraps the playground in a
native window, and an early [Game Boy CPU](gameboy/cpu.va) written in Vanta
(a tested opcode core — not a working Game Boy yet; see its header for scope).

## A quick tour

### Variables and math
`let` creates a variable, `change` updates one. Keeping them separate means a
typo in a `change` is caught instead of silently making a new variable.

```
let total be 0
change total to total + 10
say 2 plus 3            # words or symbols, both fine: 2 + 3 also works
say 10 % 3              # remainder

let a, b be [1, 2]      # unpack a list into several names
change a, b to b, a     # swap, all at once

fix pi_ish be 3.14159   # a constant: 'change' on it is an error
```

### Decisions
```
if score is over 90
    say "A"
otherwise if score is over 80
    say "B"
otherwise
    say "C"
end
```

Comparisons read how you'd say them: `is`, `is not`, `is over`, `is under`,
`is at least`, `is at most`, `is bigger than`, `is less than`. Logic is `and`,
`or`, `not`.

There's an inline version (a value, not a block), and a `match` for picking among
fixed cases:

```
let grade be "pass" if score is at least 60 otherwise "fail"

match command
    when "start"
        say "starting"
    when "stop"
        say "stopping"
    otherwise
        say "unknown"
end
```

### Loops
```
repeat 3 times
    say "hi"
end

for each item in ["a", "b", "c"]
    say item
end

for each key, value in { "a": 1, "b": 2 }   # two names: key + value
    say key + " = " + value
end

while count is over 0
    decrease count by 1                      # also: increase x by n
end
```

`stop` breaks out of a loop, `skip` jumps to the next round.

### Functions
Define with `to`, return with `give back`, call with `name(args)`. Parameters
can have defaults, and functions are values you can pass around:

```
to greet(who, greeting be "Hello")     # greeting has a default
    give back greeting + ", " + who
end

say greet("world")            # Hello, world
say greet("world", "Hey")     # Hey, world
```

You can also write a function inline with `make`, and functions are real
closures — they remember the scope they were made in:

```
let double be make x give x * 2
say map(double, [1, 2, 3])    # [2, 4, 6]

to multiplier(factor)
    give back make x give x * factor   # captures factor
end
let triple be multiplier(3)
say triple(10)                # 30
```

### Strings that fill themselves in
Anything in `{curly braces}` inside a string is evaluated and dropped in (use
`{{` and `}}` for literal braces):

```
let name be "Juan"
say "Hello {name}, you'll be {25 + 1} next year."
```

### Higher-order functions
`map`, `keep` (filter), `reduce`, `each`, `count_where`, `find_where`, and
`sort_by` all take a function. Your own functions and the builtins both work:

```
to square(n)
    give back n * n
end

say map(square, [1, 2, 3])          # [1, 4, 9]
say keep(is_number, [1, "a", 2])    # [1, 2]
say map(uppercase, ["a", "b"])      # ["A", "B"]
```

### Your own types
Define a type with fields (`has`) and methods (`to`). Inside a method, `me`
refers to the object. A `setup` method runs when you build one; a `show` method
controls how it prints:

```
type Dog
    has name
    has sound
    to speak()
        give back me.name + " says " + me.sound
    end
end

let d be new Dog("Rex", "Woof")
say d.speak()                 # Rex says Woof
change d.name to "Max"
```

Types can inherit from another type with `from`, override methods, and be
checked with `is a`:

```
type Puppy from Dog
    to speak()
        give back super.speak() + ", but tiny"     # super reaches Dog's version
    end
end

let pup be new Puppy("Tiny", "Yip")
say pup.speak()              # Tiny says Yip, but tiny
say pup is a Dog             # yes  (inheritance)
```

### Comprehensions and regular expressions
```
let nums be [1, 2, 3, 4, 5]
say [n * n for each n in nums]               # [1, 4, 9, 16, 25]
say [n for each n in nums if n % 2 is 0]     # [2, 4]
say { n: n * n for each n in nums }          # a map of each number to its square

say matches("abc123", "[0-9]+")              # yes
say find_all("cat hat bat", "[a-z]at")       # ["cat", "hat", "bat"]
say replace_all("a1b2", "[0-9]", "#")        # a#b#
```

### Handling errors
Wrap risky code in `attempt` / `rescue`, and raise your own with `fail`:

```
attempt
    let x be 10 / 0
rescue problem
    say "That went wrong: {problem}"
end
```

### Lists and maps
```
let scores be [10, 20, 30]
add 40 to scores
change scores at 0 to 99
say scores[0]                  # first item
say scores[-1]                 # last item (negative indexing)
say scores[1:3]                # a slice (items 1 and 2)
say 99 is in scores            # membership test -> yes
say [n * 2 for each n in scores]
say [0] * 5                    # repeat -> [0, 0, 0, 0, 0]

let person be { "name": "Juan", "age": 25 }
change person at "age" to 26
say person["name"]
say "age" is in person         # is there such a key? -> yes
```

### Talking to the outside world
This is what makes Vanta useful for real scripts:

```
write_file("note.txt", "hello")
say read_file("note.txt")
say run("ls -la")            # run a shell command, get its output
```

### The web — servers and APIs
Vanta is full-stack. A web server is just a function that takes a request and
gives back a page (a string is sent as HTML; a map/list body is sent as JSON):

```
to handle(req)
    let path be req["path"]
    if path is "/"
        give back "<h1>Hello from Vanta</h1>"
    end
    if path is "/api"
        give back {"status": 200, "body": {"ok": yes}, "type": "application/json"}
    end
    give back {"status": 404, "body": "Not found"}
end

serve(8080, handle)          # now open http://localhost:8080
```

And you can call any API with `http_get` / `http_post` (a map/list body is sent
as JSON; you get back `{"status", "body", "headers"}`):

```
let res be http_get("https://api.github.com")
let code be res["status"]    # bind first — interpolation can't hold quotes
say "GitHub says {code}"
let data be from_json(res["body"])
```

> One gotcha: string interpolation `"{...}"` can't contain double quotes, so
> bind `let p be req["path"]` first, then say `"{p}"`.

### Modules and the standard library
`import` runs another file's definitions into your program. It looks for the
file as given, then in Vanta's bundled library (`lib/`), then in installed
packages under `~/.vanta/packages/` — so you can import by plain name:

```
import "math"                # finds lib/math.va
import "lists"
import "./my_helpers.va"     # or a path of your own

say sum([1, 2, 3, 4])        # from lib/lists.va
say factorial(10)            # from lib/math.va
```

The bundled library (`lib/`) ships `text`, `lists`, and `math` modules, all
written in Vanta. To publish your own, drop a `.va` file (or a folder with a
`main.va`) into `~/.vanta/packages/` and import it by name.

## Standard library

```
text:     length text number uppercase lowercase trim replace starts_with
          ends_with find split lines pad_left pad_right join chr code
          repeat_text title_case capitalize format_number
bytes:    read_bytes band bor bxor bnot shift_left shift_right
numbers:  abs round floor ceil sqrt power sin cos tan asin acos atan atan2
          log exp min max sum product clamp sign random random_float now
lists:    first last range contains keys values sort reverse slice push pop
          remove_at unique zip flatten index_of last_index_of insert_at
          shuffle pick chunk
maps:     get has_key remove_key merge entries
higher:   map keep reduce each count_where find_where sort_by any_where
          all_where
dates:    format_date parse_date
modules:  import "math" / "lists" / "text" / "random" (the bundled lib/)
types:    type_of is_a is_number is_text is_list is_map is_function is_nothing
regex:    matches find_all replace_all
time:     now today clock sleep
errors:   fail assert
constants: pi e
system:   read_file write_file run shell arguments env make_dir remove_path
          list_dir path_exists copy_path to_json from_json interpreter
web:      serve http_get http_post http_request url_encode url_decode html_escape
```

## How it works

Every programming language does three things, and all three live in `vanta.py`:

1. **Tokenize** — break each line into pieces: words, numbers, strings, symbols.
   This is also where word-phrases like `is at least` get folded into `>=`.
2. **Parse** — turn the tokens into a tree. Expressions use a recursive-descent
   parser with the usual precedence (multiplication before addition, comparisons
   last); statements are line-based and blocks close with `end`.
3. **Compile** — walk the tree *once* and turn each node into a small Python
   function (a closure) that does exactly its job. Operators, variable lookups,
   and calls are resolved here, not re-decided on every run.
4. **Run** — call the compiled closures. Variables live in scoped environments,
   which is what makes functions, recursion, and closures work; control flow
   (`give back`, `stop`, `skip`) travels as return signals rather than
   exceptions.

The original interpreter just walked the tree directly on every run — simpler to
read, but it re-decided what each line meant every single time. The compile step
keeps the same readable tree but does that work once, which is roughly 3× faster.
Both engines live in `vanta.py`; the tree-walker is still there as the fallback
for a few rare statements. It's still an interpreter you can actually follow —
just no longer a naive one. (`tools/benchmark.py` measures it.)

Honest limit: it's still interpreted in Python, so it's slower than C/Rust/V8 on
heavy number-crunching. That matters for tight compute loops, not for servers,
scripts, or talking to APIs — those wait on I/O, where the interpreter speed
barely shows.

## Examples

The `examples/` folder has a working program for each feature:

| File | Shows |
|------|-------|
| `hello.va` | printing, variables, math |
| `greet.va` | input and a decision |
| `countdown.va` | both kinds of loop |
| `fizzbuzz.va` | the classic exercise |
| `functions.va` | functions and recursion |
| `lists.va` | lists, `for each`, `range`, logic |
| `maps.va` | key/value maps |
| `mathtools.va` + `app.va` | a module and a program that imports it |
| `system.va` | files and shell commands |
| `objects.va` | a type with fields, methods, and `show` |
| `shapes.va` | inheritance, polymorphism, and comprehensions |
| `higher_order.va` | `map` / `keep` / `reduce` and passing functions |
| `errors.va` | `attempt` / `rescue` and `fail` |
| `using_lib.va` | importing the bundled standard library |
| `guess.va` | a number-guessing game |

There's also a longer write-up in [`docs/LANGUAGE_GUIDE.md`](docs/LANGUAGE_GUIDE.md).

## Tests

```bash
python3 run_tests.py
```

This runs the assertion-based tests in `tests/` and then runs every example to
make sure nothing crashes.

## Ecosystem

- **[vanbrew](https://github.com/Juanshep1/vanbrew)** — a one-file package manager
  (pip + Homebrew in one). `vanbrew install vanta` to get the language, plus vcode,
  vc, vself and more.
- **[vcode](https://github.com/Juanshep1/vcode)** — a Claude Code–style terminal
  coding agent that speaks Vanta: it reads, writes, runs and debugs `.va` programs
  for you. `vanbrew install vcode`.
- **[Harbor](https://github.com/Juanshep1/harbor)** — a Docker-style container
  engine whose entire engine is a Vanta program; a real tool written in Vanta.

## Why I built it

Most languages were designed by programmers for programmers, and it shows in all
the punctuation you have to learn before you can print a line. I wanted to see
what happens if readability wins every tie. Vanta is the result, and writing the
interpreter taught me more about how languages work than any tutorial did.

If you want to see what a real tool written in Vanta looks like, check out
[Harbor](https://github.com/Juanshep1/harbor) — a Docker-style container engine
whose entire engine is a Vanta program.

## License

MIT. See [LICENSE](LICENSE).
