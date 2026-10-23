"""`vanta check FILES` — finds likely mistakes without running the program.

It reads each file with the interpreter's own parser and reports, as `file.va:LINE: message`:
  * names that are never defined anywhere they could be seen (with a "did you mean" suggestion),
  * `change` of a name that doesn't exist, or of a `fix`ed one,
  * calls to your own functions and types with too many / too few values, or a named value they don't have,
  * module names that don't exist or are private (geo.nope, from "x" use nope), unknown kind values (Color.purple),
  * type mismatches against optional type notes, when the value's type is obvious:
        to area(r: number) -> number     area("big")          -> r should be a number, not text
        let name: text be 5                                  -> name should be text, not a number
        give back "x"  inside  -> number                     -> should give back a number, not text
It is deliberately cautious: when it can't be sure of a type, it says nothing.
Exit status: 0 when no problems were found, 1 otherwise.
"""
import difflib
import os

# what some builtins give back (for type notes)
BUILTIN_RETURNS = {
    "length": "number", "number": "number", "text": "text", "uppercase": "text", "lowercase": "text",
    "trim": "text", "replace": "text", "join": "text", "round": "number", "floor": "number", "ceil": "number",
    "abs": "number", "sqrt": "number", "sum": "number", "random": "number", "range": "list", "split": "list",
    "keys": "list", "values": "list", "sort": "list", "reverse": None, "set": "set", "list": "list",
    "is_number": "yes-no", "is_text": "yes-no", "is_list": "yes-no", "is_map": "yes-no", "contains": "yes-no",
    "format": "text", "type_of": "text", "to_json": "text", "read_file": "text", "now": "number",
}
TYPE_WORDS = {"number", "text", "yes-no", "list", "map", "set", "nothing", "function", "generator", "bytes",
              "any", "module", "kind", "type"}


def native_builtin_names():
    """Builtins only native builds have (the canvas/game runtime, ...): read from the runtime's tables."""
    import re
    names = set()
    rt = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "native", "runtime")
    try:
        for folder, _, files in os.walk(rt):
            for f in files:
                if not f.endswith(".c"):
                    continue
                src = open(os.path.join(folder, f), encoding="utf-8", errors="replace").read()
                for tab in re.findall(r"static const Entry \w*table\w*\[\] = \{(.*?)\n\};", src, re.S):
                    names.update(re.findall(r'\{"(\w+)",', tab))
    except OSError:
        pass
    return names


NATIVE_BUILTINS = None


class Problem(Exception):
    pass


