"""`vanta test` — runs the plain-English test blocks in Vanta files.

    to add(a, b)
        give back a + b
    end

    test "adds numbers"
        expect add(2, 2) is 4
        expect add(2, 2) is not 5
        expect [1, 2, 3] contains 2
        expect add(1, "x") fails
    end

`vanta run` ignores test blocks; `vanta test` runs the file's other top-level code once
(the setup), then every test block in a fresh scope, and prints a summary with counts and
timings. A file with no test blocks counts as one test that passes if it runs cleanly.
"""

import contextlib
import glob
import io
import os
import subprocess
import sys
import tempfile
import time

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def _color(on):
    if not on:
        return {"g": "", "r": "", "y": "", "d": "", "x": ""}
    return {"g": GREEN, "r": RED, "y": YELLOW, "d": DIM, "x": RESET}


def has_test_blocks(path):
    try:
        with open(path, encoding="utf-8") as f:
            return any(line.lstrip().startswith('test "') for line in f)
    except (OSError, UnicodeDecodeError):
        return False


def discover(targets):
    """Files to test: given files as-is; in a directory, *_test.va, test_*.va and any
    .va file that contains test blocks."""
    if not targets:
        targets = ["tests"] if os.path.isdir("tests") else ["."]
    files = []
    for t in targets:
        if os.path.isdir(t):
            found = []
            for p in sorted(glob.glob(os.path.join(t, "**", "*.va"), recursive=True)):
                if "/packages/" in p.replace(os.sep, "/"):
                    continue
                base = os.path.basename(p)
                if base.startswith("test_") or base.endswith("_test.va") or has_test_blocks(p):
                    found.append(p)
            files.extend(found)
        elif os.path.isfile(t):
            files.append(t)
        else:
            raise FileNotFoundError(t)
    return files


class Result:
    def __init__(self, name, ok, ms, message="", output=""):
        self.name, self.ok, self.ms, self.message, self.output = name, ok, ms, message, output


def run_file(V, path, name_filter=None):
    """Run one file's tests in the interpreter. Returns (results, file_error_or_None)."""
    V.reset_runtime()
    abspath = os.path.abspath(path)
    V.CURRENT_FILE = abspath
    try:
        with open(path, encoding="utf-8") as f:
            source = f.read()
        stmts = V.parse_program(V.load_lines(source), keep_tests=True)
    except (OSError, V.VantaError) as e:
        return [], f"{e}"
    tests = [s for s in stmts if s[0] == "test"]
    setup = [s for s in stmts if s[0] != "test"]
    results = []
    if not tests:                       # a plain file: it passes if it runs without an error
        buf = io.StringIO()
        t0 = time.perf_counter()
        try:
            with contextlib.redirect_stdout(buf):
                V.compile_block(setup)(V.GLOBAL_ENV)
            ok, msg = True, ""
        except V.VantaError as e:
            ok, msg = False, str(e)
        except (V.BreakLoop, V.ContinueLoop, V.ReturnSignal):
            ok, msg = False, "'stop'/'skip'/'give back' used outside a loop or function"
        results.append(Result("(runs without errors)", ok, (time.perf_counter() - t0) * 1000, msg, buf.getvalue()))
        return results, None
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            V.compile_block(setup)(V.GLOBAL_ENV)
    except V.VantaError as e:
        return [], f"the code outside the tests failed: {e}" + (f"\n{buf.getvalue()}" if buf.getvalue() else "")
    for t in tests:
        _, lineno, name, body = t
        if name_filter and name_filter.lower() not in name.lower():
            continue
        out = io.StringIO()
        t0 = time.perf_counter()
        try:
            code = V.compile_block(body)
            with contextlib.redirect_stdout(out):
                code(V.Environment(V.GLOBAL_ENV))
            ok, msg = True, ""
        except V.VantaError as e:
            ok, msg = False, str(e)
        except (V.BreakLoop, V.ContinueLoop):
            ok, msg = False, "'stop'/'skip' used outside a loop"
        except RecursionError:
            ok, msg = False, "too much recursion (a function that never stops calling itself?)"
        results.append(Result(name, ok, (time.perf_counter() - t0) * 1000, msg, out.getvalue()))
    return results, None


