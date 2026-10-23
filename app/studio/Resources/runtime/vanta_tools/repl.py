"""`vanta repl` — the interactive prompt.

Line editing and history (readline; saved in ~/.vanta_history), blocks that keep
reading until their `end`, expression values shown automatically, tab completion of
names, and a few colon commands: :help :load :vars :reset :quit."""

import os
import sys

HISTORY = os.path.join(os.path.expanduser("~"), ".vanta_history")

HELP = """\
Type Vanta code and press Enter. Expressions show their value:
  vanta> 2 + 3
  5
Blocks (if, repeat, while, for each, to, type, match, attempt, test) keep going
until their 'end'. :cancel (or Ctrl-C) abandons a half-typed block.

  :help            this message
  :load FILE       run a file into the session
  :vars            list the variables and functions you've made
  :reset           forget everything
  :doc NAME        show what a builtin does
  :quit            leave (also: bye, exit, Ctrl-D)"""


def shown(V, value):
    """How the REPL shows a value: text in quotes, so "5" and 5 look different."""
    if isinstance(value, str):
        return V.json.dumps(value, ensure_ascii=False)
    return V.display(value)


def block_delta(V, text):
    """+1 if the line opens a block, -1 for `end`, 0 otherwise."""
    from .fmt import opens_block, first_word
    t = text.strip()
    if not t or t.startswith("#"):
        return 0
    head = first_word(t)
    if head == "end":
        return -1
    return 1 if opens_block(V, t, head) else 0


def setup_readline(V):
    try:
        import readline
    except ImportError:
        return None
    try:
        readline.read_history_file(HISTORY)
    except (OSError, IOError):
        pass
    readline.set_history_length(2000)

    def complete(text, state):
        names = sorted(set(V.BUILTINS) | set(V.GLOBAL_ENV.vars) | set(V.RESERVED))
        matches = [n for n in names if n.startswith(text) and not n.startswith("__")]
        return matches[state] if state < len(matches) else None

    readline.set_completer(complete)
    if "libedit" in (readline.__doc__ or ""):
        readline.parse_and_bind("bind ^I rl_complete")
    else:
        readline.parse_and_bind("tab: complete")
    return readline


def run_chunk(V, program, report):
    """Run some code; if its last statement is a bare expression, show its value."""
    try:
        stmts = V.parse_program(V.load_lines(program), keep_tests=False)
    except V.VantaError as e:
        report(e)
        return
    show_last = bool(stmts) and stmts[-1][0] == "expr"
    try:
        if show_last:
            V.compile_block(stmts[:-1])(V.GLOBAL_ENV)
            value = V.compile_expr(stmts[-1][2])(V.GLOBAL_ENV)
            if value is not None:
                print(shown(V, value))
        else:
            V.compile_block(stmts)(V.GLOBAL_ENV)
    except V.VantaError as e:
        report(e)
    except (V.BreakLoop, V.ContinueLoop):
        print("Oops! 'stop'/'skip' only work inside a loop")
    except V.ReturnSignal:
        print("Oops! 'give back' only works inside a function")
    except RecursionError:
        print("Oops! too much recursion")
    except KeyboardInterrupt:
        print("\ninterrupted.")


def show_vars(V):
    rows = []
    for name, value in V.GLOBAL_ENV.vars.items():
        if name in ("pi", "e"):
            continue
        rows.append((name, V.type_name(value), shown(V, value)))
    if not rows:
        print("(nothing yet — make something with: let NAME be VALUE)")
        return
    width = max(len(r[0]) for r in rows)
    for name, kind, value in rows:
        if len(value) > 60:
            value = value[:57] + "..."
        print(f"  {name.ljust(width)}  {kind:<9} {value}")


def main(V, args):
    from . import errors
    interactive = sys.stdin.isatty()
    rl = setup_readline(V) if interactive else None
    print(f"Vanta {V.VERSION} - type Vanta code, :help for help, :quit to leave.")
    report = lambda e: errors.report(V, e, None)
    V.CURRENT_FILE = None
    buffer, depth = [], 0
    while True:
        try:
            line = input("...    " if buffer else "vanta> ")
        except EOFError:
            print()
            break
        except KeyboardInterrupt:
            print("\n(cancelled)" if buffer else "\n(use :quit or Ctrl-D to leave)")
            buffer, depth = [], 0
            continue
        text = line.strip()
        if not buffer:
            if text in ("bye", "exit", "quit", ":quit", ":q", ":exit"):
                break
            if text == "" or text.startswith("#"):
                continue
            if text.startswith(":"):
                cmd, _, arg = text[1:].partition(" ")
                arg = arg.strip()
                if cmd in ("help", "h", "?"):
                    print(HELP)
                elif cmd == "vars":
                    show_vars(V)
                elif cmd == "reset":
                    V.reset_runtime()
                    print("(fresh start)")
                elif cmd == "load":
                    if not arg:
                        print("Usage: :load FILE")
                        continue
                    try:
                        with open(arg, encoding="utf-8") as f:
                            src = f.read()
                    except OSError as e:
                        print(f"Oops! could not open {arg}: {e.strerror or e}")
                        continue
                    try:
                        V.run_source(src, arg)
                        print(f"(loaded {arg})")
                    except V.VantaError as e:
                        errors.report(V, e, arg)
                    finally:
                        V.CURRENT_FILE = None
                elif cmd == "doc":
                    from .builtin_docs import describe
                    print(describe(V, arg) or f"no builtin called '{arg}'")
                elif cmd == "cancel":
                    pass
                else:
                    print(f"Oops! unknown command :{cmd} (try :help)")
                continue
        if buffer and text == "":
            continue
        if buffer and text == ":cancel":
            print("(block cancelled)")
            buffer, depth = [], 0
            continue
        depth += block_delta(V, text)
        buffer.append(line)
        if depth <= 0:
            program = "\n".join(buffer)
            buffer, depth = [], 0
            run_chunk(V, program, report)
    if rl is not None:
        try:
            rl.write_history_file(HISTORY)
        except (OSError, IOError):
            pass
    return 0
