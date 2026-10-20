#!/usr/bin/env python3
"""vantac: compiles a Vanta program into C and builds a native executable.

It reads programs with vanta.py's own parser, so it accepts exactly the language the interpreter runs, and the
runtime (native/runtime) reproduces the interpreter's behaviour and messages. Every Vanta function becomes a C
function; every scope is a heap environment (so closures work), and every intermediate value lives in a scope slot,
which keeps the garbage collector precise.

    python3 native/vantac.py program.va [-o program] [--run] [--keep-c] [--debug]
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
INTERP_ONLY = set(vanta.BUILTINS) - NATIVE


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
            for _, body in st[3]:
                declared_names(body, out)
            declared_names(st[4], out)
        elif tag in ("while", "repeat"):
            declared_names(st[3], out)
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

    def slot(self, name):
        if name not in self.slots:
            self.slots[name] = len(self.slots)
        return self.slots[name]


class Compiler:
    def __init__(self, main_path, debug=False):
        self.main_path = os.path.abspath(main_path)
        self.debug = debug
        self.funcs = []            # C function definitions
        self.protos = []
        self.consts = {}           # text constant -> index
        self.fn_count = 0
        self.modules = {}          # absolute path -> module function name
        self.module_order = []
        self.fixed = set()
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
        for p in (name, with_ext, os.path.join(ROOT, "lib", with_ext), os.path.join(packages, with_ext),
                  os.path.join(packages, name, "main.va")):
            if os.path.isfile(p):
                return os.path.abspath(p)
        raise CompileError(f"could not find a module named '{name}'")

    def collect_globals(self, stmts, from_dir, names, seen):
        """Top-level names of the program and everything it imports (they all share the global scope)."""
        declared_names(stmts, names)
        for st in self.walk_stmts(stmts):
            if st[0] == "fix":
                self.fixed.add(st[2])
            if st[0] == "import" and st[2][0] == "lit" and isinstance(st[2][1], str):
                p = self.resolve_import(st[2][1], from_dir)
                if p not in seen:
                    seen.add(p)
                    self.collect_globals(self.load(p), os.path.dirname(p), names, seen)

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
            elif tag in ("while", "repeat"):
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
        self.gscope = Scope("global", None, gnames)
        self.gscope.global_scope = self.gscope
        body = self.compile_body(main, self.gscope, os.path.dirname(self.main_path), is_global=True)
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
        init = ["int main(int argc, char **argv) {", "    vrt_init(argc, argv);",
                f"    vrt_globals = vrt_env(NULL, {nslots});"]
        for text, i in self.consts.items():
            b = text.encode("utf-8")
            init.append(f"    K[{i}] = vrt_perm_str({c_str(text)}, {len(b)});")
        for n in sorted(self.used_builtins):
            init.append(f'    BI_{n} = vrt_builtin_named("{n}");')
        init.append(f"    vrt_globals->s[{self.gscope.slots['pi']}] = VF(3.141592653589793);")
        init.append(f"    vrt_globals->s[{self.gscope.slots['e']}] = VF(2.718281828459045);")
        init += ["    vanta_main();", "    fflush(stdout);", "    return 0;", "}"]
        return "\n".join(out + init) + "\n"

    def compile_body(self, stmts, scope, src_dir, is_global=False):
        ctx = FnCtx(self, scope, src_dir)
        ctx.emit_block(stmts, 1)
        scope.ntemps_max = max(scope.ntemps_max, ctx.tmax)
        return ctx.lines

    def compile_function(self, name, params, body, parent_scope, src_dir, method=False):
        """Returns the C name of a function taking (clo, argc, argv, self, super)."""
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
        ctx = FnCtx(self, scope, src_dir, fn_name=name)
        ctx.lines.append(f"    int saved_line = vrt_line;")
        ctx.lines.append(f"    vrt_bind_check({c_str(name)}, argc, {len(params)});")
        ctx.lines.append(f"    VEnv *E = vrt_env(clo, NSLOTS);")
        ctx.lines.append(f"    vrt_root_push(E);")
        if method:
            ctx.lines.append(f"    E->s[{scope.slots['me']}] = self;")
            ctx.lines.append(f"    E->s[{scope.slots['super']}] = super_;")
        for i, (pname, default) in enumerate(params):
            s = scope.slots[pname]
            if default is None:
                ctx.lines.append(f"    if (argc > {i}) E->s[{s}] = argv[{i}]; else vrt_missing_arg({c_str(name)}, {c_str(pname)});")
            else:
                ctx.lines.append(f"    if (argc > {i}) E->s[{s}] = argv[{i}]; else {{")
                v = ctx.expr(default, 2)
                ctx.lines.append(f"        E->s[{s}] = {v};")
                ctx.lines.append("    }")
                ctx.reset_temps()
        ctx.lines.append("    vrt_safepoint();")
        ctx.emit_block(body, 1)
        ctx.lines.append("    vrt_root_pop();")
        ctx.lines.append("    vrt_line = saved_line;")
        ctx.lines.append("    return VNIL;")
        named = len(scope.slots)
        nslots = named + ctx.tmax
        sig = f"static V {cname}(VEnv *clo, int argc, V *argv, V self, V super_)"
        self.protos.append(sig + ";")
        body_lines = [sig + " {", "    (void)self; (void)super_;"] + [l.replace("NSLOTS", str(nslots)).replace("@@N@@", str(named)) for l in ctx.lines] + ["}"]
        self.funcs.append("\n".join(body_lines))
        return cname

    def compile_module(self, path):
        if path in self.modules:
            return self.modules[path]
        cname = self.new_fn("MOD")
        self.modules[path] = cname
        stmts = self.load(path)
        ctx = FnCtx(self, self.gscope, os.path.dirname(path))
        ctx.emit_block(stmts, 1)
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
                    cands.append(f"vrt_globals->s[{scope.slots[name]}]")
                else:
                    cands.append(f"{path}->s[{scope.slots[name]}]")
            if scope.kind == "global":
                break
            nxt = scope.parent
            if nxt is None:
                nxt = self.scope.global_scope
                if name in nxt.slots and not any(c.startswith("vrt_globals") for c in cands):
                    cands.append(f"vrt_globals->s[{nxt.slots[name]}]")
                break
            path = f"{path}->parent"
            scope = nxt
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
            target_env = "vrt_globals"
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
        for _ in range(self.tries - upto):
            self.out("vrt_try_pop();", ind)

    def stmt(self, st, ind):
        tag, line = st[0], st[1]
        self.out(f"vrt_line = {line};", ind)
        if tag == "expr":
            self.expr(st[2], ind)
        elif tag == "say":
            if st[2] is None:
                self.out("vrt_say(VUNDEF);", ind)
            else:
                self.out(f"vrt_say({self.expr(st[2], ind)});", ind)
        elif tag in ("let", "fix"):
            v = self.expr(st[3], ind)
            self.define(st[2], v, ind, fix=(tag == "fix"))
        elif tag == "let_multi":
            vals = self.value_group(st[3], len(st[2]), ind)
            for n, v in zip(st[2], vals):
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
            self.out(f"{t} = {self.arith_c(sign, cur, amt)};", ind)
            self.assign(target, t, ind, line)
        elif tag == "append":
            v = self.expr(st[2], ind)
            tgt = self.expr(st[3], ind)
            self.out(f'if ({tgt}.t != VT_LIST) vrt_fail("you can only \'add ... to\' a list");', ind)
            self.out(f"vrt_list_push({tgt}, {v});", ind)
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
            self.out(f"for (int64_t n{n} = {c}.u.i, i{n} = 0; i{n} < n{n}; i{n}++) {{", ind)
            self.loops.append(self.tries)
            self.out("vrt_safepoint();", ind + 1)
            self.emit_block(st[3], ind + 1)
            self.loops.pop()
            self.out("}", ind)
        elif tag in ("foreach", "foreach2"):
            pair = tag == "foreach2"
            iter_node = st[4] if pair else st[3]
            body = st[5] if pair else st[4]
            n = self.u()
            src = self.expr(iter_node, ind)
            lst = self.temp()
            self.out(f"{lst} = {'vrt_iter_pairs' if pair else 'vrt_iter_list'}({src});", ind)
            saved = self.hold()
            self.out(f"for (int64_t i{n} = 0; i{n} < AS_LIST({lst})->len; i{n}++) {{", ind)
            self.loops.append(self.tries)
            self.out("vrt_safepoint();", ind + 1)
            if pair:
                self.define(st[2], f"AS_LIST(AS_LIST({lst})->items[i{n}])->items[0]", ind + 1)
                self.define(st[3], f"AS_LIST(AS_LIST({lst})->items[i{n}])->items[1]", ind + 1)
            else:
                self.define(st[2], f"AS_LIST({lst})->items[i{n}]", ind + 1)
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
        elif tag == "attempt":
            n = self.u()
            self.out(f"{{ VTry tr{n}; vrt_try_push(&tr{n});", ind)
            self.out(f"if (setjmp(tr{n}.jb) == 0) {{", ind)
            self.tries += 1
            self.emit_block(st[2], ind + 1)
            self.tries -= 1
            self.out("vrt_try_pop();", ind + 1)
            self.out("} else {", ind)
            self.define(st[3], "vrt_caught()", ind + 1)
            self.emit_block(st[4], ind + 1)
            self.out("} }", ind)
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
            self.define(name, f"vrt_func({c_str(name)}, {cname}, E)", ind)
        elif tag == "type":
            _, _, name, parent_name, fields, methods = st
            parent = self.read_name(parent_name, ind, line) if parent_name else "VUNDEF"
            mnames = list(methods.keys())
            base = self.temps(len(mnames)) if mnames else None
            for i, mn in enumerate(mnames):
                fn = methods[mn]
                cname = self.c.compile_function(mn, fn.params, fn.body, self.scope, self.src_dir, method=True)
                self.out(f"E->s[{self.slot_expr(base + i)}] = vrt_func({c_str(mn)}, {cname}, vrt_globals);", ind)
            fl = ", ".join(c_str(f) for f in fields) or "NULL"
            ml = ", ".join(c_str(m) for m in mnames) or "NULL"
            n = self.u()
            self.out(f"{{ static const char *fs{n}[] = {{{fl}}}; static const char *ms{n}[] = {{{ml}}};", ind)
            mptr = f"&E->s[{self.slot_expr(base)}]" if mnames else "NULL"
            self.define(name, f"vrt_type({c_str(name)}, {parent}, {len(fields)}, fs{n}, {len(mnames)}, ms{n}, {mptr})", ind + 1)
            self.out("}", ind)
        elif tag == "import":
            node = st[2]
            if node[0] != "lit" or not isinstance(node[1], str):
                raise CompileError(f"line {line}: native builds need import with a fixed file name")
            path = self.c.resolve_import(node[1], self.src_dir)
            mod = self.c.compile_module(path)
            self.out(f"{mod}();", ind)
        else:
            raise CompileError(f"line {line}: unsupported statement {tag}")

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
    ARITH = {"+": "'+'", "-": "'-'", "*": "'*'", "/": "'/'", "%": "'%'", "^": "'^'",
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
                return f"VF({float(v)!r})"
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
            self.out(f"{lst} = vrt_iter_list({src});", ind)
            saved = self.hold()
            hidden = self.scope.slot(f"<comp{self.u()}:{var}>")
            self.scope.alias.append((var, hidden))
            n = self.u()
            self.out(f"for (int64_t i{n} = 0; i{n} < AS_LIST({lst})->len; i{n}++) {{", ind)
            self.out(f"E->s[{hidden}] = AS_LIST({lst})->items[i{n}];", ind + 1)
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
            self.release(saved)
            return res
        if tag == "lambda":
            params = [(p, None) for p in node[1]]
            cname = self.c.compile_function("<anonymous>", params, [("return", 0, node[2])], self.scope, self.src_dir)
            t = self.temp()
            self.out(f'{t} = vrt_func("<anonymous>", {cname}, E);', ind)
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
    cmd = [cc, *flags, "-std=c11", "-w", "-I", RUNTIME, c_path,
           os.path.join(RUNTIME, "vrt.c"), os.path.join(RUNTIME, "vrt_builtins.c"), "-lm", "-o", out]
    if comp.used_builtins & GAME:
        # A game: add the SDL2 video/input runtime.
        try:
            sdl = subprocess.run(["sdl2-config", "--cflags", "--libs"], capture_output=True, text=True, check=True).stdout.split()
        except (OSError, subprocess.CalledProcessError):
            print("Oops! this program is a game and needs SDL2 (macOS: brew install sdl2; Linux: apt install libsdl2-dev)")
            sys.exit(1)
        cmd[-4:-4] = [os.path.join(RUNTIME, "vgame.c")]
        cmd += sdl
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


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    path, out, run, keep, debug, rest = None, None, False, False, False, []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-o":
            out = args[i + 1]; i += 2; continue
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
    build(path, out, run, keep, debug, rest)


if __name__ == "__main__":
    main()
