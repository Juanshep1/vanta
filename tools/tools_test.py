#!/usr/bin/env python3
"""Tests for Vanta's developer tools (the `vanta` command line, test runner, formatter,
doc generator, projects/packages, REPL, debugger, language server, error reports and
the Pygments lexer). Run directly or through run_tests.py.

    python3 tools/tools_test.py [-v] [name-filter]
"""

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VANTA = os.path.join(ROOT, "vanta.py")
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

import vanta as V                                    # noqa: E402
from vanta_tools import fmt, docgen                  # noqa: E402

VERBOSE = "-v" in sys.argv
FILTER = [a for a in sys.argv[1:] if not a.startswith("-")]
TMP = tempfile.mkdtemp(prefix="vanta-tools-test-")
results = []


def vanta(*args, stdin="", cwd=None, timeout=120):
    r = subprocess.run([sys.executable, VANTA, *args], input=stdin, capture_output=True, text=True,
                       cwd=cwd or ROOT, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def write(name, text):
    path = os.path.join(TMP, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return path


def check(cond, what):
    if not cond:
        raise AssertionError(what)


def case(fn):
    if FILTER and not any(f in fn.__name__ for f in FILTER):
        return fn
    try:
        fn()
        results.append((fn.__name__, None))
    except Exception as e:                    # noqa: BLE001
        results.append((fn.__name__, f"{type(e).__name__}: {e}"))
    return fn


# ---------------------------------------------------------------- command line

@case
def cli_version_and_help():
    code, out, _ = vanta("version")
    check(code == 0 and out.startswith("Vanta "), out)
    code, out, _ = vanta("help")
    check(code == 0 and "test [PATHS]" in out and "lsp" in out, out)
    code, out, _ = vanta("help", "test")
    check(code == 0 and "expect add(2, 2) is 4" in out, out)
    code, out, _ = vanta("test", "--help")
    check(code == 0 and "--native" in out, out)
    code, out, _ = vanta("tset")
    check(code == 1 and "did you mean 'vanta test'" in out, out)
    for cmd in ("run", "repl", "build", "test", "fmt", "doc", "new", "get", "check", "debug", "lsp",
                "version", "help"):
        code, out, _ = vanta("help", cmd)
        check(code == 0 and out.strip(), f"help {cmd}")


@case
def cli_old_forms_and_args():
    p = write("args.va", 'say "args: " + join(arguments(), ",")\n')
    for form in ([p, "a", "b"], ["run", p, "a", "b"]):
        code, out, _ = vanta(*form)
        check(code == 0 and out.strip() == "args: a,b", f"{form}: {out}")
    r = subprocess.run(["sh", os.path.join(ROOT, "vanta"), p, "x"], capture_output=True, text=True)
    check(r.stdout.strip() == "args: x", r.stdout + r.stderr)
    code, out, _ = vanta("run", os.path.join(TMP, "missing.va"))
    check(code == 1 and "could not open" in out, out)


# ---------------------------------------------------------------- error reports

@case
def error_report_with_caret_hint_and_stack():
    p = write("err.va", "let total be 10\n\nto price(n)\n    let tax be 2\n    give back totl + tax * n\nend\n\n"
                        "to outer()\n    give back price(3)\nend\n\nsay \"start\"\nsay outer()\n")
    code, out, err = vanta("run", p)
    check(code == 1, "exit code")
    check(out.strip().splitlines() == ["start", "Oops! line 5: I don't know what 'totl' is yet"], out)
    check("err.va:5" in err, err)
    check("    give back totl + tax * n" in err and "              ^^^^" in err, err)
    check("did you mean 'total'?" in err, err)
    check("line 13, at the top level" in err and "line 9, in outer" in err and "line 5, in price" in err, err)


@case
def error_in_imported_module_names_the_file():
    write("mod/helper.va", "to boom(x)\n    give back x + nothing\nend\n")
    p = write("usemod.va", 'import "mod/helper.va"\nsay boom(1)\n')
    code, out, err = vanta("run", p, cwd=TMP)
    check(code == 1 and "line 2:" in out, out)
    check("helper.va:2" in err and "in boom" in err and "usemod.va line 2, at the top level" in err, err)


@case
def error_hint_for_misspelled_statement():
    p = write("typo.va", 'sya "hello"\n')
    code, out, err = vanta("run", p)
    check(code == 1 and "did you mean 'say'?" in err, out + err)


# ---------------------------------------------------------------- test blocks

TESTS_FIXTURE = '''to add(a, b)
    give back a + b
end

type Dog
    has name
end

say "setup output"

test "adds numbers"
    expect add(2, 2) is 4
    expect add(2, 2) is not 5
    expect add(2, 3) is at least 5
    expect [1, 2, 3] contains 2
    expect "hello" contains "ell"
    expect {"a": 1} contains "a"
    expect add(1, nothing) fails
    expect fail("boom here") fails with "boom"
    expect 2 is in [1, 2]
    expect new Dog("Rex") is a Dog
    expect add(1, 1) is 2
    for each n in [1, 2, 3]
        expect n is over 0
    end
end

test "a failing one"
    say "printed inside"
    expect add(2, 2) is 5
end

test "text values are quoted"
    expect "abc" + "d" is "abd"
end

test "an error inside a test"
    let x be nothing + 1
end
'''


@case
def test_runner_interpreter():
    p = write("math_test.va", TESTS_FIXTURE)
    code, out, _ = vanta("test", p)
    check(code == 1, "should fail")
    check("PASS  adds numbers" in out, out)
    check("FAIL  a failing one" in out and "line 30: expect add(2, 2) is 5: expected 5, got 4" in out, out)
    check("| printed inside" in out, out)
    check('expected "abd", got "abcd"' in out, out)
    check("FAIL  an error inside a test" in out, out)
    check("1 passed, 3 failed" in out and " ms (1 file)" in out, out)
    code, out, _ = vanta("test", p, "--filter", "adds")
    check(code == 0 and "1 passed, 0 failed" in out, out)
    code, out, _ = vanta("run", p)                       # run ignores the tests
    check(code == 0 and out == "setup output\n", out)


@case
def test_runner_json():
    p = write("json_test.va", TESTS_FIXTURE)
    code, out, _ = vanta("test", "--json", p)
    events = [json.loads(l[len("@@vanta-json "):]) for l in out.splitlines() if l.startswith("@@vanta-json ")]
    tests = [e for e in events if e["event"] == "test"]
    check(code == 1 and events[-1]["event"] == "done" and events[-1]["passed"] == 1, events[-1])
    ok = [t for t in tests if t["name"] == "adds numbers"][0]
    check(ok["ok"] and isinstance(ok["line"], int) and ok["ms"] >= 0, ok)
    bad = [t for t in tests if t["name"] == "a failing one"][0]
    check(not bad["ok"] and bad["message"].startswith("line 30:"), bad)
    code, out, _ = vanta("test", "--json", "--exact", "--filter", "adds", p)
    check('"passed": 0' in out and '"failed": 0' in out, out)


@case
def test_runner_messages_for_each_expect_form():
    p = write("forms_test.va", '''test "is"
    expect 1 + 1 is 3
end
test "is not"
    expect 2 is not 2
end
test "at least"
    expect 2 is at least 5
end
test "contains"
    expect [1, 2] contains 9
end
test "fails"
    expect 1 + 1 fails
end
test "fails with"
    expect fail("other") fails with "boom"
end
test "plain"
    expect 1 is over 5 or no
end
''')
    code, out, _ = vanta("test", p)
    for want in ("expected 3, got 2", "expected anything but 2, got 2", "expected a value at least 5, got 2",
                 "[1, 2] does not contain 9", "expected an error, but it gave back 2",
                 'the error should mention "boom", but it was "other"', "it was no", "0 passed, 7 failed"):
        check(want in out, f"missing {want!r} in\n{out}")


@case
def test_discovery_and_plain_files():
    d = os.path.join(TMP, "proj_tests")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "test_ok.va"), "w") as f:
        f.write('test "one"\n    expect 1 is 1\nend\n')
    with open(os.path.join(d, "plain_test.va"), "w") as f:
        f.write('assert(1 + 1 is 2)\n')
    with open(os.path.join(d, "helper.va"), "w") as f:
        f.write('say "not a test file"\n')
    code, out, _ = vanta("test", d)
    check(code == 0 and "2 passed, 0 failed" in out and "helper.va" not in out, out)


