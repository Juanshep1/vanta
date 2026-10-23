"""`vanta debug FILE` — a line debugger.

It installs vanta.DEBUG_HOOK, which the interpreter calls before every statement
(compile_block picks the hook up when it compiles, so normal runs pay nothing).
The call stack comes from the interpreter's own frames: every call_function /
call_method frame is a Vanta call, and the debug block runner just above it knows
which line made the call."""

import json
import os
import queue
import sys
import threading

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


# ---------------------------------------------------------------- machine mode

EVENT_MARK = "\x1e"           # an event line starts with ASCII record-separator, then JSON


class _QueuedInput:
    """Stands in for sys.stdin in --json mode: the program's `ask` reads lines the
    IDE sent as {"cmd": "input"} while the debugger keeps reading commands."""
    def __init__(self, q):
        self.q = q

    def readline(self):
        line = self.q.get()
        return "" if line is None else line + "\n"

    def isatty(self):
        return False

    def fileno(self):
        raise OSError("debugger input has no file descriptor")


class JsonDebugger(Debugger):
    """`vanta debug --json FILE`: the same debugger driven by an IDE.

    Commands arrive on stdin as JSON lines, read by a thread so breakpoints can
    change (and `pause` work) while the program runs. Events go to stdout as
    lines that start with \\x1e, so they interleave safely with the program's
    own output:

      -> {"cmd": "setBreakpoints", "file": F, "breakpoints": [{"line": 3, "condition": "i > 2"}]}
      -> {"cmd": "start", "stopOnEntry": false}
      -> continue | next | step | finish | pause | quit
      -> {"cmd": "stack", "seq": 1}            <- {"event": "response", "seq": 1, "body": [...]}
      -> {"cmd": "scopes", "frame": 0, "seq": 2}
      -> {"cmd": "variables", "ref": 7, "seq": 3}
      -> {"cmd": "evaluate", "expr": "n + 1", "frame": 0, "seq": 4}
      -> {"cmd": "input", "text": "Sam"}       (an answer for `ask`)
      <- ready | stopped {reason, file, line, stack} | continued | error {...} | exited {code}
    """

    def __init__(self, V, main_path, raw_in=None, out=None):
        super().__init__(V, main_path, out=out)
        self.breaks = {}               # (abs file, line) -> condition text or None
        self.mode = "continue"
        self.pause_requested = False
        self.commands = queue.Queue()
        self.inputs = queue.Queue()
        self.raw_in = raw_in or sys.stdin
        self.refs = {}
        self.frames = []               # [(name, file, line, env)] while stopped, outermost first
        self.lock = threading.Lock()
        self.main = os.path.realpath(self.main)
        self._real = {}                # src_file -> realpath (IDEs may send /tmp for /private/tmp)

    # ------------------------------------------------------------ io
    def emit(self, event, **body):
        body["event"] = event
        with self.lock:
            self.out.flush()
            self.out.write(EVENT_MARK + json.dumps(body, default=str) + "\n")
            self.out.flush()

    def reader(self):
        for raw in self.raw_in:
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                self.inputs.put(raw)              # a bare line is an answer for `ask`
                continue
            cmd = msg.get("cmd")
            if cmd == "input":
                self.inputs.put(str(msg.get("text", "")))
            elif cmd == "setBreakpoints":
                self.set_breakpoints(msg)
                if "seq" in msg:
                    self.emit("response", seq=msg["seq"], body=self.breakpoint_list())
            elif cmd == "pause":
                self.pause_requested = True
            else:
                self.commands.put(msg)
        self.inputs.put(None)
        self.commands.put({"cmd": "quit"})

    def set_breakpoints(self, msg):
        path = os.path.realpath(msg.get("file") or self.main)
        keep = {k: v for k, v in self.breaks.items() if k[0] != path}
        for b in msg.get("breakpoints", []):
            if isinstance(b, int):
                b = {"line": b}
            cond = (b.get("condition") or "").strip() or None
            keep[(path, int(b["line"]))] = cond
        self.breaks = keep

    def breakpoint_list(self):
        return [{"file": p, "line": n, "condition": c} for (p, n), c in sorted(self.breaks.items())]

    # ------------------------------------------------------------ the hook
    def hook(self, line, env, src_file):
        path = self._real.get(src_file)
        if path is None:
            path = self._real[src_file] = os.path.realpath(src_file) if src_file else self.main
        key = (path, line)
        reason = None
        if key in self.breaks:
            cond = self.breaks.get(key)
            if cond is None or self.condition_true(cond, env, key):
                reason = "breakpoint"
        if reason is None:
            if self.pause_requested:
                reason = "pause"
            elif self.mode == "step":
                reason = "step"
            elif self.mode == "next" and self.depth() <= self.target_depth:
                reason = "step"
            elif self.mode == "finish" and self.depth() < self.target_depth:
                reason = "step"
        if reason:
            self.pause_requested = False
            self.stopped(reason, line, env, path)

    def condition_true(self, cond, env, key):
        V = self.V
        try:
            return V.truthy(V.compile_expr(V.parse_expr_text(cond, 0))(env))
        except Exception as e:                 # noqa: BLE001 - a broken condition stops, with a note
            msg = V.clean_message(str(e)) if isinstance(e, V.VantaError) else str(e)
            self.emit("output", text=f"breakpoint condition '{cond}' failed: {msg}\n")
            return True

    def collect_frames(self):
        frames, current = [], []
        f = sys._getframe(3)
        while f is not None:
            code = f.f_code
            if code.co_name == "run_dbg" and "lineno" in f.f_locals:
                current.append((f.f_locals.get("src_file") or self.main, f.f_locals["lineno"], f.f_locals.get("env")))
            elif code.co_name in ("call_function", "call_method") and "fn" in f.f_locals:
                fn = f.f_locals["fn"]
                loc = current[0] if current else (fn.file, 0, None)
                frames.append((fn.name, loc[0], loc[1], loc[2]))
                current = []
            f = f.f_back
        loc = current[0] if current else (self.main, 0, None)
        frames.append((None, loc[0], loc[1], loc[2]))
        frames.reverse()
        return frames

    def stopped(self, reason, line, env, path):
        self.frames = self.collect_frames()
        if self.frames:                         # the innermost frame is exactly where we are
            name = self.frames[-1][0]
            self.frames[-1] = (name, path, line, env)
        self.refs = {}
        self.emit("stopped", reason=reason, file=path, line=line, stack=self.stack_body())
        while True:
            msg = self.commands.get()
            cmd = msg.get("cmd")
            seq = msg.get("seq")
            if cmd in ("continue", "c"):
                self.mode = "continue"
            elif cmd in ("step", "s", "stepIn"):
                self.mode = "step"
            elif cmd in ("next", "n", "stepOver"):
                self.mode, self.target_depth = "next", self.depth()
            elif cmd in ("finish", "f", "stepOut"):
                self.mode, self.target_depth = "finish", self.depth()
            elif cmd in ("quit", "q", "stop"):
                raise Quit()
            elif cmd == "stack":
                self.emit("response", seq=seq, body=self.stack_body())
                continue
            elif cmd == "scopes":
                self.emit("response", seq=seq, body=self.scopes(int(msg.get("frame", 0))))
                continue
            elif cmd == "variables":
                self.emit("response", seq=seq, body=self.children(self.refs.get(int(msg.get("ref", 0)))))
                continue
            elif cmd == "evaluate":
                self.emit("response", seq=seq, body=self.evaluate(msg.get("expr", ""), int(msg.get("frame", 0))))
                continue
            else:
                self.emit("response", seq=seq, body={"error": f"unknown command '{cmd}'"})
                continue
            self.frames, self.refs = [], {}
            self.emit("continued")
            return

    # ------------------------------------------------------------ inspection
    def stack_body(self):
        """Innermost first, like every IDE shows it."""
        out = []
        for i, (name, p, n, _) in enumerate(reversed(self.frames)):
            out.append({"id": i, "name": name or "top level", "file": p, "line": n})
        return out

    def frame_env(self, index):
        frames = list(reversed(self.frames))
        if 0 <= index < len(frames) and frames[index][3] is not None:
            return frames[index][3]
        return self.V.GLOBAL_ENV

    def ref_for(self, value):
        V = self.V
        if isinstance(value, (list, dict, bytearray, V.VantaInstance, V.VantaSet, V.VantaModule, _Scope)):
            if isinstance(value, (list, dict, bytearray)) and not value:
                return 0
            ref = len(self.refs) + 1
            self.refs[ref] = value
            return ref
        return 0

    def describe(self, name, value):
        V = self.V
        if isinstance(value, str):
            shown = json.dumps(value, ensure_ascii=False)
        else:
            try:
                shown = V.display(value)
            except Exception as e:             # noqa: BLE001 - a broken text() method
                shown = f"<{type(e).__name__}>"
        if len(shown) > 200:
            shown = shown[:197] + "..."
        count = len(value) if isinstance(value, (list, dict, bytearray)) else None
        if isinstance(value, V.VantaSet):
            count = len(list(value.values()))
        return {"name": str(name), "value": shown, "type": self.type_name(value),
                "ref": self.ref_for(value), "count": count}

    def type_name(self, value):
        V = self.V
        if value is None:
            return "nothing"
        if isinstance(value, bool):
            return "yes/no"
        if isinstance(value, (int, float)):
            return "number"
        if isinstance(value, str):
            return "text"
        if isinstance(value, list):
            return "list"
        if isinstance(value, dict):
            return "map"
        if isinstance(value, bytearray):
            return "bytes"
        if isinstance(value, V.VantaInstance):
            return value.vtype.name
        if isinstance(value, (V.Function, V.Builtin, V.BoundMethod)):
            return "function"
        if isinstance(value, V.VantaSet):
            return "set"
        if isinstance(value, V.VantaModule):
            return "module"
        if isinstance(value, V.VantaType):
            return "type"
        return type(value).__name__.lstrip("_").lower()

    def env_rows(self, env, stop_at_global):
        V = self.V
        rows, seen = [], set()
        e = env
        while e is not None:
            if stop_at_global and e is V.GLOBAL_ENV:
                break
            for k, v in e.vars.items():
                if k in seen or k in ("pi", "e", "super"):
                    continue
                seen.add(k)
                rows.append(self.describe(k, v))
            e = e.parent
        return rows

    def scopes(self, index):
        V = self.V
        env = self.frame_env(index)
        out = []
        if env is not V.GLOBAL_ENV:
            out.append({"name": "Locals", "ref": self.ref_for(_Scope(env, True))})
        out.append({"name": "Globals", "ref": self.ref_for(_Scope(V.GLOBAL_ENV, False))})
        return out

    def children(self, value):
        V = self.V
        if value is None:
            return []
        if isinstance(value, _Scope):
            return self.env_rows(value.env, value.local)
        if isinstance(value, list):
            return [self.describe(i, v) for i, v in enumerate(value[:500])]
        if isinstance(value, bytearray):
            return [self.describe(i, v) for i, v in enumerate(value[:500])]
        if isinstance(value, dict):
            rows = []
            for k, v in list(value.items())[:500]:
                k = V._unkey(k)
                rows.append(self.describe(json.dumps(k) if isinstance(k, str) else V.display(k), v))
            return rows
        if isinstance(value, V.VantaInstance):
            names = list(value.vtype.fields) + [k for k in value.attrs if k not in value.vtype.fields]
            return [self.describe(k, value.attrs.get(k)) for k in names]
        if isinstance(value, V.VantaSet):
            return [self.describe(i, v) for i, v in enumerate(list(value.values())[:500])]
        if isinstance(value, V.VantaModule):
            return [self.describe(k, value.env.vars.get(k)) for k in value.exports()]
        return []

    def evaluate(self, text, index):
        V = self.V
        text = (text or "").strip()
        if not text:
            return {"error": "nothing to evaluate"}
        env = self.frame_env(index)
        try:
            return self.describe(text, V.compile_expr(V.parse_expr_text(text, 0))(env))
        except V.VantaError as e:
            return {"error": V.clean_message(str(e))}
        except Exception as e:                 # noqa: BLE001
            return {"error": f"{type(e).__name__}: {e}"}


