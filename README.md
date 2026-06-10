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
types with methods, error handling, lists and maps, string interpolation, file
and system access, modules, an interactive REPL, and a standard library of about
sixty functions. There's a test suite in `tests/`. If you can write it in a
scripting language, you can mostly write it in Vanta.

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
python3 vanta.py examples/hello.va     # run a program
python3 vanta.py                       # or start the REPL
```

## A quick tour

### Variables and math
`let` creates a variable, `change` updates one. Keeping them separate means a
typo in a `change` is caught instead of silently making a new variable.

```
let total be 0
change total to total + 10
say 2 plus 3            # words or symbols, both fine: 2 + 3 also works
say 10 % 3              # remainder
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

### Loops
```
repeat 3 times
    say "hi"
end

for each item in ["a", "b", "c"]
    say item
end

while count is over 0
    change count to count minus 1
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
say scores[0]

let person be { "name": "Juan", "age": 25 }
change person at "age" to 26
say person["name"]
```

### Talking to the outside world
This is what makes Vanta useful for real scripts:

```
write_file("note.txt", "hello")
say read_file("note.txt")
say run("ls -la")            # run a shell command, get its output
import "tools.va"            # pull in functions from another file
```

## Standard library

```
text:     length text number uppercase lowercase trim replace starts_with
          ends_with find split lines pad_left pad_right join
numbers:  abs round floor ceil sqrt power min max random now
lists:    first last range contains keys values sort reverse slice push pop
          remove_at
higher:   map keep reduce each count_where find_where sort_by
types:    type_of is_number is_text is_list is_map is_function is_nothing
errors:   fail assert
system:   read_file write_file run shell arguments env make_dir remove_path
          list_dir path_exists copy_path to_json from_json interpreter
```

## How it works

Every programming language does three things, and all three live in `vanta.py`:

1. **Tokenize** — break each line into pieces: words, numbers, strings, symbols.
   This is also where word-phrases like `is at least` get folded into `>=`.
2. **Parse** — turn the tokens into a tree. Expressions use a recursive-descent
   parser with the usual precedence (multiplication before addition, comparisons
   last); statements are line-based and blocks close with `end`.
3. **Run** — walk the tree. Variables live in scoped environments, which is what
   makes functions and recursion work.

There's no compiler and no bytecode. It's the most direct kind of interpreter
there is, which is the point — you can actually follow it.

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
| `higher_order.va` | `map` / `keep` / `reduce` and passing functions |
| `errors.va` | `attempt` / `rescue` and `fail` |
| `guess.va` | a number-guessing game |

There's also a longer write-up in [`docs/LANGUAGE_GUIDE.md`](docs/LANGUAGE_GUIDE.md).

## Tests

```bash
python3 run_tests.py
```

This runs the assertion-based tests in `tests/` and then runs every example to
make sure nothing crashes.

## Known limitations

I'd rather be upfront about these than pretend they don't exist:

- It's a tree-walking interpreter, so it's not fast. Fine for scripts and
  learning, not for number-crunching.
- Strings are single-line (escapes like `\n` work, but a string can't span
  source lines), and every string interpolates — use `{{` for a literal brace.
- Indexing is 0-based; `first(list)` and `last(list)` help if that trips you up.
- No inheritance — types have fields and methods but don't extend each other.
- The standard library covers the basics but is nowhere near Python's. The
  *language* is real; the *ecosystem* is young.

## What's next

- Type inheritance and a way to check "is this a Dog?"
- A package system so modules can be shared
- A browser playground so you can try it with nothing installed
- More of the standard library (dates, regular expressions, simple HTTP)

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