@case
def test_blocks_in_tests_folder():
    code, out, _ = vanta("test", "tests/testing_blocks.va")
    check(code == 0 and "4 passed, 0 failed" in out, out)


@case
def test_runner_native():
    if shutil.which(os.environ.get("CC", "cc")) is None:
        return
    p = write("native_test.va", TESTS_FIXTURE)
    code, out, _ = vanta("test", "--native", p, timeout=300)
    check(code == 1, out)
    check("PASS  adds numbers" in out and "FAIL  a failing one" in out, out)
    check("expect add(2, 2) is 5: expected 5, got 4" in out, out)
    check("1 passed, 3 failed" in out, out)


# ---------------------------------------------------------------- formatter

@case
def fmt_rules():
    src = ('let x be  1+2*3   # keep me\nif x>3\nsay   "big {x}"\notherwise\n  say -x\nend\n'
           'to f(a,b)\ngive back a-b\nend\nsay f( 1 , -2 )\nlet m be { "a" : 1 , "b":[1,2] }\n'
           'say m["b"][0 : 1]\n\n\n\nmatch x\nwhen 1\nsay "one"\notherwise\nsay "other"\nend\n'
           'note a note line\nlet t be """raw\n   keep    this\n"""\n')
    want = ('let x be 1 + 2 * 3   # keep me\nif x > 3\n    say "big {x}"\notherwise\n    say -x\nend\n\n'
            'to f(a, b)\n    give back a - b\nend\n\nsay f(1, -2)\nlet m be {"a": 1, "b": [1, 2]}\n'
            'say m["b"][0:1]\n\nmatch x\n    when 1\n        say "one"\n    otherwise\n        say "other"\nend\n'
            'note a note line\nlet t be """raw\n   keep    this\n"""\n')
    got, problem = fmt.format_checked(V, src)
    check(problem is None, problem)
    check(got == want, "formatted:\n" + got)
    again, _ = fmt.format_checked(V, got)
    check(again == got, "not idempotent")