# ----------------------------------------------------------------- native tests

NATIVE_PRELUDE = r'''
to __vanta_show(v)
    if type_of(v) is "text"
        give back "\"" + v + "\""
    end
    give back text(v)
end
to __vtest_expect(kind, a, b, src)
    let where be "expect " + src + ": "
    if kind is "fails"
        let failed be no
        let got be nothing
        let msg be ""
        attempt
            change got to a()
        rescue problem
            change failed to yes
            change msg to problem
        end
        if not failed
            fail(where + "expected an error, but it gave back " + __vanta_show(got))
        end
        if b is not nothing and not contains(msg, text(b))
            fail(where + "the error should mention " + __vanta_show(text(b)) + ", but it was " + __vanta_show(msg))
        end
        give back nothing
    end
    if kind is "=="
        if a is not b
            fail(where + "expected " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is "!="
        if a is b
            fail(where + "expected anything but " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is ">"
        if not (a > b)
            fail(where + "expected a value over " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is "<"
        if not (a < b)
            fail(where + "expected a value under " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is ">="
        if not (a >= b)
            fail(where + "expected a value at least " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is "<="
        if not (a <= b)
            fail(where + "expected a value at most " + __vanta_show(b) + ", got " + __vanta_show(a))
        end
    otherwise if kind is "contains"
        let found be no
        if type_of(a) is "text"
            change found to contains(a, text(b))
        otherwise
            change found to contains(a, b)
        end
        if not found
            fail(where + __vanta_show(a) + " does not contain " + __vanta_show(b))
        end
    otherwise if kind is "in"
        if not (a is in b)
            fail(where + __vanta_show(a) + " is not in " + __vanta_show(b))
        end
    otherwise if kind is "notin"
        if a is in b
            fail(where + __vanta_show(a) + " is in " + __vanta_show(b))
        end
    otherwise if kind is "isa"
        if not (a is a b)
            fail(where + "got " + __vanta_show(a) + " (a " + type_of(a) + ")")
        end
    otherwise
        if not a
            fail(where + "it was " + __vanta_show(a))
        end
    end
end
to __vanta_run_test(name, f)
    let t0 be now_ms()
    attempt
        f()
        say "@@vanta-test PASS " + text(now_ms() - t0) + " " + name
    rescue problem
        say "@@vanta-test FAIL " + text(now_ms() - t0) + " " + name + "\t" + problem
    end
end
'''


def _rename(node, V):
    """expect lines call the interpreter builtin __vanta_expect; native test builds call
    the Vanta version from NATIVE_PRELUDE instead."""
    if isinstance(node, tuple):
        if node == ("name", "__vanta_expect"):
            return ("name", "__vtest_expect")
        return tuple(_rename(x, V) for x in node)
    if isinstance(node, list):
        return [_rename(x, V) for x in node]
    if isinstance(node, dict):
        return {k: _rename(v, V) for k, v in node.items()}
    if isinstance(node, V.Function):
        node.body = _rename(node.body, V)
    return node


def native_program(V, path, name_filter=None):
    """The file's statements rewritten for a native test build: each test block becomes a
    function, followed by the expect helpers and calls that run each test."""
    with open(path, encoding="utf-8") as f:
        stmts = V.parse_program(V.load_lines(f.read()), keep_tests=True)
    out, calls = [], []
    for s in stmts:
        if s[0] != "test":
            out.append(s)
            continue
        _, lineno, name, body = s
        if name_filter and name_filter.lower() not in name.lower():
            continue
        fname = f"__vanta_test_{len(calls)}"
        out.append(("func", lineno, fname, [], body))
        calls.append((name, fname))
    if not calls:
        return None
    out = [_rename(s, V) for s in out]
    out = V.parse_program(V.load_lines(NATIVE_PRELUDE)) + out
    runner = "\n".join(f"__vanta_run_test({V.json.dumps(n)}, {fn})" for n, fn in calls)
    out += V.parse_program(V.load_lines(runner))
    return out