class _Scope:
    __slots__ = ("env", "local")

    def __init__(self, env, local):
        self.env = env
        self.local = local


def main_json(V, args):
    """vanta debug --json FILE [ARGS]"""
    from . import errors
    if not args:
        print("Usage: vanta debug --json FILE [ARGS...]")
        return 1
    path = args[0]
    out = sys.stdout
    dbg = JsonDebugger(V, path, raw_in=sys.stdin, out=out)
    try:
        with open(path, encoding="utf-8") as f:
            source = f.read()
    except OSError as e:
        dbg.emit("error", message=f"could not open {path}: {e.strerror or e}", file=None, line=None)
        dbg.emit("exited", code=1)
        return 1
    V.PROGRAM_ARGS = args[1:]
    threading.Thread(target=dbg.reader, daemon=True).start()
    sys.stdin = _QueuedInput(dbg.inputs)
    dbg.emit("ready", file=dbg.main, pid=os.getpid())
    # wait for the IDE to send breakpoints, then start
    while True:
        msg = dbg.commands.get()
        if msg.get("cmd") == "start":
            dbg.mode = "step" if msg.get("stopOnEntry") else "continue"
            break
        if msg.get("cmd") in ("quit", "q", "stop"):
            dbg.emit("exited", code=0)
            return 0
    V.DEBUG_HOOK = dbg.hook
    code = 0
    try:
        V.run_source(source, path)
    except Quit:
        pass
    except V.VantaError as e:
        code = 1
        msg = str(e)
        m = __import__("re").match(r"line (\d+): (.*)", msg, __import__("re").S)
        frames = [list(f) for f in (getattr(e, "vtrace", None) or [])]
        file = (frames[0][2] if frames and frames[0][2] else dbg.main)
        line = int(m.group(1)) if m else (frames[0][0] if frames else None)
        errors.report(V, e, path)
        sys.stderr.flush()
        dbg.emit("error", message=V.clean_message(m.group(2) if m else msg), file=os.path.abspath(file), line=line)
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 0
    finally:
        V.DEBUG_HOOK = None
    dbg.emit("exited", code=code)
    return code


def main(V, args):
    """vanta debug FILE [ARGS]"""
    from . import errors
    if args and args[0] == "--json":
        return main_json(V, args[1:])
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