@case
def fmt_every_test_and_example():
    """Formatting keeps every program's meaning, is idempotent, and formatted tests print
    exactly what the originals print."""
    files = sorted(glob.glob(os.path.join(ROOT, "tests", "**", "*.va"), recursive=True) +
                   glob.glob(os.path.join(ROOT, "examples", "*.va")) +
                   glob.glob(os.path.join(ROOT, "lib", "*.va")) +
                   glob.glob(os.path.join(ROOT, "emulator", "*.va")) +
                   glob.glob(os.path.join(ROOT, "gameboy", "*.va")))
    copy = os.path.join(TMP, "fmtcopy")
    for sub in ("tests", "examples", "lib", "emulator", "gameboy"):
        shutil.copytree(os.path.join(ROOT, sub), os.path.join(copy, sub), dirs_exist_ok=True)
    for path in files:
        with open(path) as f:
            src = f.read()
        try:
            V.parse_program(V.load_lines(src), keep_tests=True)
        except V.VantaError:
            continue                  # a file that doesn't parse yet isn't the formatter's business
        new, problem = fmt.format_checked(V, src)
        check(problem is None, f"{path}: {problem}")
        check(fmt.same_program(V, src, new), f"{path}: meaning changed")
        again, _ = fmt.format_checked(V, new)
        check(again == new, f"{path}: not idempotent")
        with open(os.path.join(copy, os.path.relpath(path, ROOT)), "w") as f:
            f.write(new)
    deterministic = sorted(glob.glob(os.path.join(ROOT, "tests", "*.va"))) + [
        os.path.join(ROOT, "examples", n) for n in ("hello.va", "fizzbuzz.va", "functions.va", "lists.va",
                                                   "maps.va", "objects.va", "shapes.va", "higher_order.va",
                                                   "errors.va", "using_lib.va", "countdown.va", "app.va")]
    for path in deterministic:
        if not os.path.exists(path):
            continue
        rel = os.path.relpath(path, ROOT)
        a = subprocess.run([sys.executable, VANTA, rel], capture_output=True, text=True, cwd=ROOT,
                           stdin=subprocess.DEVNULL, timeout=120)
        b = subprocess.run([sys.executable, VANTA, rel], capture_output=True, text=True, cwd=copy,
                           stdin=subprocess.DEVNULL, timeout=120)
        check(a.stdout == b.stdout and a.returncode == b.returncode, f"{rel}: output differs after formatting")


@case
def fmt_check_mode():
    p = write("fmt_me.va", "say 1+1\n")
    code, out, _ = vanta("fmt", "--check", p)
    check(code == 1 and "would reformat" in out, out)
    code, out, _ = vanta("fmt", p)
    check(code == 0 and "formatted" in out, out)
    code, out, _ = vanta("fmt", "--check", p)
    check(code == 0, out)
    with open(p) as f:
        check(f.read() == "say 1 + 1\n", "content")
    bad = write("fmt_bad.va", 'say "unclosed\n')
    code, out, _ = vanta("fmt", bad)
    check(code == 1 and "not formatted" in out, out)


