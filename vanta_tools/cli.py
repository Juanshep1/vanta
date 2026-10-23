"""The `vanta` command line.

    vanta run file.va [args]     vanta test [paths]       vanta new NAME
    vanta repl                   vanta fmt [--check] ...  vanta get [PACKAGE]
    vanta build file.va ...      vanta doc file.va        vanta check file.va
    vanta debug file.va          vanta lsp                vanta version / help

`vanta file.va` and `python3 vanta.py file.va` still run a program, and plain `vanta`
starts the REPL."""

import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SUMMARY = """\
Vanta {version} - a plain-English programming language.

Usage: vanta <command> [options]      (or just: vanta program.va)

Running code
  run FILE [ARGS]     run a program (ARGS reach it through arguments())
  repl                interactive prompt with history, :help, :load, :vars
  debug FILE [ARGS]   step through a program: breakpoints, step/next, print, where
  build FILE [...]    compile to a native executable (-o OUT, --run, --ios, --kernel)

Checking code
  test [PATHS]        run the test blocks in files (--native, -v, --filter TEXT)
  check FILES         check types and names without running
  fmt [FILES]         format code the standard way (--check for CI)
  doc FILE            write documentation from ## comments (--html, -o OUT)

Projects and packages
  new NAME            start a project (--cli, --game, --web, --os)
  get [PACKAGE]       install a package, or every dependency in vanta.json

Editors
  lsp                 language server for editors (VS Code: editors/vscode)

Other
  version             print the version
  help [COMMAND]      show help for a command

Run 'vanta help COMMAND' for details and examples."""

