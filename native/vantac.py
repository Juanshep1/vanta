#!/usr/bin/env python3
"""vantac: compiles a Vanta program into C and builds a native executable.

It reads programs with vanta.py's own parser, so it accepts exactly the language the interpreter runs, and the
runtime (native/runtime) reproduces the interpreter's behaviour and messages. Every Vanta function becomes a C
function; every scope is a heap environment (so closures work), and every intermediate value lives in a scope slot,
which keeps the garbage collector precise.

    python3 native/vantac.py program.va [-o program] [--run] [--keep-c] [--debug]
    python3 native/vantac.py kernel.va --kernel [-o out/kernel.elf] [--arch x86|arm64] [--iso out/vanta.iso]
        a bare-metal kernel (no operating system underneath): see native/kernel_build.py and docs/KERNEL.md
"""
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUNTIME = os.path.join(HERE, "runtime")

_spec = importlib.util.spec_from_file_location("vanta_lang", os.path.join(ROOT, "vanta.py"))
vanta = importlib.util.module_from_spec(_spec)
_argv, sys.argv = sys.argv, [sys.argv[0]]
_spec.loader.exec_module(vanta)
sys.argv = _argv


class CompileError(Exception):
    pass


def native_builtins():
    """Builtin names the native runtime provides (read from the runtime's own tables)."""
    names = set()
    for f in os.listdir(RUNTIME):
        if f.endswith(".c"):
            src = open(os.path.join(RUNTIME, f)).read()
            for tab in re.findall(r"static const Entry \w*table\w*\[\] = \{(.*?)\n\};", src, re.S):
                names.update(re.findall(r'\{"(\w+)",', tab))
    return names


NATIVE = native_builtins()
GAME = {n for n in NATIVE if re.search(r'\{"' + n + r'",', open(os.path.join(RUNTIME, "vgame.c")).read())}
CANVAS = {n for n in NATIVE if re.search(r'\{"' + n + r'",', open(os.path.join(RUNTIME, "vcanvas.c")).read())}
INTERP_ONLY = set(vanta.BUILTINS) - NATIVE


def optional_runtime(used):
    """Optional runtime files (networking, threads, databases, ...): a file whose first lines say
    `/* vantac: optional; libs: -lz; needs: vrt_thread.c */` is linked only when the program uses one of the builtins
    in its tables, together with the libraries it names and the other runtime files it needs."""
    info = {}
    for f in sorted(os.listdir(RUNTIME)):
        if not f.endswith(".c"):
            continue
        src = open(os.path.join(RUNTIME, f)).read()
        m = re.search(r"vantac:\s*optional([^*]*)\*/", src[:2000])
        if not m:
            continue
        opts = dict(p.strip().split(":", 1) for p in m.group(1).split(";") if ":" in p)
        names = set()
        for tab in re.findall(r"static const Entry \w*table\w*\[\] = \{(.*?)\n\};", src, re.S):
            names.update(re.findall(r'\{"(\w+)",', tab))
        info[f] = (names, opts.get("libs", "").split(), opts.get("needs", "").split())
    files, libs = [], []
    def add(f):
        if f in files or f not in info:
            return
        files.append(f)
        for lib in info[f][1]:
            if lib not in libs:
                libs.append(lib)
        for dep in info[f][2]:
            add(dep)
    for f, (names, _, _) in info.items():
        if names & used:
            add(f)
    return [os.path.join(RUNTIME, f) for f in files], libs


