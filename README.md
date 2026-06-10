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

It started as a toy. It isn't one anymore. Vanta has functions and recursion,
lists and maps, file access, the ability to shell out to the system, modules,
an interactive REPL, and a standard library. If you can write it in a scripting
language, you can mostly write it in Vanta.

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
Define with `to`, return with `give back`, call with `name(args)`:

```
to greet(who)
    say "Hello, " + who
end

greet("world")
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

`length` `text` `number` `uppercase` `lowercase` `trim` `replace`
`starts_with` `ends_with` `find` `split` `join` `lines` `first` `last`
`slice` `reverse` `sort` `range` `contains` `keys` `remove_at`
`abs` `round` `floor` `ceil` `min` `max` `random` `now`
`read_file` `write_file` `run` `shell` `arguments` `env`
`make_dir` `remove_path` `list_dir` `path_exists` `copy_path`
`to_json` `from_json`

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
| `guess.va` | a number-guessing game |

There's also a longer write-up in [`docs/LANGUAGE_GUIDE.md`](docs/LANGUAGE_GUIDE.md).

## Known rough edges

I'd rather be upfront about these than pretend they don't exist:

- Strings are single-line. Escapes (`\n`, `\t`, `\"`, `\\`) work, but a string
  can't span multiple source lines.
- Indexing is 0-based (like most languages), which trips up beginners who expect
  position 1 to be the first item. `first(list)` and `last(list)` help.
- No classes or objects yet — maps cover most of what you'd reach for them.
- It's a tree-walking interpreter, so it's not fast. Fine for scripts and
  learning, not for number-crunching.
- The standard library is young. The *language* is real; the *ecosystem* isn't
  there yet.

## What's next

- String formatting / interpolation
- A package system so modules can be shared
- A browser playground so you can try it with nothing installed
- More of the standard library (dates, math, simple HTTP)

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