HELP = {
    "run": """\
vanta run FILE [ARGS...]

Runs a Vanta program. Everything after the file name is passed to the program,
which reads it with arguments(). Test blocks in the file are skipped.

  vanta run hello.va
  vanta run tools/rename.va *.txt
  vanta hello.va                 (the short form works too)

When something goes wrong you get the file, the line, the source line with a
caret under the problem, a hint when Vanta can guess the fix, and the chain of
function calls that led there. The exit code is 1 on an error.""",
    "repl": """\
vanta repl

An interactive prompt. Type a line and press Enter; the value of an expression
is shown. Blocks (if, repeat, to, type, ...) keep reading lines until their
'end'. Up/Down arrows recall history (saved in ~/.vanta_history).

  :help          list the commands
  :load FILE     run a file into the session (its functions stay defined)
  :vars          show the variables you've made
  :reset         forget everything and start fresh
  :quit          leave (or type bye, or press Ctrl-D)""",
    "build": """\
vanta build FILE [-o OUT] [--run] [--keep-c] [--debug] [ARGS...]
vanta build FILE --ios [-o App.app] [--name N] [--bundle-id ID] [--resources DIRS] [--icon PNG]
vanta build FILE --kernel [-o OUT]

Compiles a program to C and then to a native executable (native/vantac.py).
  -o OUT       name of the executable (default: the file name without .va)
  --run        run it right after building (extra ARGS go to the program)
  --keep-c     keep the generated C file
  --debug      build without optimisation, with debug symbols
  --ios        build an iPhone/iPad app bundle
  --kernel     build a bootable OS kernel image""",
    "test": """\
vanta test [FILES or FOLDERS] [--native] [-v] [--filter TEXT] [--no-color]

Runs test blocks. With no paths it looks in tests/ (or the current folder).
In a folder it picks test_*.va, *_test.va and any file with test blocks.

  test "adds numbers"
      expect add(2, 2) is 4
      expect add(2, 2) is not 5
      expect score is at least 10          (any comparison works)
      expect [1, 2, 3] contains 2
      expect "hello" contains "ell"
      expect add(1, "x") fails
      expect read_file("nope") fails with "could not"
      expect is_even(4)                     (passes when the value is yes)
  end

The rest of the file runs first (so tests can use its functions); each test runs
in its own scope. Output a test prints is shown only when it fails (or with -v).
  --native     compile the tests with the native compiler and run them
  --filter T   only tests whose name contains T
The exit code is 1 if anything failed.""",
    "fmt": """\
vanta fmt [--check] [--diff] [FILES or FOLDERS]

Formats Vanta code the standard way: 4-space indentation, one space around
operators and after commas, no spaces inside brackets, one blank line around
functions and types, at most one blank line in a row, no trailing spaces.
Comments are kept. Formatting twice changes nothing.

  vanta fmt                  format every .va file under the current folder
  vanta fmt game.va          format one file in place
  vanta fmt --check .        CI mode: list files that need formatting, exit 1
  vanta fmt --diff game.va   show what would change, don't write

The formatter checks that the program means exactly the same thing afterwards
and leaves a file alone if it can't prove that.""",
    "doc": """\
vanta doc FILE [--html] [-o OUT]

Writes documentation for a file from its ## comments. A ## comment block at the
very top describes the file; a ## block right above a function, type or fixed
value documents it.

  ## Shopping cart helpers.

  ## The total price of every item, with tax.
  ## rate is the tax rate as a fraction (0.2 = 20%).
  to total(items, rate be 0.2)
      ...
  end

Markdown goes to the screen unless -o is given; --html writes a web page.""",
    "new": """\
vanta new NAME [--cli | --game | --web | --os]

Creates a project folder:
  NAME/vanta.json        the manifest: name, version, entry, dependencies
  NAME/main.va           the program (a template for the kind you chose)
  NAME/tests/test_main.va
  NAME/README.md, NAME/.gitignore

  --cli    a command-line tool (default)
  --game   a 2D game window with a game loop
  --web    a small web server
  --os     a tiny operating-system kernel (build with: vanta build main.va --kernel)""",
    "get": """\
vanta get                      install every dependency listed in vanta.json
vanta get SOURCE[@VERSION]     add a package and install it
vanta get --global SOURCE      install into ~/.vanta/packages instead

SOURCE can be a git URL (https://..., git@..., file://...), a GitHub shorthand
(user/repo), a local folder, or a name listed in the package index
(~/.vanta/registry.json or $VANTA_REGISTRY). VERSION is a git tag (v1.2.0, 1.2.0).

Inside a project (a folder with vanta.json) packages go into ./packages and are
recorded in vanta.json; vanta.lock pins the exact commit of each, so 'vanta get'
installs the same code on every machine. Import a package by its name:

  import "colors"            (finds packages/colors/main.va)""",
    "check": """\
vanta check FILES

Checks programs without running them: syntax, and (when the checker is
present) type annotations and names.""",
    "debug": """\
vanta debug FILE [ARGS...]

Runs a program under the debugger. It stops before the first line.

  break 12 (b)        stop at line 12 (break file.va:12 for another file)
  break               list breakpoints        delete 12   remove one
  step (s)            run one line, going into function calls
  next (n)            run one line, stepping over function calls
  finish (f)          run until the current function gives back
  continue (c)        run until the next breakpoint
  print EXPR (p)      show a value: p total, p items[0] + 1
  vars (v)            show the variables in scope
  where (bt)          show the call stack
  list (l)            show the code around the current line
  quit (q)            stop the program""",
    "lsp": """\
vanta lsp

Starts the Vanta language server on stdin/stdout (the Language Server Protocol).
Editors launch it for you: it gives error diagnostics as you type, completion of
keywords, builtins and your own names, hover docs, and go-to-definition. The VS
Code extension is in editors/vscode.""",
    "version": "vanta version\n\nPrints the Vanta version.",
    "help": "vanta help [COMMAND]\n\nShows the list of commands, or details about one.",
}


def version_text(V):
    return f"Vanta {V.VERSION}"


