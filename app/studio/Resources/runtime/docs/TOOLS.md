# Vanta Tools Reference

Everything you do with Vanta goes through one command, `vanta`. This page documents every
subcommand, the test-block syntax, the formatter's rules, the package manifest, the REPL,
the debugger, the language server and the editor/highlighter support.

```
vanta <command> [options]        or just:  vanta program.va
```

| Command | What it does |
|---|---|
| `vanta run FILE [ARGS]` | run a program |
| `vanta repl` | interactive prompt |
| `vanta debug FILE [ARGS]` | step through a program |
| `vanta build FILE [...]` | compile to a native executable / iOS app / OS kernel |
| `vanta test [PATHS]` | run test blocks |
| `vanta check FILES` | check a program without running it |
| `vanta fmt [FILES]` | format code the standard way |
| `vanta doc FILE` | documentation from `##` comments |
| `vanta new NAME` | start a project |
| `vanta get [PACKAGE]` | install packages |
| `vanta lsp` | language server for editors |
| `vanta version` | print the version |
| `vanta help [COMMAND]` | list the commands, or explain one |

`vanta` is a small launcher script next to `vanta.py` (`vanta.bat` on Windows, which uses
`python3`, then `py -3`, then `python`). Put that folder on your `PATH`. Without the launcher,
`python3 vanta.py <command> ...` does exactly the same. The old forms keep working:
`vanta program.va`, `python3 vanta.py program.va`, and plain `vanta` (starts the REPL).

`vanta help COMMAND` (or `vanta COMMAND --help`) prints the details for one command. A
mistyped command gets a suggestion: `vanta tset` → `did you mean 'vanta test'?`

---

## vanta run

```
vanta run FILE [ARGS...]
vanta FILE [ARGS...]                 (short form)
```

Runs a program. Everything after the file name reaches the program through `arguments()`:

```
$ vanta run greet.va Ada Bob
```

`test "..."` blocks in the file are skipped. The exit code is 0 on success and 1 when the
program stops with an error.

### Error messages

When a program fails, Vanta shows where, what, and (when it can guess) how to fix it:

```
start
Oops! line 5: I don't know what 'totl' is yet
  --> shop.va:5
    |
  5 |     give back totl + tax * n
    |               ^^^^
  = hint: did you mean 'total'?
  call stack (most recent call last):
    shop.va line 13, at the top level
    shop.va line 9, in outer
    shop.va line 5, in price
```

- The `Oops! line N: ...` line is printed on standard output (exactly as in earlier
  versions); the location, source line, caret, hint and call stack go to standard error.
- The caret underlines the name the message is about, or the whole statement.
- **Hints.** For a name that doesn't exist, Vanta suggests the closest names, looking first
  at the names your program defines, then at the most common builtins, and only then at the
  rest of the library (at most two suggestions). A capitalized unknown word gets
  `if you meant the text Hello, put it in quotes: "Hello"`. A misspelled statement word
  (`sya "hi"`) gets `did you mean 'say'?`. Other hints cover a missing `end`, a missing
  closing quote, comparing text with numbers and joining numbers onto text.
- **Call stack.** Shown when the error happened inside a function: every Vanta call that
  led there, outermost first, with file and line. Errors inside imported modules name the
  module file.

---

## vanta repl

```
vanta repl          (or just: vanta)
```

```
Vanta 6.0 - type Vanta code, :help for help, :quit to leave.
vanta> let price be 4
vanta> price * 3
12
vanta> "hi"
"hi"
vanta> to double(n)
...        give back n * 2
...    end
vanta> double(21)
42
```

- **Values are shown.** If the line is an expression, its value is printed (text in quotes so
  `"5"` and `5` look different). `say` prints as usual. `nothing` isn't shown.
- **Blocks continue** until their `end`: any line that opens a block (`if`, `repeat`, `while`,
  `for each`, `to`, `type`, `match`, `attempt`, `test`, `kind NAME`, `using`, ...) switches
  to the `...` prompt. Blank lines inside a block are ignored. `:cancel` or Ctrl-C drops a
  half-typed block.
- **Line editing and history**: arrow keys, Ctrl-A/Ctrl-E and friends (readline); Up/Down
  recall earlier lines, saved between sessions in `~/.vanta_history`. Tab completes
  keywords, builtins and your own names.
- Errors are reported the same friendly way as in `vanta run` and the session continues.