# ---------------------------------------------------------------- docs

@case
def doc_generator():
    p = write("shop.va", '''## Helpers for a shopping cart.

## The sales tax rate.
fix TAX be 0.2

## The total price of every item, with tax.
to total(items, rate be TAX)
    give back sum(items) * (1 + rate)
end

to _private_helper()
    give back 1
end

## A product on the shelf.
type Product
    ## what it is called
    has name
    ## A short label.
    to label()
        give back me.name
    end
end
''')
    code, out, _ = vanta("doc", p)
    check(code == 0, out)
    for want in ("# shop.va", "Helpers for a shopping cart.", "### `total(items, rate be TAX)`",
                 "The total price of every item, with tax.", "### `type Product`", "- `name` — what it is called",
                 "- `label()` — A short label.", "### `fix TAX be 0.2`"):
        check(want in out, f"missing {want!r}:\n{out}")
    check("_private_helper" not in out, out)
    html = os.path.join(TMP, "shop.html")
    code, out, _ = vanta("doc", p, "-o", html)
    with open(html) as f:
        page = f.read()
    check(code == 0 and "<h3><code>total(items, rate be TAX)</code></h3>" in page, page[:500])


# ---------------------------------------------------------------- projects & packages

@case
def new_projects():
    for kind in ("cli", "game", "web", "os"):
        name = f"proj_{kind}"
        code, out, _ = vanta("new", name, f"--{kind}", cwd=TMP)
        check(code == 0, out)
        folder = os.path.join(TMP, name)
        manifest = json.load(open(os.path.join(folder, "vanta.json")))
        check(manifest["name"] == name and manifest["entry"] == "main.va" and manifest["dependencies"] == {},
              manifest)
        if kind != "os":              # kernel builtins exist only in --kernel builds
            code, out, _ = vanta("check", "main.va", cwd=folder)
            check(code == 0, out)
        code, out, _ = vanta("test", cwd=folder)
        check(code == 0 and "0 failed" in out, out)
        code, out, _ = vanta("fmt", "--check", cwd=folder)
        check(code == 0, out)
    code, out, _ = vanta("run", "main.va", "Ada", cwd=os.path.join(TMP, "proj_cli"))
    check(out == "Hello, Ada!\n", out)
    code, out, _ = vanta("new", "proj_cli", cwd=TMP)
    check(code == 1 and "already exists" in out, out)


@case
def get_packages_with_versions_and_lock():
    if shutil.which("git") is None:
        return
    src = os.path.join(TMP, "colors-src")
    os.makedirs(src)
    g = lambda *a: subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *a], cwd=src,
                                  capture_output=True, check=True)
    with open(os.path.join(src, "vanta.json"), "w") as f:
        f.write('{"name": "colors", "version": "1.0.0", "entry": "main.va"}\n')
    with open(os.path.join(src, "main.va"), "w") as f:
        f.write('to shout(t)\n    give back uppercase(t) + "!"\nend\n')
    g("init", "-q")
    g("add", "-A")
    g("commit", "-qm", "one")
    g("tag", "v1.0.0")
    with open(os.path.join(src, "main.va"), "w") as f:
        f.write('to shout(t)\n    give back uppercase(t) + "!!!"\nend\n')
    g("commit", "-qam", "two")
    g("tag", "v2.0.0")
    vanta("new", "app", cwd=TMP)
    app = os.path.join(TMP, "app")
    with open(os.path.join(app, "use.va"), "w") as f:
        f.write('import "colors"\nsay shout("hi")\n')
    code, out, _ = vanta("get", f"file://{src}@v1.0.0", cwd=app)
    check(code == 0 and "installed colors v1.0.0" in out, out)
    check(vanta("run", "use.va", cwd=app)[1] == "HI!\n", "v1 import")
    manifest = json.load(open(os.path.join(app, "vanta.json")))
    check(manifest["dependencies"]["colors"]["version"] == "v1.0.0", manifest)
    lock = json.load(open(os.path.join(app, "vanta.lock")))
    commit = lock["packages"]["colors"]["commit"]
    check(len(commit) == 40, lock)
    shutil.rmtree(os.path.join(app, "packages"))
    code, out, _ = vanta("get", cwd=app)                     # reinstall from vanta.json + lock
    check(code == 0 and "1 dependency installed" in out, out)
    check(vanta("run", "use.va", cwd=app)[1] == "HI!\n", "reinstalled v1")
    code, out, _ = vanta("get", f"file://{src}@2.0.0", cwd=app)   # 2.0.0 finds tag v2.0.0
    check(code == 0 and vanta("run", "use.va", cwd=app)[1] == "HI!!!\n", out)
    code, out, _ = vanta("get", f"file://{src}@v9", cwd=app)
    check(code == 1 and "has no version v9" in out, out)
    code, out, _ = vanta("get", "no-such-package-anywhere", cwd=app)
    check(code == 1 and "don't know where to find" in out, out)