def run_program(V, path, args):
    """Run a .va file with friendly error reports. Returns the exit code."""
    from . import errors
    V.PROGRAM_ARGS = list(args)
    try:
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
    except OSError as e:
        print(f"Oops! could not open {path}: {e.strerror or e}")
        return 1
    try:
        V.run_source(source, path)
    except V.VantaError as e:
        errors.report(V, e, path)
        return 1
    except (V.BreakLoop, V.ContinueLoop):
        print("Oops! 'stop'/'skip' only work inside a loop")
        return 1
    except V.ReturnSignal:
        print("Oops! 'give back' only works inside a function")
        return 1
    except RecursionError:
        print("Oops! too much recursion - a function kept calling itself without stopping")
        return 1
    except KeyboardInterrupt:
        print("\nstopped.")
        return 130
    return 0


def cmd_run(V, args):
    if not args:
        print("Usage: vanta run FILE [ARGS...]")
        return 1
    return run_program(V, args[0], args[1:])


def cmd_build(V, args):
    compiler = os.path.join(HERE, "native", "vantac.py")
    if not os.path.isfile(compiler):
        print("Oops! this copy of Vanta doesn't include the native compiler (native/vantac.py)")
        return 1
    import subprocess
    return subprocess.call([sys.executable, compiler] + args)


def cmd_check(V, args):
    """`vanta check` — the type/name checker if one is installed, otherwise a syntax check."""
    for hook in ("cmd_check", "check_main", "main_check"):
        fn = getattr(V, hook, None)
        if callable(fn):
            return fn(args) or 0
    try:
        from . import checker            # a checker module, if one ships in vanta_tools
        return checker.main(V, args) or 0
    except ImportError:
        pass
    if not args:
        print("Usage: vanta check FILES")
        return 1
    from . import errors
    bad = 0
    for path in args:
        try:
            with open(path, encoding="utf-8") as f:
                V.CURRENT_FILE = os.path.abspath(path)
                V.parse_program(V.load_lines(f.read()), keep_tests=True)
            print(f"{path}: ok")
        except OSError as e:
            print(f"Oops! could not open {path}: {e.strerror or e}")
            bad += 1
        except V.VantaError as e:
            errors.report(V, e, path)
            bad += 1
    return 1 if bad else 0


def cmd_help(V, args):
    if args and args[0] in HELP:
        print(HELP[args[0]])
        return 0
    if args:
        print(f"Oops! there's no command called '{args[0]}'.")
        _suggest_command(args[0])
        return 1
    print(SUMMARY.format(version=V.VERSION))
    return 0


def _suggest_command(word):
    import difflib
    close = difflib.get_close_matches(word, list(COMMANDS), n=1, cutoff=0.6)
    if close:
        print(f"  did you mean 'vanta {close[0]}'?")
    print("  run 'vanta help' to see every command.")


def _lazy(module, func="main"):
    def run(V, args):
        import importlib
        mod = importlib.import_module(f"{__package__}.{module}")
        return getattr(mod, func)(V, args)
    return run


COMMANDS = {
    "run": cmd_run,
    "repl": _lazy("repl"),
    "build": cmd_build,
    "test": _lazy("testing"),
    "fmt": _lazy("fmt"),
    "doc": _lazy("docgen"),
    "new": _lazy("pkg", "cmd_new"),
    "get": _lazy("pkg", "cmd_get"),
    "check": cmd_check,
    "debug": _lazy("debugger"),
    "lsp": _lazy("lsp"),
    "version": lambda V, a: print(version_text(V)) or 0,
    "help": cmd_help,
}
ALIASES = {"--help": "help", "-h": "help", "--version": "version", "-v": "version",
           "format": "fmt", "install": "get"}


def main(V, argv):
    """Dispatch a command. Returns the process exit code."""
    if not argv:
        return COMMANDS["repl"](V, [])
    command, rest = argv[0], argv[1:]
    command = ALIASES.get(command, command)
    if command in COMMANDS:
        if rest and rest[0] in ("--help", "-h") and command not in ("run", "debug"):
            print(HELP.get(command, ""))
            return 0
        return COMMANDS[command](V, rest) or 0
    if command.endswith(".va") or os.path.isfile(command):
        return run_program(V, command, rest)       # the old form: vanta program.va [args]
    print(f"Oops! '{command}' is not a Vanta command or a file.")
    _suggest_command(command)
    return 1