class Checker:
    def __init__(self, V, path, source=None):
        self.V = V
        self.path = path
        self.source = source      # unsaved text of `path` (the editor's buffer), or None to read the file
        self.problems = []
        self.funcs = {}           # name -> (params, return note, line)   top-level functions
        self.types = {}           # name -> {"fields", "setup", "parent", "methods"}
        self.enums = {}           # name -> members
        self.modules = {}         # alias -> (exports, private, path)
        self.globals = set()
        self.fixed = set()
        self.notes = {}           # (line, what, name) -> type text (copied from the parser)

    # ------------------------------------------------------------------ reporting
    def report(self, line, msg):
        self.problems.append((line, msg))

    def suggest(self, name, visible):
        close = difflib.get_close_matches(name, sorted(visible), n=1, cutoff=0.75)
        return f" (did you mean '{close[0]}'?)" if close else ""

    # ------------------------------------------------------------------ loading
    def parse(self, path):
        V = self.V
        if self.source is not None and os.path.abspath(path) == os.path.abspath(self.path):
            src = self.source
        else:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        V.TYPE_NOTES.clear()
        saved = V.CURRENT_FILE
        V.CURRENT_FILE = os.path.abspath(path)
        try:
            stmts = V.parse_program(V.load_lines(src))
        finally:
            V.CURRENT_FILE = saved
        notes = dict(V.TYPE_NOTES)
        return stmts, notes

    def resolve(self, name, from_dir):
        try:
            return os.path.abspath(self.V.resolve_import(name, from_dir))
        except self.V.VantaError:
            return find_above(name, from_dir)

    def module_names(self, path, seen=None):
        """Top-level names a file defines, including what its plain imports define."""
        seen = seen if seen is not None else set()
        if path in seen:
            return set(), set()
        seen.add(path)
        try:
            stmts, _ = self.parse(path)
        except (OSError, self.V.VantaError):
            return set(), set()
        names = set(declared(stmts))
        private = set(self.V.private_names(stmts))
        for st in walk(stmts):
            if st[0] == "import" and st[2][0] == "lit":
                p = self.resolve(st[2][1], os.path.dirname(path))
                if p:
                    names |= self.module_names(p, seen)[0]
        return names, private

    # ------------------------------------------------------------------ the check
    def run(self):
        V = self.V
        try:
            stmts, self.notes = self.parse(self.path)
        except V.VantaError as e:
            msg = str(e)
            line = 0
            if msg.startswith("line "):
                line = int(msg[5:msg.index(":")]) if ":" in msg else 0
                msg = msg[msg.index(":") + 2:] if ":" in msg else msg
            self.report(line, msg)
            return self.problems
        here = os.path.dirname(os.path.abspath(self.path))
        self.globals = set(declared(stmts)) | {"pi", "e"}
        self.collect(stmts, here, top=True)
        for st in walk(stmts):
            if st[0] == "import" and st[2][0] == "lit":
                p = self.resolve(st[2][1], here)
                if p is None:
                    self.report(st[1], f"there is no module called '{st[2][1]}'")
                else:
                    self.globals |= self.module_names(p)[0]
        self.block(stmts, [{}], None, here)
        return self.problems

    def collect(self, stmts, here, top):
        """Remember functions, types, kinds and modules defined at the top level."""
        for st in stmts:
            if st[0] == "private":
                st = st[2]
            tag = st[0]
            if tag == "func":
                self.funcs[st[2]] = (st[3], self.notes.get((st[1], "return", st[2])), st[1])
            elif tag == "type":
                methods = st[5]
                self.types[st[2]] = {"fields": list(st[4]), "parent": st[3],
                                     "setup": methods["setup"].params if "setup" in methods else None,
                                     "methods": set(methods), "line": st[1]}
            elif tag == "enum":
                self.enums[st[2]] = list(st[3])
            elif tag == "fix":
                self.fixed.add(st[2])
            elif tag in ("import_as", "use") and st[2][0] == "lit":
                p = self.resolve(st[2][1], here)
                if p is None:
                    self.report(st[1], f"there is no module called '{st[2][1]}'")
                    continue
                exports, private = self.module_names(p)
                exports -= private
                if tag == "import_as":
                    self.modules[st[3]] = (exports, private, p)
                else:
                    for nm in st[3]:
                        if nm in private:
                            self.report(st[1], f"'{nm}' is private to the module '{os.path.basename(p)[:-3]}'")
                        elif nm not in exports:
                            self.report(st[1], f"the module '{os.path.basename(p)[:-3]}' has no '{nm}'"
                                        + self.suggest(nm, exports))
        for name in [n for n in self.fixed]:
            for st in stmts:
                if st[0] == "let" and st[2] == name:
                    self.fixed.discard(name)

    def all_fields(self, tname):
        t = self.types.get(tname)
        if t is None:
            return None
        fields = []
        if t["parent"]:
            pf = self.all_fields(t["parent"])
            if pf is None:
                return None
            fields = list(pf)
        for f in t["fields"]:
            if f not in fields:
                fields.append(f)
        return fields

    def setup_of(self, tname):
        t = self.types.get(tname)
        while t is not None:
            if t["setup"] is not None:
                return t["setup"]
            t = self.types.get(t["parent"]) if t["parent"] else None
        return None

    # ------------------------------------------------------------------ scopes
    def visible(self, scopes):
        out = set(self.globals) | set(self.V.BUILTIN_VALUES)
        for s in scopes:
            out |= set(k for k in s if not k.startswith("@"))
        return out

    def known(self, name, scopes):
        global NATIVE_BUILTINS
        if name in self.globals or name in self.V.BUILTIN_VALUES:
            return True
        if NATIVE_BUILTINS is None:
            NATIVE_BUILTINS = native_builtin_names()
        if name in NATIVE_BUILTINS:
            return True
        canvas = getattr(self.V, "_canvas_names", None)      # the native canvas runtime's builtins (window, rect, ...)
        if canvas is not None and name in canvas():
            return True
        return any(name in s for s in scopes)

    def note_of(self, name, scopes):
        for s in reversed(scopes):
            if name in s:
                return s.get("@" + name)
        return None

    def local_shadow(self, name, scopes):
        return any(name in s for s in scopes[1:])

    # ------------------------------------------------------------------ statements
    def block(self, stmts, scopes, fn, here):
        for st in stmts:
            try:
                self.stmt(st, scopes, fn, here)
            except Problem:
                pass

    def stmt(self, st, scopes, fn, here):
        tag, line = st[0], st[1]
        E = lambda node: self.expr(node, scopes, line)
        if tag in ("let", "fix"):
            vt = E(st[3])
            note = self.notes.get((line, "let", st[2]))
            if note:
                scopes[-1]["@" + st[2]] = note
                self.mismatch(line, vt, note, f"'{st[2]}' should be {article(note)}")
        elif tag == "let_multi":
            for v in st[3]:
                E(v)
        elif tag == "assign":
            vt = E(st[3])
            target = st[2]
            if target[0] == "name":
                nm = target[1]
                if not self.known(nm, scopes):
                    self.report(line, f"'{nm}' doesn't exist yet (use: let {nm} be ...)"
                                + self.suggest(nm, self.visible(scopes)))
                elif nm in self.fixed and not self.local_shadow(nm, scopes):
                    self.report(line, f"'{nm}' is fixed and can't be changed")
                else:
                    note = self.note_of(nm, scopes)
                    if note:
                        self.mismatch(line, vt, note, f"'{nm}' should be {article(note)}")
            else:
                self.target(target, scopes, line)
        elif tag == "assign_multi":
            for v in st[3]:
                E(v)
            for t in st[2]:
                if t[0] == "name" and not self.known(t[1], scopes):
                    self.report(line, f"'{t[1]}' doesn't exist yet (use: let {t[1]} be ...)")
                elif t[0] != "name":
                    self.target(t, scopes, line)
        elif tag == "mutate":
            E(st[2]); E(st[4])
        elif tag in ("say", "expr"):
            if st[2] is not None:
                E(st[2])
        elif tag == "return":
            vt = E(st[2]) if st[2] is not None else None
            if fn is not None and fn.get("returns") and st[2] is not None and st[2] != ("lit", None):
                self.mismatch(line, vt, fn["returns"], f"'{fn['name']}' should give back {article(fn['returns'])}")
        elif tag == "yield":
            E(st[2])
        elif tag == "if":
            for c, body in st[2]:
                E(c)
                self.block(body, scopes, fn, here)
            self.block(st[3], scopes, fn, here)
        elif tag in ("while", "repeat"):
            E(st[2])
            self.block(st[3], scopes, fn, here)
        elif tag == "foreach":
            E(st[3])
            self.block(st[4], scopes, fn, here)
        elif tag == "foreach2":
            E(st[4])
            self.block(st[5], scopes, fn, here)
        elif tag == "match":
            E(st[2])
            for vn, body in st[3]:
                self.when(vn, scopes, line)
                self.block(body, scopes, fn, here)
            self.block(st[4], scopes, fn, here)
        elif tag == "attempt":
            self.block(st[2], scopes, fn, here)
            self.block(st[4], scopes, fn, here)
        elif tag == "using":
            E(st[3])
            self.block(st[4], scopes, fn, here)
        elif tag in ("append", "remove"):
            E(st[2]); E(st[3])
        elif tag == "ask":
            if st[2] is not None:
                E(st[2])
        elif tag == "func":
            self.function(st[2], st[3], st[4], scopes, line, method=False)
        elif tag == "type":
            _, _, name, parent, fields, methods = st
            if parent and "." not in parent and not self.known(parent, scopes):
                self.report(line, f"'{parent}' is not defined" + self.suggest(parent, self.visible(scopes)))
            for fname, vnode in getattr(methods, "shared_fields", ()):
                E(vnode)
            for mname, m in methods.items():
                self.function(mname, m.params, m.body, [scopes[0]], line, method=not m.shared,
                              type_name=name)
        elif tag == "private":
            self.stmt(st[2], scopes, fn, here)
        elif tag in ("test", "lock"):
            body = st[3] if len(st) > 3 and isinstance(st[3], list) else []
            self.block(body, scopes, fn, here)

    def function(self, name, params, body, scopes, line, method, type_name=None):
        local = {p for p, _ in params}
        local |= set(declared(body))
        if method:
            local |= {"me", "super"}
        scope = {n: True for n in local}
        top = body[0][1] if body else 10 ** 9
        for p, d in params:
            # the note is keyed by the `to` line: the last one at or after `line` and before the body
            cands = [ln for (ln, what, nm) in self.notes if what == "param" and nm == p and line <= ln <= top]
            note = self.notes.get((max(cands), "param", p)) if cands else None
            if note:
                scope["@" + p] = note
            if d is not None and d != self.V.REST_PARAM:
                self.expr(d, scopes + [scope], line)
        fn = {"name": name, "returns": None}
        # find the return note: the `to` line is the first line before the body
        for (ln, what, nm), note in self.notes.items():
            if what == "return" and nm == name and (not body or ln < body[0][1]) and ln >= line:
                fn["returns"] = note
        self.block(body, scopes + [scope], fn, None)

    def target(self, node, scopes, line):
        if node[0] == "index":
            self.expr(node[1], scopes, line); self.expr(node[2], scopes, line)
        elif node[0] == "getattr":
            self.expr(node[1], scopes, line)

    def when(self, vn, scopes, line):
        if vn[0] == "anyof":
            for v in vn[1]:
                self.expr(v, scopes, line)
        elif vn[0] == "pattern":
            for p in vn[1]:
                self.pattern(p, scopes, line)
            if vn[2] is not None:
                self.expr(vn[2], scopes, line)
        else:
            self.expr(vn, scopes, line)

    def pattern(self, p, scopes, line):
        tag = p[0]
        if tag == "pat_value":
            self.expr(p[1], scopes, line)
        elif tag == "pat_list":
            for i in p[1]:
                self.pattern(i, scopes, line)
        elif tag == "pat_map":
            for k, v in p[1]:
                self.expr(k, scopes, line)
                self.pattern(v, scopes, line)
        elif tag == "pat_type":
            t = p[1]
            if t[0] == "name" and t[1] not in TYPE_WORDS and not self.known(t[1], scopes):
                self.report(line, f"'{t[1]}' is not a type you've defined" + self.suggest(t[1], self.visible(scopes)))

    # ------------------------------------------------------------------ expressions (give back a type or None)
    def expr(self, node, scopes, line):
        if node is None:
            return None
        tag = node[0]
        X = lambda n: self.expr(n, scopes, line)
        if tag == "lit":
            v = node[1]
            if v is None:
                return "nothing"
            if isinstance(v, bool):
                return "yes-no"
            if isinstance(v, (int, float)):
                return "number"
            if isinstance(v, str):
                return "text"
            return None
        if tag == "name":
            nm = node[1]
            if not self.known(nm, scopes):
                self.report(line, f"'{nm}' is not defined" + self.suggest(nm, self.visible(scopes)))
                return None
            note = self.note_of(nm, scopes)
            if note:
                return note
            if nm in self.types and not self.local_shadow(nm, scopes):
                return "type"
            return None
        if tag == "arith":
            a, b = X(node[2]), X(node[3])
            if node[1] == "+" and "text" in (a, b):
                return "text"
            if a == "number" and b == "number":
                return "number"
            if node[1] == "+" and a == "list" and b == "list":
                return "list"
            return None
        if tag in ("cmp",):
            X(node[2]); X(node[3])
            return "yes-no"
        if tag in ("and", "or"):
            X(node[1]); X(node[2])
            return "yes-no"
        if tag == "not":
            X(node[1])
            return "yes-no"
        if tag in ("neg", "bitnot"):
            t = X(node[1])
            return "number" if t == "number" else None
        if tag in ("isa", "in", "notin"):
            X(node[1]); X(node[2])
            return "yes-no"
        if tag == "ternary":
            c, a, b = X(node[1]), X(node[2]), X(node[3])
            return a if a == b else None
        if tag == "format":
            for p in node[1]:
                X(p)
            return "text"
        if tag == "fmtspec":
            X(node[1])
            return "text"
        if tag == "list":
            for i in node[1]:
                X(i)
            return "list"
        if tag == "map":
            for k, v in node[1]:
                X(k); X(v)
            return "map"
        if tag in ("call", "callkw"):
            return self.call(node, scopes, line)
        if tag == "index":
            X(node[1]); X(node[2])
            return None
        if tag == "getattr":
            return self.getattr(node, scopes, line)
        if tag == "sliceop":
            t = X(node[1])
            if node[2] is not None:
                X(node[2])
            if node[3] is not None:
                X(node[3])
            return t if t in ("list", "text") else None
        if tag == "lambda":
            self.expr(node[2], scopes + [{p: True for p in node[1]}], line)
            return "function"
        if tag in ("listcomp", "mapcomp"):
            var = node[-3]
            names = var if isinstance(var, list) else [var]
            self.expr(node[-2], scopes, line)
            inner = scopes + [{n: True for n in names}]
            if tag == "listcomp":
                self.expr(node[1], inner, line)
            else:
                self.expr(node[1], inner, line); self.expr(node[2], inner, line)
            if node[-1] is not None:
                self.expr(node[-1], inner, line)
            return "list" if tag == "listcomp" else "map"
        if tag == "anyof":
            for v in node[1]:
                X(v)
            return None
        return None

    def getattr(self, node, scopes, line):
        base, attr = node[1], node[2]
        if base[0] == "name" and not self.local_shadow(base[1], scopes):
            nm = base[1]
            if nm in self.modules:
                exports, private, path = self.modules[nm]
                mod = os.path.basename(path)[:-3]
                if attr in private:
                    self.report(line, f"'{attr}' is private to the module '{mod}'")
                elif attr not in exports:
                    self.report(line, f"the module '{mod}' has no '{attr}'" + self.suggest(attr, exports))
                return None
            if nm in self.enums:
                if attr not in self.enums[nm]:
                    self.report(line, f"the kind {nm} has no value '{attr}' (it has {', '.join(self.enums[nm])})")
                return nm
        self.expr(base, scopes, line)
        return None

    def call(self, node, scopes, line):
        callee, args = node[1], node[2]
        named = node[3] if node[0] == "callkw" else []
        types = [self.expr(a, scopes, line) for a in args]
        for _, v in named:
            self.expr(v, scopes, line)
        if callee[0] != "name":
            self.expr(callee, scopes, line)
            return None
        nm = callee[1]
        if not self.known(nm, scopes):
            self.report(line, f"there is no function called '{nm}'" + self.suggest(nm, self.visible(scopes)))
            return None
        if self.local_shadow(nm, scopes) or (nm not in self.globals and nm not in self.V.BUILTIN_VALUES):
            return None
        if nm in self.funcs:
            params, returns, _ = self.funcs[nm]
            self.arity(nm, params, len(args), named, line)
            for (pname, _), t in zip(params, types):
                note = self.param_note(nm, pname)
                if note:
                    self.mismatch(line, t, note, f"'{pname}' of {nm} should be {article(note)}")
            return returns
        if nm in self.types:
            setup = self.setup_of(nm)
            if setup is not None:
                self.arity(nm, setup, len(args), named, line)
            else:
                fields = self.all_fields(nm)
                if fields is not None:
                    given = len(args) + len(named)
                    for k, _ in named:
                        if k not in fields:
                            self.report(line, f"{nm} has no field named '{k}'" + self.suggest(k, fields))
                    if given != len(fields) and not named:
                        self.report(line, f"{nm} expects {len(fields)} value(s) ({', '.join(fields)}), but got {given}")
            return nm
        if nm in self.V.BUILTIN_VALUES and nm not in self.globals:
            return BUILTIN_RETURNS.get(nm)
        return None

    def param_note(self, fname, pname):
        _, _, line = self.funcs[fname]
        return self.notes.get((line, "param", pname))

    def arity(self, name, params, nargs, named, line):
        rest = bool(params) and params[-1][1] == self.V.REST_PARAM
        plain = [p for p in params if p[1] != self.V.REST_PARAM]
        required = [p for p, d in plain if d is None]
        names = [p for p, _ in plain]
        for k, _ in named:
            if k not in names:
                self.report(line, f"'{name}' has no value named '{k}'" + self.suggest(k, names))
        given = nargs + len([k for k, _ in named if k in names])
        if not rest and nargs > len(plain):
            self.report(line, f"'{name}' takes {'at most ' if len(required) < len(plain) else ''}{len(plain)} "
                              f"value(s), but got {nargs}")
        elif given < len(required):
            missing = [p for p in required[nargs:] if p not in dict(named)]
            if missing:
                self.report(line, f"'{name}' is missing a value for '{missing[0]}'")

    def mismatch(self, line, got, want, what):
        if got is None or want is None:
            return
        base = want.split(" of ")[0]
        if base == "any" or got == "nothing" or got == base:
            return
        if got in self.types and base in self.types:       # a subtype is fine
            t = got
            while t:
                if t == base:
                    return
                t = self.types.get(t, {}).get("parent")
            self.report(line, f"{what}, but this is {article(got)}")
            return
        if base not in TYPE_WORDS and base not in self.types:
            return                                         # a type we don't know about: say nothing
        if got not in TYPE_WORDS and got not in self.types:
            return
        self.report(line, f"{what}, but this is {article(got)}")