# ---------------------------------------------------------------- REPL

@case
def repl_session():
    session = ("let x be 5\nx * 2\n\"hi\"\nto sq(n)\n    give back n * n\n\nend\nsq(4)\n:vars\n"
               "for each i in range(1, 3)\nsay i\nend\nnope + 1\n:doc length\n:help\n:quit\n")
    code, out, err = vanta("repl", stdin=session)
    check(code == 0, out + err)
    for want in ("10\n", '"hi"\n', "16\n", "x   number    5", "sq  function", "1\n2\n",
                 "Oops! I don't know what 'nope' is yet", "length(value)", ":load FILE"):
        check(want in out, f"missing {want!r}:\n{out}")
    p = write("lib_for_repl.va", "to triple(n)\n    give back n * 3\nend\n")
    code, out, _ = vanta("repl", stdin=f":load {p}\ntriple(5)\n")
    check("(loaded" in out and "15\n" in out, out)


# ---------------------------------------------------------------- debugger

@case
def debugger_session():
    p = write("dbg.va", "to square(n)\n    let result be n * n\n    give back result\nend\n\nlet total be 0\n"
                        "for each i in [1, 2, 3]\n    change total to total + square(i)\nend\nsay \"total is {total}\"\n")
    cmds = "break 2\nc\nwhere\np n + 100\nvars\nfinish\nn\np total\ndelete 2\nc\n"
    code, out, err = vanta("debug", p, stdin=cmds)
    check(code == 0, out + err)
    for want in ("dbg.va:1  to square(n)", "breakpoint at dbg.va:2", "dbg.va:2  let result be n * n",
                 "#0 top level at dbg.va:8", "#1 square at dbg.va:2", "(vdb) 101", "n = 1", "total = 0",
                 "total is 14", "(program finished)"):
        check(want in out, f"missing {want!r}:\n{out}")
    code, out, _ = vanta("debug", p, stdin="s\ns\ns\nq\n")
    check("(stopped)" in out, out)