def sdl_flags():
    """Compile + link flags for SDL2 (games and canvas programs)."""
    try:
        return subprocess.run(["sdl2-config", "--cflags", "--libs"], capture_output=True, text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        print("Oops! this program is a game and needs SDL2 (macOS: brew install sdl2; Linux: apt install libsdl2-dev)")
        sys.exit(1)


def canvas_runtime(cc, flags):
    """The canvas runtime: vcanvas.c, plus the stb image/font/sound libraries (vstb.c), which take a few seconds to
    compile and never change, so they're compiled once into ~/.cache/vanta and reused."""
    import hashlib
    stb = os.path.join(RUNTIME, "vstb.c")
    stamp = [cc, *flags] + [str(os.path.getmtime(os.path.join(RUNTIME, "stb", f))) for f in sorted(os.listdir(os.path.join(RUNTIME, "stb")))]
    stamp.append(str(os.path.getmtime(stb)))
    key = hashlib.sha1("|".join(stamp).encode()).hexdigest()[:12]
    cache = os.environ.get("VANTA_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "vanta")
    obj = os.path.join(cache, f"vstb-{key}.o")
    if not os.path.exists(obj):
        os.makedirs(cache, exist_ok=True)
        tmp = f"{obj}.{os.getpid()}.tmp"
        r = subprocess.run([cc, *flags, "-std=c11", "-w", "-I", RUNTIME, "-c", stb, "-o", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            print("Oops! the C compiler failed:\n" + r.stderr[-4000:])
            sys.exit(1)
        os.replace(tmp, obj)
    return [os.path.join(RUNTIME, "vcanvas.c"), obj]


# a 512 MB main-thread stack, so deep recursion works (Linux raises its limit at start-up instead)
STACK_FLAGS = ["-Wl,-stack_size,0x20000000"] if sys.platform == "darwin" else []


def c_str(s):
    """A C string literal for UTF-8 text."""
    out = ['"']
    for b in s.encode("utf-8"):
        c = chr(b)
        if c == '"' or c == "\\":
            out.append("\\" + c)
        elif 32 <= b < 127 and c != "?":
            out.append(c)
        else:
            out.append("\\%03o" % b)
    out.append('"')
    return "".join(out)


def declared_names(stmts, out=None):
    """Names a block defines in its own scope (let, fix, to, type, for each, ask, rescue, let a, b)."""
    if out is None:
        out = []
    def add(n):
        if n not in out:
            out.append(n)
    for st in stmts:
        tag = st[0]
        if tag in ("let", "fix"):
            add(st[2])
        elif tag == "let_multi":
            for n in st[2]:
                add(n)
        elif tag in ("func", "type"):
            add(st[2])
        elif tag == "foreach":
            add(st[2]); declared_names(st[4], out)
        elif tag == "foreach2":
            add(st[2]); add(st[3]); declared_names(st[5], out)
        elif tag == "ask":
            add(st[3])
        elif tag == "attempt":
            declared_names(st[2], out); add(st[3]); declared_names(st[4], out)
        elif tag == "if":
            for _, body in st[2]:
                declared_names(body, out)
            declared_names(st[3], out)
        elif tag == "match":
            for vn, body in st[3]:
                if vn[0] == "pattern":                 # names a when-pattern takes apart
                    for pat in vn[1]:
                        for n in vanta.pattern_names(pat, []):
                            add(n)
                declared_names(body, out)
            declared_names(st[4], out)
        elif tag in ("while", "repeat", "lock"):
            declared_names(st[3], out)
        elif tag == "enum":
            add(st[2])
        elif tag == "private":
            declared_names([st[2]], out)
        elif tag == "import_as":
            add(st[3])
        elif tag == "use":
            for n in st[3]:
                add(n)
        elif tag == "using":
            add(st[2]); declared_names(st[4], out)
    return out


class Scope:
    """One Vanta scope = one heap environment. `closes` = whether it can see its lexical parent (methods can't)."""
    def __init__(self, kind, parent, names, closes=True):
        self.kind = kind
        self.parent = parent if closes else None
        self.global_scope = parent.global_scope if parent else self
        self.slots = {}
        for n in names:
            self.slot(n)
        self.ntemps_max = 0
        self.alias = []           # comprehension variables: [(name, slot)] innermost last
        self.envname = "vrt_globals"   # global scopes: the C variable holding their environment
        self.fallback = None      # a module's scope: the program's global scope, consulted after its own

    def slot(self, name):
        if name not in self.slots:
            self.slots[name] = len(self.slots)
        return self.slots[name]


class Compiler:
    def __init__(self, main_path, debug=False):
        self.main_path = os.path.abspath(main_path)
        self.file_ids = {self.main_path: 0}   # source file -> id packed into vrt_line (id << 20 | line)
        self.file_stack = [0]
        self.debug = debug
        self.funcs = []            # C function definitions
        self.protos = []
        self.consts = {}           # text constant -> index
        self.fn_count = 0
        self.modules = {}          # absolute path -> module function name
        self.module_order = []
        self.fixed = set()
        self.folded = {}           # top-level fix NAME be <whole number>: compiled straight to the number
        self.top_decls = {}        # how many times each top-level name is declared
        self.used_builtins = set()
        self.missing = {}          # interpreter-only builtin name -> first line

    # ------------------------------------------------------------------ loading
    def load(self, path):
        with open(path) as f:
            src = f.read()
        try:
            return vanta.parse_program(vanta.load_lines(src))
        except vanta.VantaError as e:
            raise CompileError(f"{os.path.basename(path)}: {e}")

    def resolve_import(self, name, from_dir):
        """The interpreter's search order: the path as given, then lib/, then installed packages."""
        with_ext = name if name.endswith(".va") else name + ".va"
        packages = os.path.join(os.path.expanduser("~"), ".vanta", "packages")
        near = [os.path.join(from_dir, with_ext)] if from_dir else []     # next to the importing file
        for p in (name, with_ext, os.path.join(ROOT, "lib", with_ext), os.path.join(packages, with_ext),
                  os.path.join(packages, name, "main.va"), *near, *vanta.package_candidates(name, from_dir)):
            if os.path.isfile(p):
                return os.path.abspath(p)
        raise CompileError(f"could not find a module named '{name}'")

    def collect_globals(self, stmts, from_dir, names, seen):
        """Top-level names of the program and everything it imports (they all share the global scope)."""
        declared_names(stmts, names)
        for st in stmts:
            if st[0] == "private":
                st = st[2]
            if st[0] in ("let", "fix", "func", "type"):
                self.top_decls[st[2]] = self.top_decls.get(st[2], 0) + 1
            if st[0] == "fix":
                v = st[3]
                if v[0] == "neg" and v[1][0] == "lit" and type(v[1][1]) is int:
                    self.folded[st[2]] = -v[1][1]
                elif v[0] == "lit" and type(v[1]) is int:
                    self.folded[st[2]] = v[1]
        top_ids = {id(st) for st in stmts}
        for st in self.walk_stmts(stmts):
            if st[0] == "fix":
                self.fixed.add(st[2])
            if st[0] == "let" and id(st) not in top_ids:      # a nested `let X` of a fixed X must still fail at run time
                self.top_decls[st[2]] = self.top_decls.get(st[2], 0) + 1
            if st[0] == "import" and st[2][0] == "lit" and isinstance(st[2][1], str):
                p = self.resolve_import(st[2][1], from_dir)
                if p not in seen:
                    seen.add(p)
                    self.collect_globals(self.load(p), os.path.dirname(p), names, seen)
            if st[0] in ("import_as", "use") and st[2][0] == "lit" and isinstance(st[2][1], str):
                # a namespaced module has its own scope, but its plain imports still join the global one
                p = self.resolve_import(st[2][1], from_dir)
                if ("ns", p) not in seen:
                    seen.add(("ns", p))
                    for st2 in self.walk_stmts(self.load(p)):
                        if st2[0] == "fix":
                            self.fixed.add(st2[2])
                        if st2[0] in ("import", "import_as", "use"):
                            self.collect_globals([st2], os.path.dirname(p), names, seen)

    def walk_stmts(self, stmts):
        for st in stmts:
            yield st
            tag = st[0]
            if tag == "if":
                for _, b in st[2]:
                    yield from self.walk_stmts(b)
                yield from self.walk_stmts(st[3])
            elif tag == "match":
                for _, b in st[3]:
                    yield from self.walk_stmts(b)
                yield from self.walk_stmts(st[4])
            elif tag in ("while", "repeat", "lock"):
                yield from self.walk_stmts(st[3])
            elif tag == "foreach":
                yield from self.walk_stmts(st[4])
            elif tag == "foreach2":
                yield from self.walk_stmts(st[5])
            elif tag == "attempt":
                yield from self.walk_stmts(st[2]); yield from self.walk_stmts(st[4])
            elif tag == "func":
                yield from self.walk_stmts(st[4])
            elif tag == "type":
                for m in st[5].values():
                    yield from self.walk_stmts(m.body)
            elif tag == "private":
                yield from self.walk_stmts([st[2]])
            elif tag == "using":
                yield from self.walk_stmts(st[4])

    # ------------------------------------------------------------------ helpers
    def k(self, text):
        if text not in self.consts:
            self.consts[text] = len(self.consts)
        return f"K[{self.consts[text]}]"

    def new_fn(self, prefix="F"):
        self.fn_count += 1
        return f"{prefix}{self.fn_count}"

    # ------------------------------------------------------------------ program
    def compile_program(self):
        main = self.load(self.main_path)
        gnames = ["pi", "e"]             # the interpreter predefines these globals
        self.collect_globals(main, os.path.dirname(self.main_path), gnames, {self.main_path})
        self.folded = {n: v for n, v in self.folded.items() if self.top_decls.get(n) == 1}
        self.gscope = Scope("global", None, gnames)
        self.gscope.global_scope = self.gscope
        body = self.compile_body(main, self.gscope, os.path.dirname(self.main_path), is_global=True)
        body += self.game_loop_call(main)
        gnamed = len(self.gscope.slots)
        nslots = gnamed + self.gscope.ntemps_max
        main_fn = ["static void vanta_main(void) {", "    VEnv *E = vrt_globals;", "    (void)E;"] + body + ["}"]
        main_fn = [l.replace("@@N@@", str(gnamed)) for l in main_fn]
        self.funcs = [f.replace("@@N@@", str(gnamed)) if f.startswith("static void MOD") else f for f in self.funcs]
        if self.missing:
            names = ", ".join(sorted(self.missing))
            raise CompileError(f"native builds don't have these yet: {names} "
                               f"(first used on line {min(self.missing.values())}); run with vanta.py instead")
        out = ['#include "vrt.h"', '#include <stdio.h>', '#include <stdlib.h>', '#include <string.h>', '#include <setjmp.h>',
               f"static V K[{max(1, len(self.consts))}];"]
        out += [f"static V BI_{n};" for n in sorted(self.used_builtins)]
        out += self.protos
        out += ["static void vanta_main(void);"]
        out += self.funcs
        out += main_fn
        names = sorted(self.file_ids, key=lambda k: self.file_ids[k])
        init = ["int main(int argc, char **argv) {", "    vrt_init(argc, argv);",
                "    static const char *FILES[] = {" + ", ".join(c_str(os.path.basename(n)) for n in names) + "};",
                f"    vrt_file_names = FILES; vrt_file_count = {len(names)};",
                f"    vrt_globals = vrt_env(NULL, {nslots});"]
        for text, i in self.consts.items():
            b = text.encode("utf-8")
            init.append(f"    K[{i}] = vrt_perm_str({c_str(text)}, {len(b)});")
        for n in sorted(self.used_builtins):
            init.append(f'    BI_{n} = vrt_builtin_named("{n}");')
        init.append(f"    vrt_globals->s[{self.gscope.slots['pi']}] = VF(3.141592653589793);")
        init.append(f"    vrt_globals->s[{self.gscope.slots['e']}] = VF(2.718281828459045);")
        init += ["    vanta_main();", "    fflush(stdout);", "    return 0;", "}"]
        self.parts = {"main_fn": main_fn, "init": init}
        return "\n".join(out + init) + "\n"

    def game_loop_call(self, main):
        """Canvas programs: once the top-level code has run, the game loop calls the program's on_frame() — or
        update(dt) and draw() — 60 times a second (a program with none of them keeps its picture on screen). A program
        that runs its own loop with next_frame() or run_game() is left alone."""
        if not (self.used_builtins & CANVAS) or self.used_builtins & {"run_game", "next_frame"}:
            return []
        funcs = {st[2]: st for st in main if st[0] == "func"}
        if "on_frame" in funcs:
            call = "run_game(on_frame, nothing, nothing, no)"
        else:
            upd = funcs.get("update")
            takes_dt = "yes" if upd is not None and len(upd[3]) >= 1 else "no"
            call = (f"run_game(nothing, {'update' if upd else 'nothing'}, "
                    f"{'draw' if 'draw' in funcs else 'nothing'}, {takes_dt})")
        stmts = vanta.parse_program(vanta.load_lines(call))
        return self.compile_body(stmts, self.gscope, os.path.dirname(self.main_path), is_global=True)

    def split_sources(self, nchunks):
        """The same program as several C files that compile in parallel: a shared header of declarations,
        chunks of functions, and a main file with the constants table and main()."""
        def unstatic(text):
            return text[len("static "):] if text.startswith("static ") else text
        header = ['#include "vrt.h"', '#include <stdio.h>', '#include <stdlib.h>', '#include <string.h>', '#include <setjmp.h>',
                  f"extern V K[{max(1, len(self.consts))}];"]
        header += [f"extern V BI_{n};" for n in sorted(self.used_builtins)]
        header += [unstatic(p) for p in self.protos]
        header += ["void vanta_main(void);"]
        funcs = [unstatic(f) for f in self.funcs]
        total = sum(len(f) for f in funcs)
        chunks, cur, size = [], [], 0
        for f in funcs:
            cur.append(f)
            size += len(f)
            if size >= total / nchunks and len(chunks) < nchunks - 1:
                chunks.append(cur)
                cur, size = [], 0
        chunks.append(cur)
        main_lines = ['#include "prog.h"', f"V K[{max(1, len(self.consts))}];"]
        main_lines += [f"V BI_{n};" for n in sorted(self.used_builtins)]
        main_lines += [unstatic(l) if i == 0 else l for i, l in enumerate(self.parts["main_fn"])]
        main_lines += self.parts["init"]
        return "\n".join(header) + "\n", ["#include \"prog.h\"\n" + "\n".join(c) + "\n" for c in chunks], "\n".join(main_lines) + "\n"

    def compile_body(self, stmts, scope, src_dir, is_global=False):
        ctx = FnCtx(self, scope, src_dir)
        ctx.emit_block(stmts, 1)
        scope.ntemps_max = max(scope.ntemps_max, ctx.tmax)
        return ctx.lines

    def compile_function(self, name, params, body, parent_scope, src_dir, method=False):
        """Returns the C name of a function taking (clo, argc, argv, self, super). A body that yields becomes a
        generator: this function binds the parameters and returns a VGen whose resume function runs the body."""
        cname = self.new_fn("M" if method else "F")
        pnames = [p for p, _ in params]
        names = list(pnames) + (["me", "super"] if method else [])
        for n in declared_names(body):
            if n not in names:
                names.append(n)
        scope = Scope("method" if method else "func", parent_scope, names, closes=not method)
        scope.params = set(pnames) | ({"me", "super"} if method else set())
        if method:
            scope.parent = parent_scope.global_scope
        gen = vanta.body_yields(body)
        if gen:                                 # compile the body first: it may add slots
            gname = self.new_fn("G")
            gctx = FnCtx(self, scope, src_dir, fn_name=name)
            gctx.gen = True
            gctx.lines.append("    vrt_safepoint();")
            gctx.emit_block(body, 1)
            gctx.lines.append("    g->state = -1; vrt_root_pop(); return 0;")
        rest = bool(params) and params[-1][1] == vanta.REST_PARAM
        ctx = FnCtx(self, scope, src_dir, fn_name=name)
        ctx.lines.append(f"    int saved_line = vrt_line;")
        if not rest:
            nreq = sum(1 for _, d in params if d is None)
            ctx.lines.append(f"    vrt_bind_check2({c_str(name)}, argc, {len(params)}, {nreq});")
        ctx.lines.append(f"    VEnv *E = vrt_env(clo, NSLOTS);")
        ctx.lines.append(f"    vrt_root_push(E);")
        if method:
            ctx.lines.append(f"    E->s[{scope.slots['me']}] = self;")
            ctx.lines.append(f"    E->s[{scope.slots['super']}] = super_;")
        for i, (pname, default) in enumerate(params):
            s = scope.slots[pname]
            given = f"argc > {i} && argv[{i}].t != VT_UNDEF"      # a gap left by f(name: value) means 'not given'
            if default == vanta.REST_PARAM:
                ctx.lines.append(f"    E->s[{s}] = vrt_list_of(argc > {i} ? argc - {i} : 0, argv + {i});")
            elif default is None:
                ctx.lines.append(f"    if ({given}) E->s[{s}] = argv[{i}]; else vrt_missing_arg({c_str(name)}, {c_str(pname)});")
            else:
                ctx.lines.append(f"    if ({given}) E->s[{s}] = argv[{i}]; else {{")
                v = ctx.expr(default, 2)
                ctx.lines.append(f"        E->s[{s}] = {v};")
                ctx.lines.append("    }")
                ctx.reset_temps()
        if gen:
            ctx.lines.append(f"    {{ V g = vrt_gen_new({c_str(name)}, E, {gname}); vrt_root_pop(); vrt_line = saved_line; return g; }}")
        else:
            ctx.lines.append("    vrt_safepoint();")
            ctx.emit_block(body, 1)
            ctx.lines.append("    vrt_root_pop();")
            ctx.lines.append("    vrt_line = saved_line;")
            ctx.lines.append("    return VNIL;")
        named = len(scope.slots)
        nslots = named + max(ctx.tmax, gctx.tmax if gen else 0)
        fix = lambda l: l.replace("NSLOTS", str(nslots)).replace("@@N@@", str(named))
        sig = f"static V {cname}(VEnv *clo, int argc, V *argv, V self, V super_)"
        self.protos.append(sig + ";")
        body_lines = [sig + " {", "    (void)self; (void)super_;"] + [fix(l) for l in ctx.lines] + ["}"]
        self.funcs.append("\n".join(body_lines))
        if gen:
            gsig = f"static int {gname}(VGen *g, V *out)"
            self.protos.append(gsig + ";")
            dispatch = ["    switch (g->state) {"]
            for k, path in gctx.yields:
                dispatch.append(f"    case {k}: goto {'T%d' % path[0] if path else 'Y%d' % k};")
            dispatch.append("    default: break;\n    }")
            glines = "\n".join(fix(l) for l in gctx.lines)
            for att, targets in gctx.try_dispatch.items():     # re-entering an attempt/using on resume
                cases = "".join(f" case {k}: goto {t};" for k, t in targets)
                glines = glines.replace(f"@@DISPATCH{att}@@", f"if (resuming) switch (g->state) {{{cases} default: break; }}" if cases else "")
            self.funcs.append("\n".join([gsig + " {", "    VEnv *E = g->env; volatile int resuming = g->state != 0; (void)resuming;",
                                         "    vrt_root_push(E);"] + dispatch + [glines, "}"]))
        return cname

    def func_value(self, name, cname, env, params):
        """The C expression for a function value (with its parameter names, for calls like f(size: 2))."""
        n = self.fn_count = self.fn_count + 1
        names = ", ".join(c_str(p) for p, _ in params) or "NULL"
        rest = 1 if params and params[-1][1] == vanta.REST_PARAM else 0
        self.protos.append(f"/*pn*/static const char *PN{n}[] = {{{names}}};")
        return f"vrt_func_sig(vrt_func({c_str(name)}, {cname}, {env}), {len(params)}, PN{n}, {rest})"

    def compile_ns_module(self, path):
        """import "x" as y / from "x" use ...: the module runs once in its own scope (a static environment) and is
        given back as a module value."""
        key = ("ns", path)
        if key in self.modules:
            return self.modules[key]
        n = self.fn_count = self.fn_count + 1
        cname, envname = f"NSMOD{n}", f"MENV{n}"
        self.modules[key] = cname
        stmts = self.load(path)
        self.file_ids.setdefault(path, len(self.file_ids))
        self.file_stack.append(self.file_ids[path])
        scope = Scope("global", None, declared_names(stmts))
        scope.global_scope = scope
        scope.envname = envname
        scope.fallback = self.gscope
        private = sorted(vanta.private_names(stmts))
        exports = [nm for nm in scope.slots if nm not in private]
        ctx = FnCtx(self, scope, os.path.dirname(path))
        ctx.emit_block(stmts, 1)
        self.file_stack.pop()
        named = len(scope.slots)
        fix = lambda l: l.replace("@@N@@", str(named))
        modname = os.path.splitext(os.path.basename(path))[0]
        names = ", ".join(c_str(x) for x in exports) or "NULL"
        slots = ", ".join(str(scope.slots[x]) for x in exports) or "0"
        priv = ", ".join(c_str(x) for x in private) or "NULL"
        sig = f"static V {cname}(void)"
        self.protos.append(sig + ";")
        self.protos.append(f"extern VEnv *{envname};")
        self.funcs.append("\n".join([
            f"VEnv *{envname};",
            sig + " {",
            "    static V mod; static int done = 0;",
            "    if (done) return mod;",
            "    done = 1;",
            f"    {envname} = vrt_env(NULL, {named + ctx.tmax});",
            f"    {{ static const char *names[] = {{{names}}}; static const int slots[] = {{{slots}}}; static const char *priv[] = {{{priv}}};",
            f"      mod = vrt_module({c_str(modname)}, {envname}, {len(exports)}, names, slots, {len(private)}, priv); }}",
            f"    VEnv *E = {envname};", "    (void)E;", "    int saved_line = vrt_line;"]
            + [fix(l) for l in ctx.lines] + ["    vrt_line = saved_line;", "    return mod;", "}"]))
        return cname

    def compile_module(self, path):
        if path in self.modules:
            return self.modules[path]
        cname = self.new_fn("MOD")
        self.modules[path] = cname
        stmts = self.load(path)
        self.file_ids.setdefault(path, len(self.file_ids))
        self.file_stack.append(self.file_ids[path])
        ctx = FnCtx(self, self.gscope, os.path.dirname(path))
        ctx.emit_block(stmts, 1)
        self.file_stack.pop()
        self.gscope.ntemps_max = max(self.gscope.ntemps_max, ctx.tmax)
        sig = f"static void {cname}(void)"
        self.protos.append(sig + ";")
        self.funcs.append("\n".join([sig + " {", "    static int done = 0;", "    if (done) return;", "    done = 1;",
                                     "    VEnv *E = vrt_globals;", "    (void)E;"] + ctx.lines + ["}"]))
        return cname


class FnCtx:
    """Code generation for one C function (one Vanta scope)."""
    def __init__(self, comp, scope, src_dir, fn_name=None):
        self.c = comp
        self.scope = scope
        self.src_dir = src_dir
        self.fn_name = fn_name
        self.lines = []
        self.nnamed = len(scope.slots)
        self.tbase = 0           # temps below this are held by enclosing loops / expressions
        self.tcur = 0
        self.tmax = 0
        self.loops = []          # try-depth at each enclosing loop
        self.tries = 0
        self.uid = 0
        self.closes = {}         # try level -> resource a `using` block closes when left early
        self.gen = False         # compiling a generator's resume function (a state machine)
        self.yields = []         # generator: [(state, [enclosing attempt/using ids, outermost first])]
        self.try_path = []       # generator: attempt/using blocks whose body we're in
        self.try_dispatch = {}   # generator: attempt/using id -> [(state, label to jump to on resume)]

    # ---- temps (scope slots after the named ones) ----
    def temp(self):
        t = self.tcur
        self.tcur += 1
        self.tmax = max(self.tmax, self.tcur)
        return f"E->s[@@N@@+{t}]"

    def temps(self, n):
        """n consecutive temps; returns the index of the first (use slot_expr)."""
        first = self.tcur
        self.tcur += n
        self.tmax = max(self.tmax, self.tcur)
        return first

    def reset_temps(self):
        self.tcur = self.tbase

    def hold(self):
        """Keep the temps allocated so far alive (for a loop's list, a match subject, a map being built)."""
        saved = self.tbase
        self.tbase = self.tcur
        return saved

    def release(self, saved):
        self.tbase = saved
        self.tcur = max(self.tcur, saved)

    def u(self):
        self.uid += 1
        return self.uid

    def out(self, line, ind):
        self.lines.append("    " * ind + line)

    # ---- name resolution ----
    def chain(self, name):
        """Where a name may live, innermost first: [(C slot expression, slot index)], then 'builtin' or None."""
        for alias_name, slot in reversed(self.scope.alias):
            if alias_name == name:
                return [f"E->s[{slot}]"], None
        cands = []
        scope, path = self.scope, "E"
        while scope is not None:
            if name in scope.slots:
                if scope.kind == "global":
                    cands.append(f"{scope.envname}->s[{scope.slots[name]}]")
                else:
                    cands.append(f"{path}->s[{scope.slots[name]}]")
            if scope.kind == "global":
                break
            nxt = scope.parent
            if nxt is None:
                nxt = self.scope.global_scope
                if name in nxt.slots and not any(c.startswith(nxt.envname + "->") for c in cands):
                    cands.append(f"{nxt.envname}->s[{nxt.slots[name]}]")
                break
            path = f"{path}->parent"
            scope = nxt
        g = self.scope.global_scope
        if g.fallback is not None and name in g.fallback.slots:    # a module sees the program's globals too
            cands.append(f"vrt_globals->s[{g.fallback.slots[name]}]")
        fallback = None
        if name in vanta.BUILTIN_VALUES or name in self.c.used_builtins or name in NATIVE:
            fallback = "builtin"
        return cands, fallback

    def builtin_ref(self, name, line):
        if name not in NATIVE:
            self.c.missing.setdefault(name, line)
            return "VNIL"
        self.c.used_builtins.add(name)
        return f"BI_{name}"

    def read_name(self, name, ind, line, for_call=False):
        cands, fb = self.chain(name)
        if name in self.c.folded and len(cands) == 1 and cands[0].startswith("vrt_globals"):
            return self.expr(("lit", self.c.folded[name]), ind)
        miss = f'vrt_fail("I don\'t know a function called \'%s\'", {c_str(name)})' if for_call else f"vrt_unknown({c_str(name)})"
        if not cands:
            if fb:
                return self.builtin_ref(name, line)
            t = self.temp()
            self.out(f"{miss};", ind)
            return "VNIL"
        if len(cands) == 1 and not fb and cands[0].startswith("E->s[") and self.is_param(name):
            return cands[0]
        t = self.temp()
        self.out(f"{t} = {cands[0]};", ind)
        for c in cands[1:]:
            self.out(f"if ({t}.t == VT_UNDEF) {t} = {c};", ind)
        if fb:
            self.out(f"if ({t}.t == VT_UNDEF) {t} = {self.builtin_ref(name, line)};", ind)
        else:
            self.out(f"if ({t}.t == VT_UNDEF) {miss};", ind)
        return t

    def is_param(self, name):
        return getattr(self.scope, "params", None) is not None and name in self.scope.params

    def assign_name(self, name, value, ind, line):
        for alias_name, slot in reversed(self.scope.alias):
            if alias_name == name:
                self.out(f"E->s[{slot}] = {value};", ind)
                return
        cands, _ = self.chain(name)
        if not cands:
            self.out(f"vrt_no_var({c_str(name)});", ind)
            return
        if name in self.c.folded and len(cands) == 1 and cands[0].startswith("vrt_globals"):
            self.out(f"vrt_fixed({c_str(name)});", ind)
            return
        fixed = name in self.c.fixed
        parts = []
        for i, cnd in enumerate(cands):
            kw = "if" if i == 0 else "else if"
            env = cnd.rsplit("->s[", 1)[0]
            slot = cnd.rsplit("->s[", 1)[1].rstrip("]")
            guard = f" if ({env}->consts && {env}->consts[{slot}]) vrt_fixed({c_str(name)});" if fixed else ""
            parts.append(f"{kw} ({cnd}.t != VT_UNDEF) {{{guard} {cnd} = {value}; }}")
        parts.append(f"else vrt_no_var({c_str(name)});")
        for p in parts:
            self.out(p, ind)

    def define(self, name, value, ind, fix=False):
        if self.scope.kind == "global":
            s = self.scope.slots[name]
            target_env = self.scope.envname
        else:
            s = self.scope.slots[name]
            target_env = "E"
        self.out(f"{target_env}->s[{s}] = {value};", ind)
        if fix:
            self.out(f"if (!{target_env}->consts) {target_env}->consts = calloc((size_t){target_env}->n, 1);", ind)
            self.out(f"{target_env}->consts[{s}] = 1;", ind)

    # ---- statements ----
    def emit_block(self, stmts, ind):
        for st in stmts:
            self.reset_temps()
            self.stmt(st, ind)
        self.reset_temps()

    def pop_tries(self, upto, ind):
        unlocks = getattr(self, "unlocks", {})
        for level in range(self.tries, upto, -1):
            self.out("vrt_try_pop();", ind)
            if level in unlocks:              # leaving a 'lock' block early (give back / stop / skip)
                self.out(unlocks[level], ind)
            if level in self.closes:          # leaving a 'using' block early: close its resource
                self.out(f"vrt_close({self.closes[level]});", ind)

    def stmt(self, st, ind):
        tag, line = st[0], st[1]
        self.out(f"vrt_line = {(self.c.file_stack[-1] << 20) | line};", ind)
        if tag == "expr":
            self.expr(st[2], ind)
        elif tag == "say":
            if st[2] is None:
                self.out("vrt_say(VUNDEF);", ind)
            else:
                self.out(f"vrt_say({self.expr(st[2], ind)});", ind)
        elif tag == "fix" and self.scope is self.c.gscope and st[2] in self.c.folded:
            pass                   # folded into every use
        elif tag in ("let", "fix"):
            v = self.expr(st[3], ind)
            if tag == "let" and st[2] in self.c.fixed:
                self.let_guard(st[2], ind)
            self.define(st[2], v, ind, fix=(tag == "fix"))
        elif tag == "let_multi":
            vals = self.value_group(st[3], len(st[2]), ind)
            for n, v in zip(st[2], vals):
                if n in self.c.fixed:
                    self.let_guard(n, ind)
                self.define(n, v, ind)
        elif tag == "assign":
            self.assign(st[2], self.expr(st[3], ind), ind, line)
        elif tag == "assign_multi":
            vals = self.value_group(st[3], len(st[2]), ind)
            for tnode, v in zip(st[2], vals):
                self.assign(tnode, v, ind, line)
        elif tag == "mutate":
            _, _, target, sign, amount = st
            cur = self.expr(target, ind)
            amt = self.expr(amount, ind)
            t = self.temp()
            self.out(f"vrt_mutate_check({cur}, {amt}, '{sign}');", ind)
            self.out(f"{t} = {self.arith_c(sign, cur, amt)};", ind)
            self.assign(target, t, ind, line)
        elif tag == "append":
            v = self.expr(st[2], ind)
            tgt = self.expr(st[3], ind)
            self.out(f"if ({tgt}.t == VT_LIST) vrt_list_push({tgt}, {v}); else vrt_add_to({v}, {tgt});", ind)
        elif tag == "ask":
            p = "VUNDEF" if st[2] is None else self.expr(st[2], ind)
            t = self.temp()
            self.out(f"{t} = vrt_ask({p});", ind)
            self.define(st[3], t, ind)
        elif tag == "if":
            first = True
            for cond, body in st[2]:
                if first:
                    c = self.expr(cond, ind)
                    self.out(f"if (vrt_truthy({c})) {{", ind)
                    first = False
                else:
                    self.out("} else {", ind)
                    ind += 1
                    c = self.expr(cond, ind)
                    self.out(f"if (vrt_truthy({c})) {{", ind)
                self.emit_block(body, ind + 1)
            if st[3]:
                self.out("} else {", ind)
                self.emit_block(st[3], ind + 1)
            self.out("}", ind)
            for _ in range(len(st[2]) - 1):
                ind -= 1
                self.out("}", ind)
        elif tag == "while":
            self.loops.append(self.tries)
            self.out("for (;;) {", ind)
            self.out("vrt_safepoint();", ind + 1)
            c = self.expr(st[2], ind + 1)
            self.out(f"if (!vrt_truthy({c})) break;", ind + 1)
            self.emit_block(st[3], ind + 1)
            self.out("}", ind)
            self.loops.pop()
        elif tag == "repeat":
            n = self.u()
            c = self.expr(st[2], ind)
            self.out(f'if ({c}.t != VT_INT) vrt_fail("repeat needs a whole number of times");', ind)
            saved = None
            if self.gen:                      # a generator keeps its loop counters in its scope (they survive a yield)
                cn, ci = self.temp(), self.temp()
                self.out(f"{cn} = {c};", ind)
                saved = self.hold()
                self.out(f"for ({ci} = VI(0); {ci}.u.i < {cn}.u.i; {ci}.u.i++) {{", ind)
            else:
                self.out(f"for (int64_t n{n} = {c}.u.i, i{n} = 0; i{n} < n{n}; i{n}++) {{", ind)
            self.loops.append(self.tries)
            self.out("vrt_safepoint();", ind + 1)
            self.emit_block(st[3], ind + 1)
            self.loops.pop()
            self.out("}", ind)
            if saved is not None:
                self.release(saved)
        elif tag in ("foreach", "foreach2"):
            pair = tag == "foreach2"
            iter_node = st[4] if pair else st[3]
            body = st[5] if pair else st[4]
            n = self.u()
            src = self.expr(iter_node, ind)
            lst = self.temp()
            self.out(f"{lst} = {'vrt_iter_pairs' if pair else 'vrt_iter_list'}({src});", ind)
            item = self.temp()
            if self.gen:
                cnt = self.temp()
                saved = self.hold()
                self.out(f"for ({cnt} = VI(0); VRT_STEP({lst}, {cnt}.u.i, &{item}); {cnt}.u.i++) {{", ind)
            else:
                saved = self.hold()                # lists step inline; generators are asked one value at a time
                self.out(f"for (int64_t i{n} = 0; VRT_STEP({lst}, i{n}, &{item}); i{n}++) {{", ind)
            self.loops.append(self.tries)
            self.out("vrt_safepoint();", ind + 1)
            if pair:
                self.define(st[2], f"AS_LIST({item})->items[0]", ind + 1)
                self.define(st[3], f"AS_LIST({item})->items[1]", ind + 1)
            else:
                self.define(st[2], item, ind + 1)
            self.emit_block(body, ind + 1)
            self.loops.pop()
            self.out("}", ind)
            self.release(saved)
        elif tag == "match":
            subj = self.expr(st[2], ind)
            hold_t = self.temp()
            self.out(f"{hold_t} = {subj};", ind)
            saved = self.hold()
            first = True
            depth = 0
            for value_node, body in st[3]:
                if not first:
                    self.out("} else {", ind)
                    ind += 1
                    depth += 1
                if value_node[0] == "anyof":
                    hit = self.temp()
                    self.out(f"{hit} = VFALSE;", ind)
                    for vn in value_node[1]:
                        v = self.expr(vn, ind)
                        self.out(f"if (!vrt_truthy({hit}) && vrt_equal({hold_t}, {v})) {hit} = VTRUE;", ind)
                    self.out(f"if (vrt_truthy({hit})) {{", ind)
                elif value_node[0] == "pattern":
                    hit = self.when_pattern(value_node, hold_t, ind)
                    self.out(f"if (vrt_truthy({hit})) {{", ind)
                else:
                    v = self.expr(value_node, ind)
                    self.out(f"if (vrt_equal({hold_t}, {v})) {{", ind)
                first = False
                self.emit_block(body, ind + 1)
            if st[3]:
                if st[4]:
                    self.out("} else {", ind)
                    self.emit_block(st[4], ind + 1)
                self.out("}", ind)
                for _ in range(depth):
                    ind -= 1
                    self.out("}", ind)
            else:
                self.emit_block(st[4], ind)
            self.release(saved)
        elif tag == "lock":
            # lock [LOCK] ... end: hold the lock for the block; release it on errors (then re-raise) and early exits
            if st[2] is not None:
                lk = self.temp()
                self.out(f"{lk} = {self.expr(st[2], ind)};", ind)
            else:
                lk = "VUNDEF"
            saved = self.hold()
            if "new_lock" in NATIVE:
                self.c.used_builtins.add("new_lock")       # links the thread runtime (vrt_thread.c)
            n = self.u()
            self.out(f"vrt_lock_enter({lk});", ind)
            self.out(f"{{ VTry tr{n}; vrt_try_push(&tr{n});", ind)
            self.out(f"if (setjmp(tr{n}.jb) == 0) {{", ind)
            self.tries += 1
            if not hasattr(self, "unlocks"):
                self.unlocks = {}
            self.unlocks[self.tries] = f"vrt_lock_exit({lk});"
            self.emit_block(st[3], ind + 1)
            del self.unlocks[self.tries]
            self.tries -= 1
            self.out("vrt_try_pop();", ind + 1)
            self.out(f"vrt_lock_exit({lk});", ind + 1)
            self.out("} else {", ind)
            self.out(f"vrt_lock_exit({lk}); vrt_rethrow();", ind + 1)
            self.out("} }", ind)
            self.release(saved)
        elif tag == "attempt":
            n = self.u()
            self.open_try(n, ind)
            self.emit_block(st[2], ind + 1)
            self.close_try(n)
            self.out("vrt_try_pop();", ind + 1)
            self.out("} else {", ind)
            self.define(st[3], "vrt_caught()", ind + 1)
            self.emit_block(st[4], ind + 1)
            self.out("} }", ind)
        elif tag == "using":
            # using NAME be VALUE ... end: close the value however the block is left (errors are re-raised after)
            _, _, name, value_node, body = st
            res = self.temp()
            self.out(f"{res} = {self.expr(value_node, ind)};", ind)
            saved = self.hold()
            self.define(name, res, ind)
            n = self.u()
            self.open_try(n, ind)
            self.closes[self.tries] = res
            self.emit_block(body, ind + 1)
            del self.closes[self.tries]
            self.close_try(n)
            self.out("vrt_try_pop();", ind + 1)
            self.out(f"vrt_close({res});", ind + 1)
            self.out("} else {", ind)
            self.out(f"vrt_close_rethrow({res});", ind + 1)
            self.out("} }", ind)
            self.release(saved)
        elif tag == "yield":
            if not self.gen:
                self.out('vrt_fail("\'yield\' only works inside a function (it makes the function a generator)");', ind)
                return
            v = self.expr(st[2], ind)
            k = len(self.yields) + 1
            path = list(self.try_path)
            self.yields.append((k, path))
            for i, att in enumerate(path):
                self.try_dispatch.setdefault(att, []).append((k, f"T{path[i + 1]}" if i + 1 < len(path) else f"Y{k}"))
            self.out(f"*out = {v};", ind)
            for _ in range(self.tries):        # suspended, not left: the attempts are entered again on resume
                self.out("vrt_try_pop();", ind)
            self.out(f"g->state = {k}; vrt_root_pop(); return 1;", ind)
            self.out(f"Y{k}: resuming = 0;", ind)
        elif tag == "return" and self.gen:
            self.pop_tries(0, ind)
            self.out("g->state = -1; vrt_root_pop(); return 0;", ind)
        elif tag == "return":
            v = self.expr(st[2], ind) if st[2] is not None else "VNIL"
            if self.scope.kind in ("func", "method"):
                self.pop_tries(0, ind)
                self.out(f"{{ V r = {v}; vrt_root_pop(); vrt_line = saved_line; return r; }}", ind)
            else:
                self.out('vrt_fail("\'give back\' only works inside a function");', ind)
        elif tag in ("stop", "skip"):
            if not self.loops:
                self.out('vrt_fail("\'stop\'/\'skip\' only work inside a loop");', ind)
            else:
                self.pop_tries(self.loops[-1], ind)
                self.out("break;" if tag == "stop" else "continue;", ind)
        elif tag == "func":
            _, _, name, params, body = st
            cname = self.c.compile_function(name, params, body, self.scope, self.src_dir)
            self.define(name, self.c.func_value(name, cname, "E", params), ind)
        elif tag == "type":
            _, _, name, parent_name, fields, methods = st
            if parent_name and "." in parent_name:     # type Ball from geo.Circle
                parent = self.stable(self.expr(vanta.parse_expr_text(parent_name, line), ind), ind)
            else:
                parent = self.read_name(parent_name, ind, line) if parent_name else "VUNDEF"
            home = self.scope.global_scope.envname     # methods see the top level of their own file
            mnames = [m for m in methods if not methods[m].shared]
            shared = [m for m in methods if methods[m].shared]
            base = self.temps(len(mnames)) if mnames else None
            for i, mn in enumerate(mnames):
                fn = methods[mn]
                cname = self.c.compile_function(mn, fn.params, fn.body, self.scope, self.src_dir, method=True)
                self.out(f"E->s[{self.slot_expr(base + i)}] = {self.c.func_value(mn, cname, home, fn.params)};", ind)
            fl = ", ".join(c_str(f) for f in fields) or "NULL"
            ml = ", ".join(c_str(m) for m in mnames) or "NULL"
            n = self.u()
            self.out(f"{{ static const char *fs{n}[] = {{{fl}}}; static const char *ms{n}[] = {{{ml}}};", ind)
            mptr = f"&E->s[{self.slot_expr(base)}]" if mnames else "NULL"
            self.define(name, f"vrt_type({c_str(name)}, {parent}, {len(fields)}, fs{n}, {len(mnames)}, ms{n}, {mptr})", ind + 1)
            self.out("}", ind)
            if shared or getattr(methods, "shared_fields", None):
                tv = self.read_name(name, ind, line)
                tv = self.stable(tv, ind)
                saved = self.hold()
                for mn in shared:                       # shared to make(): Type.make()
                    fn = methods[mn]
                    gscope = self.scope.global_scope
                    cname = self.c.compile_function(mn, fn.params, fn.body, gscope, self.src_dir)
                    self.out(f"vrt_type_shared({tv}, {c_str(mn)}, {self.c.func_value(mn, cname, home, fn.params)});", ind)
                for fname, vnode in methods.shared_fields:   # shared count be 0: Type.count
                    v = self.expr(vnode, ind)
                    self.out(f"vrt_type_shared({tv}, {c_str(fname)}, {v});", ind)
                    self.reset_temps()
                self.release(saved)
        elif tag == "enum":
            names = ", ".join(c_str(m) for m in st[3])
            n = self.u()
            self.out(f"{{ static const char *km{n}[] = {{{names}}};", ind)
            self.define(st[2], f"vrt_enum({c_str(st[2])}, {len(st[3])}, km{n})", ind + 1)
            self.out("}", ind)
        elif tag == "private":
            self.stmt(st[2], ind)
        elif tag == "remove":
            v = self.stable(self.expr(st[2], ind), ind)
            coll = self.expr(st[3], ind)
            self.out(f"vrt_remove({v}, {coll});", ind)
        elif tag in ("import_as", "use"):
            node = st[2]
            if node[0] != "lit" or not isinstance(node[1], str):
                raise CompileError(f"line {line}: native builds need import with a fixed file name")
            path = self.c.resolve_import(node[1], self.src_dir)
            mod = self.c.compile_ns_module(path)
            t = self.temp()
            self.out(f"{t} = {mod}();", ind)
            if tag == "import_as":
                self.define(st[3], t, ind)
            else:
                for nm in st[3]:                        # from "x" use a, b
                    self.define(nm, f"vrt_module_get({t}, {self.c.k(nm)})", ind)
        elif tag == "import":
            node = st[2]
            if node[0] != "lit" or not isinstance(node[1], str):
                raise CompileError(f"line {line}: native builds need import with a fixed file name")
            path = self.c.resolve_import(node[1], self.src_dir)
            mod = self.c.compile_module(path)
            self.out(f"{mod}();", ind)
        else:
            raise CompileError(f"line {line}: unsupported statement {tag}")

    def let_guard(self, name, ind):
        """`let NAME` where NAME was fixed in this same scope is an error."""
        env = self.scope.envname if self.scope.kind == "global" else "E"
        s = self.scope.slots[name]
        self.out(f"if ({env}->consts && {env}->consts[{s}]) vrt_fixed({c_str(name)});", ind)

    def open_try(self, n, ind):
        """Start an attempt/using body. In a generator its entry has a label, so resuming after a yield inside
        can push the try again and then jump on inward (@@DISPATCH@@ is filled in once all yields are known)."""
        self.out(f"{{ VTry tr{n};", ind)
        self.out(f"{'T%d: ' % n if self.gen else ''}vrt_try_push(&tr{n});", ind)
        self.out(f"if (setjmp(tr{n}.jb) == 0) {{", ind)
        if self.gen:
            self.try_dispatch.setdefault(n, [])
            self.out(f"@@DISPATCH{n}@@", ind + 1)
            self.try_path.append(n)
        self.tries += 1

    def close_try(self, n):
        self.tries -= 1
        if self.gen:
            self.try_path.pop()

    def when_pattern(self, vn, subj, ind):
        """A `when` with patterns: returns a temp that is yes when one alternative matches (and its guard holds).
        Names are bound only once a whole alternative matches."""
        hit = self.temp()
        self.out(f"{hit} = VFALSE;", ind)
        saved = self.hold()
        for pat in vn[1]:
            ok = self.temp()
            binds = {}
            for nm in vanta.pattern_names(pat, []):
                binds[nm] = self.temp()
            inner = self.hold()
            self.out(f"if (!vrt_truthy({hit})) {{", ind)
            self.out(f"{ok} = VTRUE;", ind + 1)
            self.pat_emit(pat, subj, ok, binds, ind + 1)
            self.out(f"if (vrt_truthy({ok})) {{", ind + 1)
            for nm, t in binds.items():
                self.define(nm, t, ind + 2)
            if vn[2] is not None:
                g = self.expr(vn[2], ind + 2)
                self.out(f"{hit} = VB(vrt_truthy({g}));", ind + 2)
                self.reset_temps()
            else:
                self.out(f"{hit} = VTRUE;", ind + 2)
            self.out("}", ind + 1)
            self.out("}", ind)
            self.release(inner)
            self.reset_temps()
        self.release(saved)
        return hit

    def pat_emit(self, pat, subj, ok, binds, ind):
        tag = pat[0]
        if tag == "pat_any":
            return
        if tag == "pat_bind":
            self.out(f"if (vrt_truthy({ok})) {binds[pat[1]]} = {subj};", ind)
            return
        if tag == "pat_value":
            self.out(f"if (vrt_truthy({ok})) {{", ind)
            v = self.expr(pat[1], ind + 1)
            self.out(f"if (!vrt_equal({subj}, {v})) {ok} = VFALSE;", ind + 1)
            self.out("}", ind)
            self.reset_temps()
            return
        if tag == "pat_list":
            items, rest = pat[1], pat[2]
            n = len(items)
            cmp = f"AS_LIST({subj})->len {'==' if rest is None else '>='} {n}"
            self.out(f"if (vrt_truthy({ok}) && !({subj}.t == VT_LIST && {cmp})) {ok} = VFALSE;", ind)
            for i, sub in enumerate(items):
                it = self.temp()
                saved = self.hold()
                self.out(f"if (vrt_truthy({ok})) {it} = AS_LIST({subj})->items[{i}];", ind)
                self.pat_emit(sub, it, ok, binds, ind)
                self.release(saved)
            if rest is not None:
                self.out(f"if (vrt_truthy({ok})) {binds[rest]} = vrt_slice({subj}, VI({n}), VUNDEF);", ind)
            return
        if tag == "pat_map":
            self.out(f"if (vrt_truthy({ok}) && {subj}.t != VT_MAP) {ok} = VFALSE;", ind)
            for knode, sub in pat[1]:
                it = self.temp()
                saved = self.hold()
                self.out(f"if (vrt_truthy({ok})) {{", ind)
                kv = self.expr(knode, ind + 1)
                self.out(f"int f_ = 0; if ({kv}.t == VT_LIST || {kv}.t == VT_MAP) {ok} = VFALSE; "
                         f"else {{ {it} = vrt_map_get({subj}, {kv}, &f_); if (!f_) {ok} = VFALSE; }}", ind + 1)
                self.out("}", ind)
                self.reset_temps()
                self.pat_emit(sub, it, ok, binds, ind)
                self.release(saved)
            return
        if tag == "pat_type":
            tnode, fields = pat[1], pat[2]
            tv = self.temp()
            saved = self.hold()
            self.out(f"if (vrt_truthy({ok})) {{", ind)
            if tnode[0] == "name":                  # a type/kind by that name, else a word like number or text
                tname = tnode[1]
                cands, _ = self.chain(tname)
                self.out(f"{tv} = VUNDEF;", ind + 1)
                for c in cands:
                    self.out(f"if ({tv}.t == VT_UNDEF) {tv} = {c};", ind + 1)
            else:
                tname = "None"
                self.out(f"{tv} = {self.expr(tnode, ind + 1)};", ind + 1)
            self.out(f"if (!vrt_pat_type({subj}, {tv}, {c_str(tname)})) {ok} = VFALSE;", ind + 1)
            for fld in fields:
                self.out(f"else {binds[fld]} = vrt_getattr({subj}, {self.c.k(fld)});" if fld == fields[0] else
                         f"if (vrt_truthy({ok})) {binds[fld]} = vrt_getattr({subj}, {self.c.k(fld)});", ind + 1)
            self.out("}", ind)
            self.reset_temps()
            self.release(saved)
            return
        raise CompileError(f"unsupported pattern {tag}")

    def slot_expr(self, temp_index):
        return f"@@N@@+{temp_index}"

    def value_group(self, nodes, count, ind):
        if len(nodes) == 1:
            v = self.expr(nodes[0], ind)
            t = self.temp()
            self.out(f"{t} = vrt_unpack({v}, {count});", ind)
            return [f"AS_LIST({t})->items[{i}]" for i in range(count)]
        if len(nodes) != count:
            self.out(f'vrt_fail("there are {count} names but {len(nodes)} values");', ind)
            return ["VNIL"] * count
        vals = []
        for nd in nodes:
            v = self.expr(nd, ind)
            t = self.temp()
            self.out(f"{t} = {v};", ind)
            vals.append(t)
        return vals

    def assign(self, target, value, ind, line):
        tag = target[0]
        if tag == "name":
            self.assign_name(target[1], value, ind, line)
        elif tag == "index":
            # value may be a temp; evaluate target pieces after (they get their own temps)
            hold = self.temp()
            self.out(f"{hold} = {value};", ind)
            coll = self.expr(target[1], ind)
            idx = self.expr(target[2], ind)
            self.out(f"vrt_set_index({coll}, {idx}, {hold});", ind)
        elif tag == "getattr":
            hold = self.temp()
            self.out(f"{hold} = {value};", ind)
            obj = self.expr(target[1], ind)
            self.out(f"vrt_setattr({obj}, {self.c.k(target[2])}, {hold});", ind)
        else:
            self.out('vrt_fail("you can\'t change that");', ind)

    # ---- expressions: return a C expression (a literal, a slot, or a temp the code just filled) ----
    ARITH = {"+": "'+'", "-": "'-'", "*": "'*'", "/": "'/'", "%": "'%'", "^": "'^'", "//": "'d'",
             "&": "'&'", "|": "'|'", "xor": "'x'", "<<": "'<'", ">>": "'>'"}

    def arith_c(self, op, a, b):
        if op == "+":
            return f"VRT_ADD({a}, {b})"
        if op == "-":
            return f"VRT_SUB({a}, {b})"
        if op == "*":
            return f"VRT_MUL({a}, {b})"
        if op == "&":
            return f"VRT_BAND({a}, {b})"
        if op == "|":
            return f"VRT_BOR({a}, {b})"
        if op == "xor":
            return f"VRT_BXOR({a}, {b})"
        if op == "<<":
            return f"VRT_SHL({a}, {b})"
        if op == ">>":
            return f"VRT_SHR({a}, {b})"
        if op == "%":
            return f"VRT_MOD({a}, {b})"
        return f"vrt_arith({self.ARITH[op]}, {a}, {b})"

    def stable(self, v, ind):
        """Make sure a value survives the next calls: literals and constants already do; slot reads get copied."""
        if v.startswith("VI(") or v.startswith("VF(") or v.startswith("K[") or v in ("VNIL", "VTRUE", "VFALSE", "VUNDEF") or v.startswith("BI_"):
            return v
        if re.fullmatch(r"E->s\[@@N@@\+\d+\]", v):
            return v
        t = self.temp()
        self.out(f"{t} = {v};", ind)
        return t

    def expr(self, node, ind):
        tag = node[0]
        if tag == "lit":
            v = node[1]
            if v is None:
                return "VNIL"
            if v is True:
                return "VTRUE"
            if v is False:
                return "VFALSE"
            if isinstance(v, int):
                if -(1 << 63) <= v < (1 << 63):
                    return f"VI({v}LL)" if v >= 0 else f"VI(({v + 1}LL) - 1)"
                t = self.temp()                         # a whole number too big for 64 bits
                self.out(f'{t} = vrt_big_parse("{v}", {len(str(v))});', ind)
                return t
            if isinstance(v, float):
                return f"VF({v!r})"
            if isinstance(v, str):
                return self.c.k(v)
            raise CompileError(f"unsupported literal {v!r}")
        if tag == "name":
            return self.read_name(node[1], ind, 0)
        if tag == "arith":
            a = self.stable(self.expr(node[2], ind), ind)
            b = self.expr(node[3], ind)
            t = self.temp()
            self.out(f"{t} = {self.arith_c(node[1], a, b)};", ind)
            return t
        if tag == "cmp":
            op = node[1]
            a = self.stable(self.expr(node[2], ind), ind)
            b = self.expr(node[3], ind)
            t = self.temp()
            if op == "==":
                self.out(f"{t} = VB(vrt_equal({a}, {b}));", ind)
            elif op == "!=":
                self.out(f"{t} = VB(!vrt_equal({a}, {b}));", ind)
            else:
                cop = {"<": "'<'", ">": "'>'", "<=": "'l'", ">=": "'g'"}[op]
                self.out(f"{t} = VRT_CMP({cop}, {a}, {b});", ind)
            return t
        if tag in ("and", "or"):
            t = self.temp()
            a = self.expr(node[1], ind)
            if tag == "and":
                self.out(f"if (!vrt_truthy({a})) {t} = VFALSE; else {{", ind)
            else:
                self.out(f"if (vrt_truthy({a})) {t} = VTRUE; else {{", ind)
            b = self.expr(node[2], ind + 1)
            self.out(f"{t} = VB(vrt_truthy({b}));", ind + 1)
            self.out("}", ind)
            return t
        if tag == "not":
            a = self.expr(node[1], ind)
            t = self.temp()
            self.out(f"{t} = VB(!vrt_truthy({a}));", ind)
            return t
        if tag == "neg":
            a = self.expr(node[1], ind)
            t = self.temp()
            self.out(f"{t} = vrt_neg({a});", ind)
            return t
        if tag == "bitnot":
            a = self.expr(node[1], ind)
            t = self.temp()
            self.out(f"{t} = vrt_bitnot({a});", ind)
            return t
        if tag in ("isa", "in", "notin"):
            a = self.stable(self.expr(node[1], ind), ind)
            b = self.expr(node[2], ind)
            t = self.temp()
            if tag == "isa":
                self.out(f"{t} = vrt_isa({a}, {b});", ind)
            elif tag == "in":
                self.out(f"{t} = vrt_in({a}, {b});", ind)
            else:
                self.out(f"{t} = VB(!vrt_truthy(vrt_in({a}, {b})));", ind)
            return t
        if tag == "ternary":
            t = self.temp()
            c = self.expr(node[1], ind)
            self.out(f"if (vrt_truthy({c})) {{", ind)
            a = self.expr(node[2], ind + 1)
            self.out(f"{t} = {a};", ind + 1)
            self.out("} else {", ind)
            b = self.expr(node[3], ind + 1)
            self.out(f"{t} = {b};", ind + 1)
            self.out("}", ind)
            return t
        if tag == "format":
            parts = node[1]
            base = self.temps(len(parts))
            saved = self.hold()
            for i, p in enumerate(parts):
                v = self.expr(p, ind)
                self.out(f"E->s[{self.slot_expr(base + i)}] = {v};", ind)
                self.reset_temps()
            self.release(saved)
            t = self.temp()
            self.out(f"{t} = vrt_format({len(parts)}, &E->s[{self.slot_expr(base)}]);", ind)
            return t
        if tag == "list":
            items = node[1]
            if not items:
                t = self.temp()
                self.out(f"{t} = vrt_list(4);", ind)
                return t
            base = self.temps(len(items))
            saved = self.hold()
            for i, it in enumerate(items):
                v = self.expr(it, ind)
                self.out(f"E->s[{self.slot_expr(base + i)}] = {v};", ind)
                self.reset_temps()
            self.release(saved)
            t = self.temp()
            self.out(f"{t} = vrt_list_of({len(items)}, &E->s[{self.slot_expr(base)}]);", ind)
            return t
        if tag == "map":
            m = self.temp()
            self.out(f"{m} = vrt_map();", ind)
            saved = self.hold()
            for knode, vnode in node[1]:
                kv = self.stable(self.expr(knode, ind), ind)
                vv = self.expr(vnode, ind)
                self.out(f"vrt_map_set({m}, {kv}, {vv});", ind)
                self.reset_temps()
            self.release(saved)
            return m
        if tag in ("listcomp", "mapcomp"):
            if tag == "listcomp":
                _, out_expr, var, iter_expr, cond = node
                key_expr = None
            else:
                _, key_expr, out_expr, var, iter_expr, cond = node
            res = self.temp()
            self.out(f"{res} = {'vrt_list(4)' if tag == 'listcomp' else 'vrt_map()'};", ind)
            src = self.expr(iter_expr, ind)
            lst = self.temp()
            two = isinstance(var, list)                 # [i for each i, x in xs]
            self.out(f"{lst} = {'vrt_iter_pairs' if two else 'vrt_iter_list'}({src});", ind)
            saved = self.hold()
            n = self.u()
            if two:
                pair = self.scope.slot(f"<comp{n}:pair>")
                h1 = self.scope.slot(f"<comp{n}:{var[0]}>")
                h2 = self.scope.slot(f"<comp{n}:{var[1]}>")
                self.scope.alias.append((var[0], h1))
                self.scope.alias.append((var[1], h2))
                self.out(f"for (int64_t i{n} = 0; VRT_STEP({lst}, i{n}, &E->s[{pair}]); i{n}++) {{", ind)
                self.out(f"E->s[{h1}] = AS_LIST(E->s[{pair}])->items[0]; E->s[{h2}] = AS_LIST(E->s[{pair}])->items[1];", ind + 1)
            else:
                hidden = self.scope.slot(f"<comp{n}:{var}>")
                self.scope.alias.append((var, hidden))
                self.out(f"for (int64_t i{n} = 0; VRT_STEP({lst}, i{n}, &E->s[{hidden}]); i{n}++) {{", ind)
            inner = ind + 1
            if cond is not None:
                c = self.expr(cond, inner)
                self.out(f"if (vrt_truthy({c})) {{", inner)
                inner += 1
            if tag == "listcomp":
                v = self.expr(out_expr, inner)
                self.out(f"vrt_list_push({res}, {v});", inner)
            else:
                kv = self.stable(self.expr(key_expr, inner), inner)
                vv = self.expr(out_expr, inner)
                self.out(f"vrt_map_set({res}, {kv}, {vv});", inner)
            if cond is not None:
                self.out("}", ind + 1)
            self.reset_temps()
            self.out("}", ind)
            self.scope.alias.pop()
            if two:
                self.scope.alias.pop()
            self.release(saved)
            return res
        if tag == "lambda":
            params = [(p, None) for p in node[1]]
            cname = self.c.compile_function("<anonymous>", params, [("return", 0, node[2])], self.scope, self.src_dir)
            t = self.temp()
            self.out(f'{t} = {self.c.func_value("<anonymous>", cname, "E", params)};', ind)
            return t
        if tag == "fmtspec":
            v = self.expr(node[1], ind)
            t = self.temp()
            self.out(f"{t} = vrt_format_spec({v}, {self.c.k(node[2])});", ind)
            return t
        if tag == "callkw":
            callee_node, args, named = node[1], node[2], node[3]
            if callee_node[0] == "name":
                callee = self.read_name(callee_node[1], ind, 0, for_call=True)
            else:
                callee = self.expr(callee_node, ind)
            callee = self.stable(callee, ind)
            n, m = len(args), len(named)
            base = self.temps(n + m)
            saved = self.hold()
            for i, a in enumerate(list(args) + [v for _, v in named]):
                v = self.expr(a, ind)
                self.out(f"E->s[{self.slot_expr(base + i)}] = {v};", ind)
                self.reset_temps()
            self.release(saved)
            u = self.u()
            names = ", ".join(c_str(k) for k, _ in named)
            t = self.temp()
            self.out(f"{{ static const char *kw{u}[] = {{{names}}};", ind)
            self.out(f"{t} = vrt_call_kw({callee}, {n}, &E->s[{self.slot_expr(base)}], {m}, kw{u}, &E->s[{self.slot_expr(base + n)}]); }}", ind + 1)
            return t
        if tag == "call":
            callee_node, args = node[1], node[2]
            if callee_node[0] == "name":
                callee = self.read_name(callee_node[1], ind, 0, for_call=True)
            else:
                callee = self.expr(callee_node, ind)
            callee = self.stable(callee, ind)
            n = len(args)
            if n:
                base = self.temps(n)
                saved = self.hold()
                for i, a in enumerate(args):
                    v = self.expr(a, ind)
                    self.out(f"E->s[{self.slot_expr(base + i)}] = {v};", ind)
                    self.reset_temps()
                self.release(saved)
                argv = f"&E->s[{self.slot_expr(base)}]"
            else:
                argv = "NULL"
            t = self.temp()
            self.out(f"{t} = vrt_call({callee}, {n}, {argv});", ind)
            return t
        if tag == "index":
            coll = self.stable(self.expr(node[1], ind), ind)
            idx = self.expr(node[2], ind)
            t = self.temp()
            self.out(f"{t} = VRT_INDEX({coll}, {idx});", ind)
            return t
        if tag == "getattr":
            obj = self.expr(node[1], ind)
            t = self.temp()
            self.out(f"{t} = vrt_getattr({obj}, {self.c.k(node[2])});", ind)
            return t
        if tag == "sliceop":
            tgt = self.stable(self.expr(node[1], ind), ind)
            a = self.stable(self.expr(node[2], ind), ind) if node[2] is not None else "VUNDEF"
            b = self.expr(node[3], ind) if node[3] is not None else "VUNDEF"
            t = self.temp()
            self.out(f"{t} = vrt_slice({tgt}, {a}, {b});", ind)
            return t
        raise CompileError(f"unsupported expression {tag}")


def finalize(c_src, comp):
    """Temps sit after each function's named slots; NAMED is that count (known only once compiling is done)."""
    return c_src


def build(path, out=None, run=False, keep_c=False, debug=False, extra_args=None):
    comp = Compiler(path, debug=debug)
    try:
        src = comp.compile_program()
    except CompileError as e:
        print(f"Oops! {e}")
        sys.exit(1)
    out = out or os.path.splitext(os.path.abspath(path))[0]
    c_path = out + ".c"
    with open(c_path, "w") as f:
        f.write(src)
    cc = os.environ.get("CC", "cc")
    flags = ["-O0", "-g"] if debug else ["-O2"]
    if len(comp.funcs) > 400 and os.environ.get("VANTA_SPLIT", "1") != "0":
        return build_split(comp, out, cc, flags, run, keep_c, extra_args, c_path)
    cmd = [cc, *flags, "-std=c11", "-w", "-I", RUNTIME, c_path,
           os.path.join(RUNTIME, "vrt.c"), os.path.join(RUNTIME, "vrt_builtins.c"), os.path.join(RUNTIME, "vrt_core.c"),
           os.path.join(RUNTIME, "vrt_big.c"), "-lm", *STACK_FLAGS, "-o", out]
    if comp.used_builtins & (GAME | CANVAS):
        # A game: add the SDL2 runtimes — the GBA-style video chip (vgame.c) and/or the canvas (vcanvas.c).
        sdl = sdl_flags()
        extra = [os.path.join(RUNTIME, "vgame.c")] if comp.used_builtins & GAME else []
        if comp.used_builtins & CANVAS:
            extra += canvas_runtime(cc, flags)
        cmd[-4:-4] = extra
        cmd += sdl
    opt_files, opt_libs = optional_runtime(comp.used_builtins)
    cmd += opt_files + opt_libs
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("Oops! the C compiler failed:\n" + r.stderr[-4000:])
        sys.exit(1)
    if not keep_c:
        os.remove(c_path)
    if run:
        res = subprocess.run([out] + (extra_args or []))
        sys.exit(res.returncode)
    return out


def build_split(comp, out, cc, flags, run, keep_c, extra_args, c_path):
    """Big programs: write the C in pieces and compile them on every core at once, then link."""
    jobs = os.cpu_count() or 4
    work = out + ".build"
    os.makedirs(work, exist_ok=True)
    import fcntl
    lock = open(os.path.join(work, ".lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)          # two builds of the same program take turns
    header, chunks, main_src = comp.split_sources(jobs * 2)
    files = []
    def write(name, text):
        p = os.path.join(work, name)
        if not (os.path.exists(p) and open(p).read() == text):   # unchanged pieces keep their object file
            with open(p, "w") as f:
                f.write(text)
        return p
    hdr = write("prog.h", header)
    for i, c in enumerate(chunks):
        files.append(write(f"part{i}.c", c))
    files.append(write("main.c", main_src))
    runtime = [os.path.join(RUNTIME, n) for n in ("vrt.c", "vrt_builtins.c", "vrt_core.c", "vrt_big.c")]
    link_extra = ["-lm"]
    if comp.used_builtins & (GAME | CANVAS):
        if comp.used_builtins & GAME:
            runtime.append(os.path.join(RUNTIME, "vgame.c"))
        if comp.used_builtins & CANVAS:
            runtime += [os.path.join(RUNTIME, "vcanvas.c"), os.path.join(RUNTIME, "vstb.c")]
        link_extra += sdl_flags()
    opt_files, opt_libs = optional_runtime(comp.used_builtins)
    runtime += opt_files
    link_extra += opt_libs
    cflags = [f for f in link_extra if f.startswith("-I") or f.startswith("-D")]
    pending, objs = [], []
    hdr_time = os.path.getmtime(hdr)
    for src_file in files + runtime:
        obj = os.path.join(work, os.path.basename(src_file)[:-2] + ".o")
        objs.append(obj)
        if os.path.exists(obj) and os.path.getmtime(obj) >= max(os.path.getmtime(src_file), hdr_time if src_file in files else 0, os.path.getmtime(os.path.join(RUNTIME, "vrt.h"))):
            continue
        cmd = [cc, *flags, "-std=c11", "-w", "-I", RUNTIME, "-I", work, *cflags, "-c", src_file, "-o", obj]
        pending.append((src_file, cmd))
    running = []
    failed = None
    while pending or running:
        while pending and len(running) < jobs:
            src_file, cmd = pending.pop(0)
            running.append((src_file, subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)))
        src_file, proc = running.pop(0)
        err = proc.communicate()[1]
        if proc.returncode != 0 and failed is None:
            failed = err
    if failed is not None:
        print("Oops! the C compiler failed:\n" + failed[-4000:])
        sys.exit(1)
    r = subprocess.run([cc, *objs, *link_extra, *STACK_FLAGS, "-o", out], capture_output=True, text=True)
    if r.returncode != 0:
        print("Oops! linking failed:\n" + r.stderr[-4000:])
        sys.exit(1)
    if not keep_c:
        os.remove(c_path)
    if run:
        res = subprocess.run([out] + (extra_args or []))
        sys.exit(res.returncode)
    return out


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        sys.exit(0 if args else 1)
    path, out, run, keep, debug, rest = None, None, False, False, False, []
    ios, ios_opts = False, {"--bundle-id": None, "--name": None, "--resources": "", "--icon": None}
    kernel, kernel_opts = False, {"--arch": "x86", "--iso": None}
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-o":
            out = args[i + 1]; i += 2; continue
        if a == "--ios":
            ios = True; i += 1; continue
        if a in ios_opts:
            ios_opts[a] = args[i + 1]; i += 2; continue
        if a == "--kernel":
            kernel = True; i += 1; continue
        if a in kernel_opts:
            kernel_opts[a] = args[i + 1]; i += 2; continue
        if a == "--run":
            run = True
        elif a == "--keep-c":
            keep = True
        elif a == "--debug":
            debug = True
        elif path is None:
            path = a
        else:
            rest.append(a)
        i += 1
    if kernel:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import kernel_build
        kernel_build.build_kernel(sys.modules[__name__], path, out, kernel_opts["--arch"], kernel_opts["--iso"], debug, keep)
        return
    if ios:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import ios_build
        comp = Compiler(path, debug=debug)
        try:
            comp.compile_program()
        except CompileError as e:
            print(f"Oops! {e}")
            sys.exit(1)
        base = os.path.splitext(os.path.basename(path))[0]
        name = ios_opts["--name"] or base.capitalize()
        bundle = ios_opts["--bundle-id"] or "com.vanta." + "".join(ch for ch in base.lower() if ch.isalnum())
        out_app = out or os.path.join(os.path.dirname(os.path.abspath(path)), name + ".app")
        ios_build.build_ios(comp, out_app, name, bundle, ios_opts["--resources"].split(","), ios_opts["--icon"],
                            ["-O0", "-g"] if debug else ["-O2"])
        return
    build(path, out, run, keep, debug, rest)


if __name__ == "__main__":
    main()