def article(t):
    if t in ("text", "nothing", "yes-no"):
        return {"text": "text", "nothing": "nothing", "yes-no": "yes/no"}[t]
    return ("an " if t[:1].lower() in "aeiou" else "a ") + t


def declared(stmts, out=None):
    """Names a block defines in its own scope (like the compiler's declared_names)."""
    out = [] if out is None else out

    def add(n):
        if n not in out:
            out.append(n)
    for st in stmts:
        tag = st[0]
        if tag in ("let", "fix", "func", "type", "enum"):
            add(st[2])
        elif tag == "let_multi":
            for n in st[2]:
                add(n)
        elif tag == "foreach":
            add(st[2]); declared(st[4], out)
        elif tag == "foreach2":
            add(st[2]); add(st[3]); declared(st[5], out)
        elif tag == "ask":
            add(st[3])
        elif tag == "attempt":
            declared(st[2], out); add(st[3]); declared(st[4], out)
        elif tag == "if":
            for _, b in st[2]:
                declared(b, out)
            declared(st[3], out)
        elif tag == "match":
            from_patterns(st[3], out)
            for _, b in st[3]:
                declared(b, out)
            declared(st[4], out)
        elif tag in ("while", "repeat", "lock", "test"):
            if len(st) > 3 and isinstance(st[3], list):
                declared(st[3], out)
        elif tag == "private":
            declared([st[2]], out)
        elif tag == "import_as":
            add(st[3])
        elif tag == "use":
            for n in st[3]:
                add(n)
        elif tag == "using":
            add(st[2]); declared(st[4], out)
    return out