@case
def debugger_json_session():
    p = write("dbgj.va", "to square(n)\n    let result be n * n\n    give back result\nend\n\nlet total be 0\n"
                         "let m be {\"a\": [1, 2]}\nfor each i in [1, 2, 3]\n    change total to total + square(i)\nend\n"
                         "ask \"name?\" into who\nsay \"total is {total} {who}\"\n")
    proc = subprocess.Popen([sys.executable, VANTA, "debug", "--json", p], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    printed = []

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def until(event):
        while True:
            line = proc.stdout.readline()
            check(line, f"stream ended waiting for {event}; output: {printed}")
            text, mark, payload = line.partition("\x1e")
            printed.append(text)
            if mark:
                msg = json.loads(payload)
                if msg["event"] == event:
                    return msg

    until("ready")
    send({"cmd": "setBreakpoints", "file": p, "breakpoints": [{"line": 2, "condition": "n is 2"}]})
    send({"cmd": "start"})
    stop = until("stopped")
    check(stop["line"] == 2 and [f["name"] for f in stop["stack"]] == ["square", "top level"], stop)
    send({"cmd": "evaluate", "expr": "n * 10", "frame": 0, "seq": 1})
    check(until("response")["body"]["value"] == "20", "evaluate")
    send({"cmd": "evaluate", "expr": "total", "frame": 1, "seq": 2})
    check(until("response")["body"]["value"] == "1", "evaluate in caller frame")
    send({"cmd": "scopes", "frame": 1, "seq": 3})
    scopes = until("response")["body"]
    send({"cmd": "variables", "ref": scopes[-1]["ref"], "seq": 4})
    m = [v for v in until("response")["body"] if v["name"] == "m"][0]
    send({"cmd": "variables", "ref": m["ref"], "seq": 5})
    check(until("response")["body"][0]["value"] == "[1, 2]", "expand map")
    send({"cmd": "stepOut"})
    check(until("stopped")["line"] == 9, "step out to the caller")
    send({"cmd": "setBreakpoints", "file": p, "breakpoints": []})
    send({"cmd": "continue"})
    send({"cmd": "input", "text": "Sam"})
    check(until("exited")["code"] == 0, printed)
    check("total is 14 Sam" in "".join(printed), printed)
    proc.wait(timeout=30)


# ---------------------------------------------------------------- language server

def lsp_session(messages):
    p = subprocess.Popen([sys.executable, VANTA, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    for m in messages:
        data = json.dumps(m).encode()
        p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
    p.stdin.close()
    raw = p.stdout.read()
    p.wait(timeout=30)
    out = []
    while raw:
        head, _, rest = raw.partition(b"\r\n\r\n")
        n = int(head.split(b":")[1])
        out.append(json.loads(rest[:n]))
        raw = rest[n:]
    return out, p.returncode


@case
def lsp_features():
    uri = "file://" + write("lsp_doc.va", "")
    src = '## Adds two numbers.\nto add(a, b)\n    give back a + b\nend\nsay add(1, 2)\nsay lenght("x")\n'
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "vanta", "version": 1, "text": "if yes\n  say (1\n"}}},
        {"jsonrpc": "2.0", "method": "textDocument/didChange",
         "params": {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [{"text": src}]}},
        {"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 5}}},
        {"jsonrpc": "2.0", "id": 3, "method": "textDocument/hover",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 1}}},
        {"jsonrpc": "2.0", "id": 4, "method": "textDocument/definition",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 5}}},
        {"jsonrpc": "2.0", "id": 5, "method": "textDocument/completion",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 4, "character": 5}}},
        {"jsonrpc": "2.0", "id": 6, "method": "textDocument/documentSymbol", "params": {"textDocument": {"uri": uri}}},
        {"jsonrpc": "2.0", "id": 7, "method": "textDocument/formatting",
         "params": {"textDocument": {"uri": uri}, "options": {"tabSize": 4, "insertSpaces": True}}},
        {"jsonrpc": "2.0", "id": 8, "method": "shutdown"},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    out, code = lsp_session(msgs)
    by_id = {m["id"]: m for m in out if "id" in m}
    diags = [m["params"]["diagnostics"] for m in out if m.get("method") == "textDocument/publishDiagnostics"]
    check(code == 0, "exit code")
    check(by_id[1]["result"]["capabilities"]["hoverProvider"] is True, by_id[1])
    check(diags[0] and diags[0][0]["message"].startswith("a closing ) is missing") and
          diags[0][0]["range"]["start"]["line"] == 1, diags[0])
    check(any("lenght" in d["message"] for d in diags[1]), diags[1])     # checker or fallback
    check("Adds two numbers." in by_id[2]["result"]["contents"]["value"], by_id[2])
    check("say VALUE" in by_id[3]["result"]["contents"]["value"], by_id[3])
    check(by_id[4]["result"]["range"]["start"] == {"line": 1, "character": 3}, by_id[4])
    labels = {i["label"] for i in by_id[5]["result"]["items"]}
    check({"add", "length", "say", "is at least"} <= labels, "completion labels")
    check(by_id[6]["result"][0]["name"] == "add", by_id[6])
    check(by_id[7]["result"] == [] or "newText" in by_id[7]["result"][0], by_id[7])