| Command | Meaning |
|---|---|
| `:help` | list the commands |
| `:load FILE` | run a file into the session; its functions and variables stay defined |
| `:vars` | list the variables and functions you've made, with their types and values |
| `:doc NAME` | what a builtin or keyword does (from the standard library reference) |
| `:reset` | forget everything |
| `:cancel` | drop a half-typed block |
| `:quit` | leave (also `bye`, `exit`, `quit`, Ctrl-D) |

---

## vanta debug

```
vanta debug FILE [ARGS...]
```

Runs the program under a line debugger. It stops before the first statement and shows the
line about to run:

```
$ vanta debug totals.va
Vanta debugger - totals.va. Type help for commands; 'c' runs to a breakpoint.
totals.va:1  to square(n)
(vdb) break 2
breakpoint at totals.va:2
(vdb) c
breakpoint at line 2
totals.va:2  let result be n * n
(vdb) where
  #0 top level at totals.va:8
  #1 square at totals.va:2
(vdb) p n + 100
101
(vdb) vars
  locals:
    n = 1
  globals:
    square = <function square>
    total = 0
    i = 1
(vdb) finish
totals.va:8  change total to total + square(i)
```

| Command | Short | What it does |
|---|---|---|
| `break N` | `b N` | stop when line N is about to run; `break FILE:N` for an imported file; `break` alone lists breakpoints |
| `delete N` | `d N` | remove a breakpoint; `delete` alone removes all |
| `step` | `s` | run one line, going into function calls |
| `next` | `n` | run one line, stepping over function calls |
| `finish` | `f` | run until the current function gives back |
| `continue` | `c` | run until the next breakpoint (or the end) |
| `print EXPR` | `p EXPR` | evaluate any expression in the current scope |
| `vars` | `v` | list local, then global variables |
| `where` | `bt` | the Vanta call stack, outermost first |
| `list` | `l` | the code around the current line (`->` marks it, `b` marks breakpoints) |
| `quit` | `q` | stop the program |
| `help` | `h` | list the commands |

How it works: the interpreter calls a debugger hook before every statement. The hook is
chosen when code is compiled, so ordinary runs pay nothing for it.

---

## vanta build

```
vanta build FILE [-o OUT] [--run] [--keep-c] [--debug] [ARGS...]
vanta build FILE --ios [-o App.app] [--name N] [--bundle-id ID] [--resources DIRS] [--icon PNG]
vanta build FILE --kernel [-o OUT]
```

Compiles the program to C and then to a native executable with `native/vantac.py`. All
options are passed straight to the compiler:

| Option | Meaning |
|---|---|
| `-o OUT` | output name (default: the file name without `.va`) |
| `--run` | run it right after building; extra ARGS go to the program |
| `--keep-c` | keep the generated C |
| `--debug` | no optimisation, with debug symbols |
| `--ios` | build an iPhone/iPad app bundle |
| `--kernel` | build a bootable operating-system kernel |

---

## vanta test

```
vanta test [FILES or FOLDERS] [--native] [-v] [--filter TEXT] [--no-color]
```

### Test blocks

Tests live in ordinary Vanta files, next to the code or in a `tests/` folder:

```
to add(a, b)
    give back a + b
end

test "adds numbers"
    expect add(2, 2) is 4
    expect add(2, 2) is not 5
end

test "knows what's in a list"
    expect [1, 2, 3] contains 2
    expect "hello world" contains "world"
end

test "refuses bad input"
    expect add(1, "x") fails
    expect read_file("missing.txt") fails with "could not"
end
```

- `test "description"` ... `end` is a block at the top level of a file. `vanta run` (and
  `vanta build`) skip test blocks entirely, so tests can sit next to the code they check.
- `expect` checks one thing. When it fails, the test stops and the message shows the
  source of the check and both values.

| Form | Passes when | Failure message |
|---|---|---|
| `expect A is B` | A equals B (`yes`/`no` only equal booleans) | `expect add(2, 2) is 5: expected 5, got 4` |
| `expect A is not B` | A differs from B | `expected anything but 2, got 2` |
| `expect A is at least B` (any comparison: `is over`, `is under`, `is at most`, `>`, `<=`, ...) | the comparison holds | `expected a value at least 5, got 2` |
| `expect A is in B` / `is not in` | membership | `3 is not in [1, 2]` |
| `expect A is a TYPE` | A is that type (or a child type) | `got 5 (a number)` |
| `expect A contains B` | list item, map key, or piece of text | `[1, 2] does not contain 9` |
| `expect ACTION fails` | evaluating ACTION stops with an error | `expected an error, but it gave back 2` |
| `expect ACTION fails with "text"` | ...and the error message contains the text | `the error should mention "boom", but it was "other"` |
| `expect CONDITION` | the value is `yes` (any other check) | `it was no` |

