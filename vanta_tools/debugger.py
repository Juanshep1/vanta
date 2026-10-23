"""`vanta debug FILE` — a line debugger.

It installs vanta.DEBUG_HOOK, which the interpreter calls before every statement
(compile_block picks the hook up when it compiles, so normal runs pay nothing).
The call stack comes from the interpreter's own frames: every call_function /
call_method frame is a Vanta call, and the debug block runner just above it knows
which line made the call."""

import os
import sys

HELP = """\
  break N  (b N)      stop at line N; break FILE:N for another file; 'break' lists them
  delete N            remove the breakpoint at line N ('delete' removes all)
  step     (s)        run one line, going into function calls
  next     (n)        run one line, stepping over function calls
  finish   (f)        run until the current function gives back
  continue (c)        run to the next breakpoint
  print X  (p X)      show the value of an expression
  vars     (v)        show the variables in scope
  where    (bt)       show the call stack
  list     (l)        show the code around the current line
  quit     (q)        stop the program"""


class Quit(Exception):
    pass


class Debugger:
    def __init__(self, V, main_path, inp=None, out=None):
        self.V = V
        self.main = os.path.abspath(main_path)
        self.breaks = set()            # (abs file, line)
        self.mode = "step"             # step | next | finish | continue
        self.target_depth = 0
        self.inp = inp or sys.stdin
        self.out = out or sys.stdout
        self.sources = {}

    # ------------------------------------------------------------ helpers
    def say(self, text=""):
        print(text, file=self.out)
        self.out.flush()

    def source(self, path):
        if path not in self.sources:
            try:
                with open(path, encoding="utf-8") as f:
                    self.sources[path] = f.read().splitlines()
            except (OSError, TypeError):
                self.sources[path] = []
        return self.sources[path]

    def stack(self):
        """Vanta call stack, outermost first: [(function name or None, file, line)]."""
        frames = []
        f = sys._getframe(2)
        pending_call = None            # function name whose call site we're looking for
        current = []
        while f is not None:
            code = f.f_code
            if code.co_name == "run_dbg" and "lineno" in f.f_locals:
                current.append((f.f_locals.get("src_file") or self.main, f.f_locals["lineno"]))
            elif code.co_name in ("call_function", "call_method") and "fn" in f.f_locals:
                fn = f.f_locals["fn"]
                frames.append((fn.name, current[0] if current else (fn.file, 0)))
                current = []
            f = f.f_back
        frames.append((None, current[0] if current else (self.main, 0)))
        frames.reverse()
        return [(name, loc[0], loc[1]) for name, loc in frames]

    def depth(self):
        n, f = 0, sys._getframe(2)
        while f is not None:
            if f.f_code.co_name in ("call_function", "call_method"):
                n += 1
            f = f.f_back
        return n

    def show_line(self, path, line):
        lines = self.source(path)
        text = lines[line - 1] if 0 < line <= len(lines) else ""
        self.say(f"{os.path.basename(path or '?')}:{line}  {text.strip()}")

    def resolve_break(self, arg):
        if ":" in arg:
            fname, _, num = arg.rpartition(":")
            path = os.path.abspath(fname)
        else:
            path, num = self.main, arg
        return path, int(num)

    # ------------------------------------------------------------ the hook
    def hook(self, line, env, src_file):
        path = src_file or self.main
        stop = False
        if (path, line) in self.breaks:
            stop = True
            if self.mode == "continue":
                self.say(f"breakpoint at line {line}")
        elif self.mode == "step":
            stop = True
        elif self.mode == "next":
            stop = self.depth() <= self.target_depth
        elif self.mode == "finish":
            stop = self.depth() < self.target_depth
        if stop:
            self.prompt(line, env, path)

    def prompt(self, line, env, path):
        self.show_line(path, line)
        while True:
            self.out.write("(vdb) ")
            self.out.flush()
            raw = self.inp.readline()
            if not raw:
                raise Quit()
            cmd, _, arg = raw.strip().partition(" ")
            arg = arg.strip()
            if cmd in ("s", "step"):
                self.mode = "step"
                return
            if cmd in ("n", "next"):
                self.mode, self.target_depth = "next", self.depth()
                return
            if cmd in ("f", "finish"):
                self.mode, self.target_depth = "finish", self.depth()
                return
            if cmd in ("c", "continue", "cont"):
                self.mode = "continue"
                return
            if cmd in ("q", "quit", "exit"):
                raise Quit()
            if cmd in ("b", "break"):
                if not arg:
                    if not self.breaks:
                        self.say("no breakpoints")
                    for p, n in sorted(self.breaks):
                        self.say(f"  {os.path.basename(p)}:{n}")
                    continue
                try:
                    p, n = self.resolve_break(arg)
                except ValueError:
                    self.say("use: break LINE  or  break FILE:LINE")
                    continue
                self.breaks.add((p, n))
                self.say(f"breakpoint at {os.path.basename(p)}:{n}")
                continue
            if cmd in ("d", "delete"):
                if not arg:
                    self.breaks.clear()
                    self.say("all breakpoints removed")
                    continue
                try:
                    self.breaks.discard(self.resolve_break(arg))
                    self.say(f"removed breakpoint {arg}")
                except ValueError:
                    self.say("use: delete LINE")
                continue
            if cmd in ("p", "print"):
                self.print_expr(arg, env)
                continue
            if cmd in ("v", "vars", "locals"):
                self.print_vars(env)
                continue
            if cmd in ("bt", "where", "w", "backtrace"):
                for i, (name, p, n) in enumerate(self.stack()):
                    where = "top level" if name is None else name
                    self.say(f"  #{i} {where} at {os.path.basename(p or '?')}:{n}")
                continue
            if cmd in ("l", "list"):
                lines = self.source(path)
                for k in range(max(1, line - 4), min(len(lines), line + 4) + 1):
                    mark = "->" if k == line else ("b " if (path, k) in self.breaks else "  ")
                    self.say(f"{mark}{k:4} {lines[k - 1]}")
                continue
            if cmd in ("h", "help", "?"):
                self.say(HELP)
                continue
            if cmd == "":
                continue
            self.say(f"unknown command '{cmd}' (type help)")

    def print_expr(self, text, env):
        V = self.V
        if not text:
            self.say("use: print EXPRESSION")
            return
        try:
            value = V.compile_expr(V.parse_expr_text(text, 0))(env)
            self.say(V.json.dumps(value) if isinstance(value, str) else V.display(value))
        except V.VantaError as e:
            self.say(f"error: {V.clean_message(str(e))}")

    def print_vars(self, env):
        V = self.V
        e, shown = env, set()
        while e is not None:
            scope = "globals" if e is V.GLOBAL_ENV else "locals"
            rows = [(k, v) for k, v in e.vars.items() if k not in shown and k not in ("pi", "e", "super")]
            if rows:
                self.say(f"  {scope}:")
                for k, v in rows:
                    shown.add(k)
                    val = V.json.dumps(v) if isinstance(v, str) else V.display(v)
                    if len(val) > 70:
                        val = val[:67] + "..."
                    self.say(f"    {k} = {val}")
            e = e.parent


def main(V, args):
    """vanta debug FILE [ARGS]"""
    from . import errors
    if not args:
        print("Usage: vanta debug FILE [ARGS...]")
        return 1
    path = args[0]
    try:
        with open(path, encoding="utf-8") as f:
            source = f.read()
    except OSError as e:
        print(f"Oops! could not open {path}: {e.strerror or e}")
        return 1
    V.PROGRAM_ARGS = args[1:]
    dbg = Debugger(V, path)
    # The debugger reads commands from the terminal; the program's own `ask` uses stdin too.
    if not sys.stdin.isatty():
        dbg.inp = sys.stdin
    print(f"Vanta debugger - {path}. Type help for commands; 'c' runs to a breakpoint.")
    V.DEBUG_HOOK = dbg.hook
    try:
        V.run_source(source, path)
        print("(program finished)")
        return 0
    except Quit:
        print("(stopped)")
        return 0
    except V.VantaError as e:
        errors.report(V, e, path)
        return 1
    finally:
        V.DEBUG_HOOK = None