@case
def lsp_navigation():
    geo = write("lspws/geo.va", "## Area of a circle.\nto area(r: number) -> number\n    give back pi * r * r\nend\n"
                "type Circle\n    has radius: number\n    to grow(by_amount)\n"
                "        change me.radius to me.radius + by_amount\n    end\nend\n")
    src = ('import "geo" as g\nfrom "geo" use area\nto add(a: number, b: number) -> number\n    let s be a + b\n'
           '    let unused be 3\n    give back s\nend\nlet c be new g.Circle(2)\nc.grow(1)\nsay area(2) + add(1, 2)\n'
           'say lenght("x")\n')
    main = write("lspws/main.va", src)
    uri, guri = "file://" + main, "file://" + geo

    def req(i, method, params):
        return {"jsonrpc": "2.0", "id": i, "method": method, "params": params}

    def at(u, line, ch, **kw):
        return dict({"textDocument": {"uri": u}, "position": {"line": line, "character": ch}}, **kw)
    msgs = [
        req(1, "initialize", {"rootUri": "file://" + os.path.dirname(main)}),
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "languageId": "vanta", "version": 1, "text": src}}},
        req(2, "textDocument/completion", at(uri, 8, 2)),
        req(3, "textDocument/hover", at(uri, 3, 9)),
        req(4, "textDocument/definition", at(uri, 8, 3)),
        req(5, "textDocument/references", at(guri, 1, 4, context={"includeDeclaration": True})),
        req(6, "textDocument/rename", at(uri, 2, 4, newName="total")),
        req(7, "textDocument/signatureHelp", at(uri, 9, 21)),
        req(8, "textDocument/documentSymbol", {"textDocument": {"uri": guri}}),
        req(9, "textDocument/rename", at(uri, 2, 4, newName="area")),
        {"jsonrpc": "2.0", "id": 10, "method": "shutdown"},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    out, code = lsp_session(msgs)
    by_id = {m["id"]: m for m in out if "id" in m}
    diags = [m["params"]["diagnostics"] for m in out if m.get("method") == "textDocument/publishDiagnostics"][0]
    typo = [d for d in diags if "lenght" in d["message"]][0]
    check(typo["range"]["start"] == {"line": 10, "character": 4} and typo["data"]["replace"] == "length", typo)
    check(any(d["message"] == "'unused' is never used" and d["severity"] == 2 for d in diags), diags)
    check([i["label"] for i in by_id[2]["result"]["items"]] == ["radius", "grow"], by_id[2])
    check("let s: number" in by_id[3]["result"]["contents"]["value"], by_id[3])
    check(by_id[4]["result"]["uri"] == guri and by_id[4]["result"]["range"]["start"]["line"] == 6, by_id[4])
    check(len(by_id[5]["result"]) == 3 and {r["uri"] for r in by_id[5]["result"]} == {uri, guri}, by_id[5])
    edits = by_id[6]["result"]["changes"][uri]
    check(len(edits) == 2 and all(e["newText"] == "total" for e in edits), edits)
    sig = by_id[7]["result"]
    check(sig["signatures"][0]["label"].startswith("add(a: number") and sig["activeParameter"] == 1, sig)
    circle = [s for s in by_id[8]["result"] if s["name"] == "Circle"][0]
    check([c["name"] for c in circle["children"]] == ["radius", "grow"], circle)
    check("already exists" in by_id[9]["error"]["message"], by_id[9])


# ---------------------------------------------------------------- lexer

@case
def pygments_lexer():
    try:
        import pygments  # noqa: F401
    except ImportError:
        return
    from pygments.token import Error, Keyword, Operator, String, Comment, Name, Number
    from vanta_lexer import VantaLexer
    lexer = VantaLexer()
    for path in sorted(glob.glob(os.path.join(ROOT, "tests", "**", "*.va"), recursive=True) +
                       glob.glob(os.path.join(ROOT, "examples", "*.va"))):
        with open(path) as f:
            toks = list(lexer.get_tokens(f.read()))
        check(not [t for t in toks if t[0] is Error], f"error tokens in {path}")
    src = ('## doc\nto area(r: number) -> number\n    if r is at least 0x1F and r is not in xs\n'
           '        say "Hi {name} {{x}}" + length(xs)\n    end\nend\n')
    toks = [(t, v) for t, v in lexer.get_tokens(src) if v.strip()]
    want = [(Comment.Special, "## doc"), (Keyword.Declaration, "to"), (Name.Function, "area"),
            (Keyword.Type, "number"), (Operator.Word, "is at least"), (Number.Hex, "0x1F"),
            (Operator.Word, "is not in"), (String.Interpol, "{"), (String.Escape, "{{"),
            (Name.Builtin, "length")]
    for w in want:
        check(w in toks, f"missing token {w}")


def main():
    for name, err in results:
        print(f"  {'PASS' if err is None else 'FAIL'}  {name}")
        if err:
            print("        " + err.replace("\n", "\n        ")[:3000])
    failed = sum(1 for _, e in results if e)
    print(f"{len(results) - failed} passed, {failed} failed")
    if not failed:
        shutil.rmtree(TMP, ignore_errors=True)
    else:
        print(f"(scratch files kept in {TMP})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