Text values are shown in quotes in failure messages (`expected "abd", got "abcd"`).
`expect` also works outside test blocks (it then behaves like `assert` with a better message).

### Running

```
$ vanta test tests/math_test.va
tests/math_test.va
  PASS  adds numbers (0.2 ms)
  FAIL  a failing one (0.0 ms)
        line 27: expect add(2, 2) is 5: expected 5, got 4
        | some output
  FAIL  text compare (0.0 ms)
        line 31: expect "abc" + "d" is "abd": expected "abd", got "abcd"

1 passed, 2 failed in 1 ms (1 file)
```

- **What runs:** the file's code outside the tests runs once first (so tests can use its
  functions and variables); then each test runs in its own scope, so a `let` inside one
  test doesn't leak into the next.
- **Output:** anything a test prints is hidden unless the test fails (shown with `| `) or
  you pass `-v`.
- **Which files:** with no paths, `tests/` (or the current folder). In a folder: files named
  `test_*.va` or `*_test.va`, and any `.va` file containing test blocks; `packages/` is
  skipped. A named file is always used. A file without test blocks counts as one test,
  `(runs without errors)`, which passes if the file runs cleanly — so assert-style test
  files work too.
- `--filter TEXT` (or `-k TEXT`) runs only tests whose description contains TEXT.
- `--native` compiles each file's tests with the native compiler and runs the executable
  (each test block becomes a function; `expect` uses a Vanta implementation of the same
  checks). Native failure messages have the same wording but no `line N:` prefix.
- The summary gives counts and total time; the exit code is 1 if any test failed or a file
  couldn't run, so `vanta test` works in CI.

---

## vanta check

```
vanta check FILES
```

Checks programs without running them. It always checks the syntax of every file (and
prints `FILE: ok`); when the type checker is installed it also checks type annotations and
names. Exit code 1 if anything is wrong.

---

## vanta fmt

```
vanta fmt [--check] [--diff] [FILES or FOLDERS]
vanta fmt -                       (format standard input to standard output)
```

| Example | Effect |
|---|---|
| `vanta fmt` | format every `.va` file under the current folder (skips `packages/` and hidden folders) |
| `vanta fmt game.va lib/` | format these files / folders in place |
| `vanta fmt --check .` | change nothing; list files that would change; exit 1 if any (for CI) |
| `vanta fmt --diff game.va` | show the changes as a unified diff, change nothing |

### The rules

- **Indentation:** 4 spaces per block level, computed from the block structure. `otherwise`
  and `rescue` line up with their `if`/`attempt`; `when` lines sit one level inside their
  `match`, with their bodies one level further.
- **Spaces:** one space around operators (`1 + 2 * 3`, `x > 3`, `a is at least b`), after
  commas, and after a map's colon (`{"a": 1}`); none inside brackets (`f(1, 2)`, `[1, 2]`),
  before a call's or index's bracket (`total(xs)`, `xs[0]`), around a slice's colon
  (`xs[1:3]`), around `.` (`me.name`), or after a unary minus (`-x`, `f(-1)`).
- **Comments** are kept as written. An inline comment keeps the spacing you gave it, with
  at least two spaces before the `#`. `note` lines are kept.
- **Blank lines:** at most one in a row; one blank line before and after every top-level
  function, type, kind and test block (a `##` doc comment stays attached to its
  definition); none at the start; exactly one newline at the end. Trailing spaces go.
- **Text is never touched:** strings, `{interpolation}` and `"""triple-quoted"""` text
  (including the lines inside it) are kept exactly.

**Safety:** before writing, the formatter parses the original and the result and checks
that they are the same program. If the full rules can't be applied safely it falls back to
re-indenting only, and if even that isn't provably safe it leaves the file alone and says
so. Files with syntax errors are reported and not changed. Formatting is idempotent:
formatting formatted code changes nothing.

---

## vanta doc

```
vanta doc FILE [FILES...] [--html] [-o OUT]
```

Writes documentation from `##` comments (a comment that starts with two `#`):

```
## Helpers for a shopping cart.
## Prices are in dollars.

## The sales tax rate.
fix TAX be 0.2

## The total price of every item, with tax.
##
## rate is the tax rate as a fraction.
to total(items, rate be TAX)
    give back sum(items) * (1 + rate)
end

## A product on the shelf.
type Product
    ## what it's called
    has name
    ## A short label like "Tea ($3)".
    to label()
        give back "{me.name}"
    end
end

## Sizes we sell.
kind Size is small, medium, large
```