def run_file_native(V, path, name_filter=None):
    """Compile one file's tests with the native compiler and run them."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(here, "native"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("vantac_for_tests", os.path.join(here, "native", "vantac.py"))
    vantac = importlib.util.module_from_spec(spec)
    saved_argv, sys.argv = sys.argv, [sys.argv[0]]
    try:
        spec.loader.exec_module(vantac)
    finally:
        sys.argv = saved_argv
    W = vantac.vanta                     # the parser instance the compiler uses
    try:
        program = native_program(W, path, name_filter)
    except W.VantaError as e:
        return [], str(e)
    if program is None:
        return [], None
    main = os.path.abspath(path)
    base = vantac.Compiler

    class TestCompiler(base):
        def load(self, p):
            if os.path.abspath(p) == main:
                return program
            return base.load(self, p)

    vantac.Compiler = TestCompiler
    exe = os.path.join(tempfile.mkdtemp(prefix="vanta-test-"), os.path.splitext(os.path.basename(path))[0])
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            vantac.build(path, exe)
    except SystemExit:
        return [], "native build failed: " + buf.getvalue().strip()
    r = subprocess.run([exe], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    results, pending = [], []
    for line in r.stdout.splitlines():
        if line.startswith("@@vanta-test "):
            _, status, ms, rest = line.split(" ", 3)
            name, _, msg = rest.partition("\t")
            results.append(Result(name, status == "PASS", float(ms), msg, "\n".join(pending)))
            pending = []
        else:
            pending.append(line)
    if r.returncode != 0:
        tail = "\n".join(pending) or r.stderr.strip()
        return results, f"the native test program stopped with an error: {tail}"
    return results, None


# ----------------------------------------------------------------- command

def main(V, args):
    """vanta test [files or folders] [--native] [-v] [--filter TEXT]"""
    native, verbose, name_filter, targets = False, False, None, []
    color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--native":
            native = True
        elif a in ("-v", "--verbose"):
            verbose = True
        elif a in ("--filter", "-k"):
            i += 1
            name_filter = args[i] if i < len(args) else None
        elif a == "--no-color":
            color = False
        else:
            targets.append(a)
        i += 1
    c = _color(color)
    try:
        files = discover(targets)
    except FileNotFoundError as e:
        print(f"Oops! no such file or folder: {e}")
        return 1
    if not files:
        print("No test files found (looked for test_*.va, *_test.va and files with test blocks).")
        return 1
    passed = failed = errors = 0
    t_start = time.perf_counter()
    for path in files:
        if native:
            results, file_error = run_file_native(V, path, name_filter)
        else:
            results, file_error = run_file(V, path, name_filter)
        print(f"{path}")
        for r in results:
            if r.ok:
                passed += 1
                print(f"  {c['g']}PASS{c['x']}  {r.name} {c['d']}({r.ms:.1f} ms){c['x']}")
            else:
                failed += 1
                print(f"  {c['r']}FAIL{c['x']}  {r.name} {c['d']}({r.ms:.1f} ms){c['x']}")
                for line in r.message.splitlines():
                    print(f"        {line}")
            if r.output and (verbose or not r.ok):
                for line in r.output.rstrip("\n").splitlines():
                    print(f"        {c['d']}| {line}{c['x']}")
        if file_error:
            errors += 1
            print(f"  {c['y']}ERROR{c['x']} {file_error}")
    total_ms = (time.perf_counter() - t_start) * 1000
    summary = f"{passed} passed, {failed} failed"
    if errors:
        summary += f", {errors} file error{'s' if errors != 1 else ''}"
    shown = f"{total_ms:.0f} ms" if total_ms < 10000 else f"{total_ms / 1000:.1f} s"
    col = c['g'] if not (failed or errors) else c['r']
    print(f"\n{col}{summary}{c['x']} in {shown} ({len(files)} file{'s' if len(files) != 1 else ''})")
    return 1 if (failed or errors) else 0
