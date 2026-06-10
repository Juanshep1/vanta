# Vanta — The Complete Language Guide

*A plain-English programming language. Version 1.0.*

---

## Page 1 — What Vanta Is and Why It Exists

### The one-sentence pitch
Vanta is a programming language designed to read like ordinary English, so that
a person who has never written a line of code can read a Vanta program and
understand what it does on the first try.

### The problem Vanta solves
Most programming languages were designed by engineers for engineers. They are
full of punctuation, abbreviations, and concepts that only make sense after you
already understand programming — a chicken-and-egg problem for beginners. Look
at how three different "mainstream" languages tell the computer to print a
greeting when someone is an adult:

```
Python:      if age >= 18: print("adult")
JavaScript:  if (age >= 18) { console.log("adult"); }
Java:        if (age >= 18) { System.out.println("adult"); }
```

Now the same thing in Vanta:

```
if age is at least 18
    say "adult"
end
```

There is no `>=`, no `()`, no `{}`, no `;`, no `console.log`, no
`System.out.println`. You say what you mean.

### The design philosophy
Vanta is built on four rules, in priority order:

1. **Readability beats brevity.** If a choice makes code shorter but harder to
   read aloud, Vanta picks readable.
2. **One obvious way.** Beginners get lost when there are ten ways to do one
   thing. Vanta offers one clear path (while still letting you use symbols if
   you prefer them).
3. **Errors should teach.** When something is wrong, Vanta tells you in a full
   sentence what to do — not a cryptic stack trace.
4. **Small enough to understand completely.** The entire language fits in one
   file you can read in an afternoon. There is no hidden magic.

### Who Vanta is for
- Absolute beginners writing their first program.
- Teachers who want students focused on *logic*, not punctuation.
- Anyone who wants to understand how a programming language is actually built,
  because Vanta's source is short and commented.

---

## Page 2 — The Core: Saying Things and Remembering Things

### Saying something (output)
The `say` command prints a value to the screen.

```
say "Hello, world!"
say 42
say 2 plus 3          # prints 5
```

### Variables: remembering things
A variable is a labeled box that holds a value. You create one with
`let NAME be VALUE`:

```
let name be "Juan"
let age be 25
let pi be 3.14
let is_happy be yes
```

Vanta has four kinds of values:

| Kind     | Example          | Meaning                       |
|----------|------------------|-------------------------------|
| Text     | `"Juan"`         | words and characters          |
| Number   | `25` or `3.14`   | whole numbers or decimals     |
| Yes/No   | `yes` / `no`     | true or false                 |

### Changing a variable
`let` is for creating. To update something that already exists, use `change`:

```
let score be 0
change score to score plus 10
say score            # prints 10
```

This separation is deliberate: `let` always means "make something new" and
`change` always means "update something that exists." If you `change` a thing
that was never created, Vanta stops and tells you so — catching a whole class
of typo bugs that silently break other languages.

### Comments: notes to yourself
Anything after `#` is ignored by Vanta. You can also start a line with the word
`note`.

```
# this is a comment
note this is also a comment
say "but this line runs"
```

---

## Page 3 — Doing Math, Making Decisions, and Repeating

### Math, two ways
Vanta is unusual: you can write math with **words** or with **symbols**, and
both produce the same result. Beginners use words; people who know math use
symbols.

```
say 2 plus 3            # or  2 + 3      -> 5
say 10 minus 4          # or  10 - 4     -> 6
say 6 times 7           # or  6 * 7      -> 42
say 10 divided by 2     # or  10 / 2     -> 5
say 10 % 3              # the remainder  -> 1
```

### Joining text
The `+` symbol joins text together, automatically turning numbers into text when
needed:

```
let name be "Juan"
let age be 25
say "Hello " + name + ", you are " + age
# prints: Hello Juan, you are 25
```

### Making decisions
The `if` command runs a block of code only when a condition is true. `otherwise`
handles the false case. Every `if` finishes with `end`.

```
if age is at least 18
    say "You can vote."
otherwise
    say "Too young to vote."
end
```

Vanta's comparison words are its signature feature. All of these work:

| You write…           | Meaning              | Symbol |
|----------------------|----------------------|--------|
| `is`                 | equal to             | `==`   |
| `is not`             | not equal to         | `!=`   |
| `is over` / `is above` | greater than       | `>`    |
| `is under` / `is below`| less than          | `<`    |
| `is bigger than`     | greater than         | `>`    |
| `is less than`       | less than            | `<`    |
| `is at least`        | greater than/equal   | `>=`   |
| `is at most`         | less than/equal      | `<=`   |

### Repeating: two kinds of loop
**Repeat a fixed number of times:**

```
repeat 3 times
    say "hip hip hooray"
end
```

**Repeat while something is true:**

```
let count be 5
while count is over 0
    say count
    change count to count minus 1
end
say "Blast off!"
```

You can leave a loop early with `stop`.

### Asking the user
The `ask` command pauses the program, shows a question, and stores the answer.
If the answer looks like a number, Vanta stores it as a number automatically.

```
ask "What is your name?" into name
ask "How old are you?" into age
say "Hi " + name
if age is at least 18
    say "Welcome, adult."
end
```

---

## Page 4 — What Makes Vanta Different

Vanta makes a handful of deliberate choices that set it apart from Python,
JavaScript, and the other languages people usually learn first.