- A `##` block at the very top of the file, followed by a blank line, describes the file.
- A `##` block directly above `to`, `type`, `kind` or a top-level `fix` documents it. Inside
  a type, `##` above `has` documents a field and above `to` a method.
- An empty `##` line starts a new paragraph.
- Every top-level function is listed (with its signature) even without a comment; names
  starting with `_` are private and left out. Ordinary `#` comments are never included.

Output is Markdown on standard output, grouped into Functions, Types (with fields and
methods), Kinds (with their values) and Constants. `-o FILE` writes to a file; `--html`
(or an `-o` name ending in `.html`) writes a self-contained web page with light and dark
styles.

---

## vanta new

```
vanta new NAME [--cli | --game | --web | --os]
```

Creates a project folder:

```
NAME/
  vanta.json            the manifest
  main.va               the program (a working template)
  tests/test_main.va    example tests (run with: vanta test)
  README.md             how to run, test, format
  .gitignore            ignores packages/, generated C, app bundles
```

| Kind | Template | Run it with |
|---|---|---|
| `--cli` (default) | greets the names given on the command line; its tests import `main.va` | `vanta run main.va Ada` |
| `--game` | a window with a circle you move with the arrow keys (`update(dt)` / `draw()`) | `vanta build main.va --run` |
| `--web` | a server with a page at `/` and JSON at `/api` | `vanta run main.va` |
| `--os` | a kernel that greets you and echoes key presses | `vanta build main.va --kernel` |

### vanta.json

```json
{
  "name": "weather",
  "version": "0.1.0",
  "description": "A Vanta cli project.",
  "entry": "main.va",
  "kind": "cli",
  "dependencies": {
    "colors": {"source": "https://github.com/someone/vanta-colors.git", "version": "v1.2.0"}
  }
}
```

| Field | Meaning |
|---|---|
| `name` | the project or package name (letters, digits, `_`, `-`) |
| `version` | its version (use the same text as its git tag, e.g. tag `v0.1.0`) |
| `description` | one line about it |
| `entry` | the main file; for a package, what `import "NAME"` loads |
| `kind` | `cli`, `game`, `web` or `os` (informational) |
| `dependencies` | packages this one needs: name → `{"source": ..., "version": ...}`; a plain string `"SOURCE@VERSION"` also works |

---

## vanta get

```
vanta get                         install every dependency in vanta.json (honouring vanta.lock)
vanta get SOURCE[@VERSION] ...    add packages to the project and install them
vanta get --global SOURCE         install into ~/.vanta/packages (also -g)
```

**SOURCE** can be:

| Source | Example |
|---|---|
| a git URL | `https://github.com/someone/vanta-colors.git`, `git@github.com:someone/colors.git`, `file:///home/me/colors` |
| GitHub shorthand | `someone/vanta-colors` |
| a local folder | `../colors` (copied; a folder that is a git repository is cloned, so versions work) |
| a name from the package index | `colors` — looked up in `~/.vanta/registry.json`, or the file or URL in `$VANTA_REGISTRY` (`{"colors": "https://...git"}`) |

**VERSION** is a git tag. `@1.2.0` also finds a tag named `v1.2.0` (and the other way
round). Without a version you get the default branch.

What happens:

1. The package is cloned (git is required for git sources), the tag is checked out, and
   its `.git` folder is dropped.
2. It is installed as `packages/NAME/` in the project (the folder holding `vanta.json`,
   searched upward from the current folder), or in `~/.vanta/packages/NAME/` with
   `--global` or outside a project. NAME comes from the package's own `vanta.json`, else
   the repository name (without `.git` and a `vanta-` prefix).
3. The package's own dependencies are installed too, next to it.
4. In a project, `vanta.json` gets the dependency and **`vanta.lock`** records the exact
   commit of every installed package:

```json
{
  "lockfile": 1,
  "packages": {
    "colors": {"source": "https://github.com/someone/vanta-colors.git", "version": "v1.2.0",
               "commit": "306c7cd4849fa0f50f896096e8718db0084019ce"}
  }
}
```

`vanta get` with no arguments reinstalls everything in `vanta.json`; a package whose source
and version still match its lock entry is checked out at the locked commit, so everyone
gets identical code. Commit `vanta.json` and `vanta.lock`; don't commit `packages/`.

### Importing packages

```
import "colors"
say shout("hi")
```