def from_patterns(branches, out):
    for vn, _ in branches:
        if vn[0] == "pattern":
            for p in vn[1]:
                for n in _PATTERN_NAMES(p, []):
                    if n not in out:
                        out.append(n)


_PATTERN_NAMES = None


def walk(stmts):
    for st in stmts:
        yield st
        tag = st[0]
        if tag == "if":
            for _, b in st[2]:
                yield from walk(b)
            yield from walk(st[3])
        elif tag == "match":
            for _, b in st[3]:
                yield from walk(b)
            yield from walk(st[4])
        elif tag in ("while", "repeat"):
            yield from walk(st[3])
        elif tag == "foreach":
            yield from walk(st[4])
        elif tag == "foreach2":
            yield from walk(st[5])
        elif tag == "attempt":
            yield from walk(st[2]); yield from walk(st[4])
        elif tag == "func":
            yield from walk(st[4])
        elif tag == "private":
            yield from walk([st[2]])
        elif tag == "using":
            yield from walk(st[4])


def check_file(V, path):
    """[(line, message)] for one file."""
    global _PATTERN_NAMES
    _PATTERN_NAMES = V.pattern_names
    return Checker(V, path).run()


def check_source(V, text, path):
    """[(line, message)] for unsaved text that belongs at `path` (imports resolve next to it)."""
    global _PATTERN_NAMES
    _PATTERN_NAMES = V.pattern_names
    return Checker(V, path, source=text).run()


def main(V, args):
    if not args:
        print("Usage: vanta check FILES")
        return 1
    total = 0
    for path in args:
        if not os.path.isfile(path):
            print(f"Oops! could not open {path}")
            total += 1
            continue
        problems = sorted(set(check_file(V, path)))
        for line, msg in problems:
            print(f"{path}:{line}: {msg}")
        if problems:
            print(f"{path}: {len(problems)} problem{'s' if len(problems) != 1 else ''} found")
        else:
            print(f"{path}: no problems found")
        total += len(problems)
    return 1 if total else 0


def find_above(name, from_dir):
    """A path written relative to a project root (`import "examples/x.va"` run from the
    repo root): look in each folder above the importing file."""
    d = os.path.abspath(from_dir) if from_dir else None
    while d and d != os.path.dirname(d):
        for cand in (os.path.join(d, name), os.path.join(d, name + ".va")):
            if os.path.isfile(cand):
                return os.path.abspath(cand)
        d = os.path.dirname(d)
    return None