### 1. English phrases instead of symbols
This is the headline. `is at least` instead of `>=`. `divided by` instead of
`/`. The goal is that a non-programmer can *read the code aloud and understand
it*. No other mainstream language commits to this fully. Importantly, Vanta
still accepts the symbols — so it is a gentle on-ramp, not a dead end. You can
start with words and graduate to symbols without changing languages.

### 2. `let` vs `change` — a safety net built into the grammar
In most languages, `x = 5` both creates and updates a variable, which means a
typo like `scroe = 10` silently creates a brand-new variable instead of failing.
Vanta splits these into two words. `let` only creates; `change` only updates a
thing that already exists. Misspell a name in a `change` and Vanta stops you
immediately with a clear message. The grammar itself prevents a common bug.

### 3. Errors written as full sentences
Compare a typical Python error:

```
NameError: name 'scroe' is not defined
```

…to Vanta's:

```
Oops! line 4: 'scroe' doesn't exist yet (use: let scroe be ...)
```

Vanta always tells you the line number, what went wrong, and what to do about
it — in a sentence, not jargon.

### 4. No "boilerplate"
Many languages make beginners type ceremony they don't understand before they
can do anything (`public static void main(String[] args)`, semicolons, import
statements, curly braces). A complete Vanta program can be a single line. There
is nothing to set up and nothing to memorize before you start.

### 5. Words for true/false
Conditions read naturally because the values are `yes` and `no`, not `True`
and `False` or `1` and `0`. When Vanta prints a yes/no value, it prints the
word "yes" or "no."

### 6. Blocks end with the word `end`
Instead of relying on invisible indentation (Python) or easy-to-mismatch braces
(`{ }` in C/JS), every block — `if`, `repeat`, `while` — finishes with the
plain word `end`. It is impossible to be confused about where a block stops, and
copy-paste never silently breaks your code's structure.

### 7. A real language, not a toy
Vanta is not a stripped-down teaching toy — it is a genuine general-purpose
language. It has user-defined **functions** (with **recursion**), **lists** and
**maps** (key/value collections), `for each` loops, logical `and`/`or`/`not`,
**file reading and writing**, the ability to **run real system commands**,
**modules** (`import` other files), an interactive **REPL**, and a standard
library of built-in functions. Anything you can write in a scripting language
like Python, you can write in Vanta — including real tools. (The one honest
caveat: Vanta does not yet have the decades of third-party *libraries* that
Python or Rust have. The language is real; the ecosystem is young.)

---

## Page 5 — How Vanta Works Under the Hood, and Where It's Going

### The three steps every language performs
Vanta is a small program (an *interpreter*) that reads your `.va` file and does
three things. Understanding these three steps means understanding how *every*
programming language works.

**Step 1 — Tokenize.** The interpreter chops each line of text into small pieces
called tokens. The line `say 2 plus 3` becomes:
`["say"] ["2"] ["plus"] ["3"]`. During this step, word-operators like `plus` and
`is at least` are recognized and converted into the matching math/comparison
operation.

**Step 2 — Parse.** The interpreter looks at the tokens and figures out the
*structure*: "this is an `if` statement, here is its condition, here is the
block of lines it controls, and here is where it ends." Blocks-within-blocks
(an `if` inside a `while`) are handled by reading the program as a nested
structure.

**Step 3 — Run.** The interpreter walks the structure and actually does what it
says: print this, store that, loop here, compare those. Variables are kept in a
simple lookup table (name → value) that the program reads and updates as it
goes.

That's the whole thing. There is no compiler, no virtual machine, no magic — and
because the source is one readable file, you can follow every step yourself.

### The expression evaluator
The most interesting piece is how Vanta computes something like
`age plus 1 is at least 18`. It reads the tokens left to right but respects the
normal order of operations — multiplication and division happen before addition
and subtraction, and comparisons happen last. This is done with a small,
classic technique called *recursive descent*, where the rules of math are
written directly as the structure of the code.

### What Vanta can already do (version 2.0)
Vanta has grown from a teaching toy into a real language. It now includes:

1. **Functions and recursion** — `to add(a, b) ... give back a + b ... end`.
2. **Lists** — `let scores be [10, 20, 30]`, with indexing, `add ... to`, and
   `for each` loops.
3. **Maps** — key/value collections, `{ "name": "Juan" }`.
4. **Logic** — `and`, `or`, `not`, and `otherwise if` chains.
5. **Random numbers** — `random(1, 10)`, enough to build games.
6. **Files** — `read_file` and `write_file` so programs remember things.
7. **System commands** — `run("ls")` runs real commands and captures output.
8. **Modules** — `import "other.va"` to split code across files.
9. **A REPL** — run `python3 vanta.py` with no file to type Vanta live.

### Roadmap — what's still ahead
1. **More standard-library functions** (dates, math helpers, JSON).
2. **Better error recovery** in the REPL.
3. **A Vanta playground** — run Vanta in a web page with no install.
4. **A package system** — share and reuse Vanta modules.

### Quick reference card
```
say VALUE                      print something
let NAME be VALUE              create a variable
change NAME to VALUE           update a variable
ask "QUESTION" into NAME       get input from the user
if CONDITION ... otherwise ... end     make a decision
repeat N times ... end         loop a fixed number of times
while CONDITION ... end         loop while true
stop                           break out of a loop
# or  note                     a comment
```

*Vanta — say what you mean.*