`import "NAME"` looks, in order, at: the path as written, the bundled library (`lib/`),
`~/.vanta/packages/NAME.va` and `~/.vanta/packages/NAME/main.va`, the importing file's
folder, then `packages/NAME/` next to the importing file, next to the main program, and in
the current folder, then `~/.vanta/packages/NAME/`. Inside a package folder the file is the
`entry` from its `vanta.json`, else `main.va`, else `NAME.va`. Native builds
(`vanta build`) find packages the same way.

---

## vanta lsp — editor support

```
vanta lsp
```

A Language Server Protocol server on standard input/output (pure Python, no packages
needed). Editors start it themselves. It provides:

- **Diagnostics as you type** — syntax errors with the exact range and Vanta's hint; the
  type checker's findings when it is available; otherwise a warning for calls to functions
  that exist nowhere (`I don't know a function called 'lenght' (did you mean 'length'?)`).
- **Completion** — your own names, keywords and phrases (`is at least`, `give back`, ...),
  and every builtin with its signature and description.
- **Hover** — signature and description of builtins and keywords (from the standard library
  reference), and of your own functions and types with their `##` doc comments.
- **Go to definition** — functions, types, kinds, variables and constants, in the file and
  in the files it imports.
- **Document symbols** — an outline of functions, types, kinds, constants and tests.
- **Formatting** — Format Document applies `vanta fmt`.

### VS Code

The extension is in `editors/vscode` (syntax highlighting, brackets, comment toggling,
indentation and folding rules, and the language server):

```
cd editors/vscode
npm install
npx @vscode/vsce package
code --install-extension vanta-language-6.0.0.vsix
```

Settings: `vanta.path` (the `vanta` command, or a path to the launcher or `vanta.py`;
default `vanta`) and `vanta.languageServer.enabled`. Commands: *Vanta: Run This File*,
*Vanta: Run Tests In This File*.

Other editors (Neovim, Helix, Sublime LSP, Emacs eglot, Zed): configure a server for
`*.va` files with the command `vanta lsp`. The TextMate grammar
`editors/vscode/syntaxes/vanta.tmLanguage.json` (scope `source.vanta`) works in any editor
that reads TextMate grammars.

---

## Syntax highlighting elsewhere

**Pygments** (Python; used by the book's PDF builder, Sphinx, MkDocs, ...): `tools/vanta_lexer.py`
defines `VantaLexer` (a `RegexLexer`; aliases `vanta`, `va`; files `*.va`).

```python
import sys; sys.path.insert(0, "tools")
from vanta_lexer import VantaLexer
from pygments import highlight
from pygments.formatters import HtmlFormatter
html = highlight(open("game.va").read(), VantaLexer(), HtmlFormatter())
```

```
pygmentize -l tools/vanta_lexer.py:VantaLexer -x -f html -O full -o game.html game.va
```

Token types: statement keywords → `Keyword`; `to`/`type`/`kind`/`test` → `Keyword.Declaration`
with the defined name as `Name.Function` / `Name.Class`; word operators (`is at least`,
`is not in`, `divided by`, `plus`, `and`, ...) → `Operator.Word` as one token; `yes`/`no`/
`nothing`/`pi`/`e` → `Keyword.Constant`; `me`/`super` → `Name.Builtin.Pseudo`; builtins
called as functions → `Name.Builtin`; capitalized names → `Name.Class`; type annotations
(`r: number`, `-> text`) → `Keyword.Type`; strings → `String.Double` with `\n` escapes and
`{{ }}` as `String.Escape` and `{interpolation}` as `String.Interpol` around highlighted
code; `"""raw text"""` → `String.Doc`; `##` doc comments → `Comment.Special`; `#` comments
and `note` lines → `Comment.Single`; numbers → `Number.Hex/Bin/Oct/Float/Integer`
(underscores allowed).

**highlight.js** (web pages): `tools/highlight-vanta.js` registers the language `vanta`
(alias `va`):

```html
<script src="highlight.min.js"></script>
<script src="tools/highlight-vanta.js"></script>
<script>hljs.highlightAll();</script>   <!-- <pre><code class="language-vanta"> -->
```

or `hljs.registerLanguage("vanta", require("./tools/highlight-vanta.js"))` in Node.

---

## Testing the tools themselves

`python3 tools/tools_test.py` tests every command above (it is part of
`python3 run_tests.py`): the command line and old forms, error reports, test blocks (in
the interpreter and natively), the formatter on every file in `tests/`, `examples/`,
`lib/`, `emulator/` and `gameboy/` (same program, idempotent, and the formatted tests print
exactly what the originals print), `vanta doc`, `vanta new` for every kind, `vanta get`
with versions and the lock file, a REPL session, a debugger session, a language-server
session and the Pygments lexer.
