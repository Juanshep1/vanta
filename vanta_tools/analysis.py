"""Source analysis for editor features (used by `vanta lsp`).

Reads Vanta source *lexically*, so it keeps working while a file is half-typed and
can't be parsed yet, and it knows exact columns (the parser only keeps lines):

  * tokens: every name in the code (comments skipped; names inside "{...}" text
    interpolation included), with what comes before a dot (`geo.area` -> qual "geo")
  * declarations: functions, types (fields, methods, shared values), kinds and their
    values, variables, constants, parameters, loop names, modules (`import ... as`),
    `from ... use` names and tests, each with its scope, signature, ## doc and type note
  * scopes: functions and tests (each test runs in its own scope)

`Index` holds the analyses of many files (open buffers win over the disk) and answers
the editor questions: what a name at a position refers to, every reference to a
declaration (across files and imports), the members of a value, and the inferred type."""

import os
import re

IDENT = re.compile(r"[A-Za-z_]\w*")
NUMBER = re.compile(r"\d[\w.]*")
ALWAYS_OPEN = {"if", "repeat", "while", "for", "to", "attempt", "type", "match", "test", "using"}
NEVER_OPEN = {"end", "say", "let", "change", "fix", "give", "add", "import", "ask", "stop", "skip",
              "increase", "decrease", "has", "note", "expect", "otherwise", "rescue", "when", "from",
              "remove", "yield", "shared", "private"}
SCOPE_KINDS = ("function", "method", "test")
TOP_KINDS = ("function", "type", "kind", "variable", "constant", "module", "import", "test")
LITERAL_TYPES = {"yes": "yes-no", "no": "yes-no", "true": "yes-no", "false": "yes-no", "nothing": "nothing"}


class Token:
    __slots__ = ("name", "line", "col", "qual", "member", "call", "decl")

    def __init__(self, name, line, col, qual=None, member=False, call=False):
        self.name, self.line, self.col = name, line, col
        self.qual = qual            # the name before the dot ("geo" in geo.area), "?" for an expression
        self.member = member        # comes right after a dot
        self.call = call            # followed by "("
        self.decl = None            # the Decl this token declares, if it is a declaration

    @property
    def end(self):
        return self.col + len(self.name)


class Decl:
    def __init__(self, name, kind, line, col, path, **kw):
        self.name, self.kind, self.line, self.col, self.path = name, kind, line, col, path
        self.end_line = line
        self.container = None       # type / kind name for members
        self.scope = None           # enclosing function/test Decl (None: top level)
        self.params = []            # [(name, note, default, rest)]
        self.returns = None
        self.note = None            # type note (`let x: number`, `has age: number`, `a: text`)
        self.value = None           # source text of the value (for inference)
        self.doc = ""
        self.parent = None          # `type B from A` -> "A"
        self.private = False
        self.shared = False
        self.module = None          # module/import: the resolved file path
        self.module_name = None     # the text in import "..."
        self.target = None          # import: the name in the module
        self.signature = ""
        for k, v in kw.items():
            setattr(self, k, v)

    @property
    def key(self):
        return (self.path, self.line, self.col, self.name)

    @property
    def is_local(self):
        return self.scope is not None

    def __repr__(self):
        return f"<{self.kind} {self.name} {os.path.basename(self.path or '?')}:{self.line + 1}>"


# ---------------------------------------------------------------------- lexing

def _strip_comment(text):
    """The code part of a line (no trailing # comment), honouring strings."""
    in_str, i = False, 0
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "#":
            return text[:i]
        i += 1
    return text


def scan_line(text, line, base=0, out=None):
    """Name tokens in one line of code. Strings are skipped except their {...} parts."""
    out = [] if out is None else out
    i, n = 0, len(text)
    prev_tok = None                  # the last name token
    since = ""                       # non-space characters seen since prev_tok
    while i < n:
        c = text[i]
        if c == "#":
            break
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "{":
                    if j + 1 < n and text[j + 1] == "{":
                        j += 2
                        continue
                    depth, k = 1, j + 1
                    while k < n and depth and text[k] != '"':
                        if text[k] == "{":
                            depth += 1
                        elif text[k] == "}":
                            depth -= 1
                        k += 1
                    inner = text[j + 1:k - 1] if depth == 0 else text[j + 1:k]
                    spec = _top_colon(inner)
                    if spec >= 0:
                        inner = inner[:spec]
                    scan_line(inner, line, base + j + 1, out)
                    j = k
                    continue
                j += 1
            i = j + 1
            prev_tok, since = None, '"'
            continue
        if c.isdigit():
            i = NUMBER.match(text, i).end()
            prev_tok, since = None, "0"
            continue
        if c.isalpha() or c == "_":
            m = IDENT.match(text, i)
            name = m.group(0)
            member = since.endswith(".") and not since.endswith("..")
            qual = None
            if member:
                qual = prev_tok.name if (prev_tok is not None and since == ".") else "?"
            j = m.end()
            while j < n and text[j] == " ":
                j += 1
            tok = Token(name, line, base + i, qual, member, j < n and text[j] == "(")
            out.append(tok)
            prev_tok, since = tok, ""
            i = m.end()
            continue
        if c not in " \t":
            since += c
        i += 1
    return out


def _top_colon(s):
    """Index of a format-spec colon at depth 0 in an interpolation ("{x:.2}"), or -1."""
    depth, in_str = 0, False
    for i, c in enumerate(s):
        if in_str:
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ":" and depth == 0:
            return i
    return -1


def split_top(s, sep=","):
    """Split at depth-0 separators (outside brackets and strings), keeping offsets."""
    parts, depth, in_str, start = [], 0, False, 0
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == sep and depth == 0:
            parts.append((start, s[start:i]))
            start = i + 1
        i += 1
    parts.append((start, s[start:]))
    return parts


def first_word(text):
    m = IDENT.match(text)
    return m.group(0) if m else ""


# ---------------------------------------------------------------------- analysis

class Analysis:
    """Everything known about one file."""

    def __init__(self, text, path=None, V=None):
        self.text = text
        self.path = path
        self.V = V
        self.lines = text.split("\n")
        self.tokens = []
        self.by_line = {}
        self.decls = []
        self.scopes = []             # Decl of functions/methods/tests (have line..end_line)
        self.types = {}              # name -> type Decl
        self.kinds = {}              # name -> kind Decl
        self.members = {}            # container name -> [Decl]
        self.imports = []            # (module text, alias or None, [names] or None, line)
        self.blocks = []             # (start, end) of every block
        self._analyze()

    # -------------------------------------------------------------- helpers
    def scope_at(self, line):
        """Innermost function/test containing a line."""
        best = None
        for s in self.scopes:
            if s.line <= line <= s.end_line and (best is None or s.line >= best.line):
                best = s
        return best

    def container_at(self, line):
        """The type a line sits in (for `me`)."""
        best = None
        for t in list(self.types.values()):
            if t.line <= line <= t.end_line and (best is None or t.line >= best.line):
                best = t
        return best

    def token_at(self, line, col):
        for t in self.by_line.get(line, ()):
            if t.col <= col <= t.end:
                return t
        return None

    def top_level(self, name):
        return [d for d in self.decls if d.name == name and d.scope is None and d.container is None
                and d.kind in TOP_KINDS]

    # -------------------------------------------------------------- the pass
    def _opens(self, code, head):
        if head in ALWAYS_OPEN:
            if head == "for" and not code.startswith("for each"):
                return False
            return True
        if head == "kind":
            return " is " not in code
        if head in NEVER_OPEN or not head:
            return False
        if self.V is not None:
            try:
                from . import fmt
                return fmt.opens_block(self.V, code, head)
            except Exception:
                return False
        return False

    def _doc_above(self, line):
        out = []
        i = line - 1
        while i >= 0:
            t = self.lines[i].strip()
            if t.startswith("##"):
                out.append(t[2:].strip())
                i -= 1
            else:
                break
        return "\n".join(reversed(out))

    def _decl(self, name, kind, line, col, **kw):
        d = Decl(name, kind, line, col, self.path, **kw)
        self.decls.append(d)
        for t in self.by_line.get(line, ()):
            if t.col == col and t.name == name:
                t.decl = d
                break
        return d

    def _analyze(self):
        lines = self.lines
        stack = []                    # [(head, decl or None, start line)]
        in_triple = False
        joining_from = None           # first line of a statement that goes on (open bracket / operator)
        for ln, raw in enumerate(lines):
            if in_triple:
                if raw.count('"""') % 2 == 1:
                    in_triple = False
                continue
            stripped = raw.strip()
            if stripped.count('"""') % 2 == 1:
                in_triple = True
                stripped = stripped[:stripped.index('"""')]
            indent = len(raw) - len(raw.lstrip())
            code = _strip_comment(stripped).rstrip()
            if not code or code.startswith("note "):
                continue
            toks = scan_line(raw, ln)
            if toks:
                self.tokens.extend(toks)
                self.by_line[ln] = toks
            cont = joining_from is not None
            depth = _depth(code)
            if cont:
                joining_from = joining_from if (self._still_open(joining_from, ln)) else None
                continue
            if depth > 0 or (code[-1] in "+-*/%^&|,([{" and not code.endswith('"')):
                joining_from = ln
            self._statement(code, ln, indent, stack)
        while stack:                  # unclosed blocks run to the end of the file
            head, d, start = stack.pop()
            self.blocks.append((start, len(lines) - 1))
            if d is not None:
                d.end_line = len(lines) - 1

    def _still_open(self, start, ln):
        text = " ".join(_strip_comment(self.lines[i].strip()) for i in range(start, ln + 1))
        code = text.rstrip()
        return _depth(code) > 0 or (code and code[-1] in "+-*/%^&|,([{" and not code.endswith('"'))

    def _statement(self, code, ln, indent, stack):
        words = code.split()
        head = words[0]
        private = shared = False
        body = code
        while head in ("private", "shared") and len(words) > 1:
            private |= head == "private"
            shared |= head == "shared"
            body = body[len(head):].lstrip()
            words = words[1:]
            head = words[0]
        col0 = indent + (len(code) - len(body))
        top = stack[-1] if stack else None
        scope = self._scope_from(stack)
        container = self._container_from(stack)

        if head == "end":
            if stack:
                h, d, start = stack.pop()
                self.blocks.append((start, ln))
                if d is not None:
                    d.end_line = ln
            return
        if top is not None and top[0] == "kind" and top[1] is not None:
            for off, part in split_top(body):
                name = part.strip()
                if IDENT.fullmatch(name or ""):
                    c = col0 + off + (len(part) - len(part.lstrip()))
                    d = self._decl(name, "member", ln, c, container=top[1].name)
                    self.members.setdefault(top[1].name, []).append(d)
            return

        opens = self._opens(body, head)
        decl = None
        if head == "to":
            decl = self._function(body, ln, col0, scope, container, top)
        elif head == "type":
            m = re.match(r"type\s+([A-Za-z_]\w*)(?:\s+from\s+([\w.]+))?", body)
            if m:
                decl = self._decl(m.group(1), "type", ln, col0 + m.start(1), scope=scope, doc=self._doc_above(ln),
                                  parent=m.group(2), private=private)
                decl.signature = f"type {m.group(1)}" + (f" from {m.group(2)}" if m.group(2) else "")
                self.types[decl.name] = decl
        elif head == "kind":
            m = re.match(r"kind\s+([A-Za-z_]\w*)(?:\s+is\s+(.*))?$", body)
            if m:
                decl = self._decl(m.group(1), "kind", ln, col0 + m.start(1), scope=scope, doc=self._doc_above(ln),
                                  private=private)
                self.kinds[decl.name] = decl
                if m.group(2):
                    base = col0 + m.start(2)
                    names = []
                    for off, part in split_top(m.group(2)):
                        name = part.strip()
                        if IDENT.fullmatch(name or ""):
                            d = self._decl(name, "member", ln, base + off + (len(part) - len(part.lstrip())),
                                           container=decl.name)
                            self.members.setdefault(decl.name, []).append(d)
                            names.append(name)
                decl.signature = f"kind {decl.name}"
        elif head == "has" and container is not None:
            m = re.match(r"has\s+([A-Za-z_]\w*)(?:\s*:\s*([\w-]+))?(?:\s+be\s+(.*))?", body)
            if m:
                d = self._decl(m.group(1), "field", ln, col0 + m.start(1), container=container.name,
                               note=m.group(2), value=m.group(3), doc=self._doc_above(ln))
                self.members.setdefault(container.name, []).append(d)
        elif head in ("let", "fix") or (shared and head not in ("to",) and container is not None):
            self._let(body if head in ("let", "fix") else "let " + body, ln,
                      col0 if head in ("let", "fix") else col0 - 4, scope, container if shared else None,
                      "constant" if head == "fix" else "variable", private, shared)
        elif head == "for" and body.startswith("for each"):
            m = re.match(r"for each\s+(.*?)\s+in\s", body)
            if m:
                self._names(m.group(1), ln, col0 + m.start(1), scope, "loop")
        elif head == "rescue":
            m = re.match(r"rescue\s+([A-Za-z_]\w*)", body)
            if m:
                self._decl(m.group(1), "variable", ln, col0 + m.start(1), scope=scope)
        elif head == "using":
            m = re.match(r"using\s+([A-Za-z_]\w*)\s+be\s+(.*)", body)
            if m:
                self._decl(m.group(1), "variable", ln, col0 + m.start(1), scope=scope, value=m.group(2))
        elif head == "ask":
            m = re.search(r"\binto\s+([A-Za-z_]\w*)\s*$", body)
            if m and not self._visible_name(m.group(1), scope):
                self._decl(m.group(1), "variable", ln, col0 + m.start(1), scope=scope)
        elif head == "import":
            m = re.match(r'import\s+"([^"]+)"(?:\s+as\s+([A-Za-z_]\w*))?', body)
            if m:
                path = self._resolve(m.group(1))
                self.imports.append((m.group(1), m.group(2), None, ln, path))
                if m.group(2):
                    self._decl(m.group(2), "module", ln, col0 + m.start(2), module=path, module_name=m.group(1))
        elif head == "from":
            m = re.match(r'from\s+"([^"]+)"\s+use\s+(.*)', body)
            if m:
                path = self._resolve(m.group(1))
                names = []
                base = col0 + m.start(2)
                for off, part in split_top(m.group(2)):
                    nm = part.strip()
                    if IDENT.fullmatch(nm or ""):
                        self._decl(nm, "import", ln, base + off + (len(part) - len(part.lstrip())),
                                   module=path, module_name=m.group(1), target=nm)
                        names.append(nm)
                self.imports.append((m.group(1), None, names, ln, path))
        elif head == "test":
            m = re.match(r'test\s+"([^"]*)"', body)
            if m:
                decl = Decl(m.group(1), "test", ln, col0, self.path)
                self.decls.append(decl)
        elif head == "when":
            self._pattern(body, ln, col0, scope)
        if "make " in body:
            for m in re.finditer(r"\bmake\s+([\w\s,]*?)\s+give\b", body):
                self._names(m.group(1), ln, col0 + m.start(1), scope, "parameter")
        if " for each " in body:          # comprehensions: [x * 2 for each x in xs]
            for m in re.finditer(r"\bfor each\s+([\w\s,]+?)\s+in\b", body):
                if m.start() > 0:
                    self._names(m.group(1), ln, col0 + m.start(1), scope, "loop")
        if opens:
            if decl is not None and decl.kind in SCOPE_KINDS:
                self.scopes.append(decl)
            stack.append((head, decl, ln))

    def _scope_from(self, stack):
        for h, d, _ in reversed(stack):
            if d is not None and d.kind in SCOPE_KINDS:
                return d
        return None

    def _container_from(self, stack):
        for h, d, _ in reversed(stack):
            if d is not None and d.kind in SCOPE_KINDS:
                return None
            if d is not None and d.kind == "type":
                return d
        return None

    def _visible_name(self, name, scope):
        return any(d.name == name and d.scope is scope for d in self.decls)

    def _resolve(self, module):
        V = self.V
        if V is None:
            return None
        here = os.path.dirname(self.path) if self.path else None
        try:
            return os.path.abspath(V.resolve_import(module, here))
        except Exception:
            pass
        if here:                      # resolve_import tries the cwd first; try next to the file too
            for cand in (os.path.join(here, module), os.path.join(here, module + ".va")):
                if os.path.isfile(cand):
                    return os.path.abspath(cand)
            # paths written relative to a project root (`import "examples/x.va"` run from
            # the repo root): try each folder above the file
            d = os.path.dirname(os.path.abspath(here))
            while d and d != os.path.dirname(d):
                for cand in (os.path.join(d, module), os.path.join(d, module + ".va")):
                    if os.path.isfile(cand):
                        return os.path.abspath(cand)
                d = os.path.dirname(d)
        return None

    def _function(self, body, ln, col0, scope, container, top):
        m = re.match(r"to\s+([A-Za-z_]\w*)\s*(\((.*)\))?\s*(?:->\s*([\w-]+))?", body)
        if not m:
            return None
        kind = "method" if container is not None else "function"
        d = self._decl(m.group(1), kind, ln, col0 + m.start(1), scope=scope, doc=self._doc_above(ln),
                       container=container.name if container is not None else None, returns=m.group(4))
        if container is not None:
            self.members.setdefault(container.name, []).append(d)
            d.shared = body is not None and self._line_has_shared(ln)
        params = []
        if m.group(2):
            base = col0 + m.start(3)
            for off, part in split_top(m.group(3)):
                p = part.strip()
                if not p:
                    continue
                pm = re.match(r"([A-Za-z_]\w*)(\.\.\.)?\s*(?::\s*([\w-]+))?\s*(?:be\s+(.*))?$", p)
                if not pm:
                    continue
                c = base + off + (len(part) - len(part.lstrip()))
                pd = Decl(pm.group(1), "parameter", ln, c, self.path, scope=d, note=pm.group(3), value=pm.group(4))
                self.decls.append(pd)
                for t in self.by_line.get(ln, ()):
                    if t.col == c:
                        t.decl = pd
                params.append((pm.group(1), pm.group(3), pm.group(4), bool(pm.group(2))))
        d.params = params
        d.signature = format_signature(d)
        return d

    def _line_has_shared(self, ln):
        return self.lines[ln].strip().startswith(("shared ", "private shared ", "shared private "))

    def _let(self, body, ln, col0, scope, container, kind, private, shared):
        m = re.match(r"(?:let|fix)\s+(.*?)(?:\s*:\s*([\w-]+))?\s+be\b\s*(.*)$", body)
        if not m:
            return
        names = m.group(1)
        if container is not None:
            for off, part in split_top(names):
                nm = part.strip()
                if IDENT.fullmatch(nm or ""):
                    d = self._decl(nm, "field", ln, col0 + m.start(1) + off + (len(part) - len(part.lstrip())),
                                   container=container.name, value=m.group(3), note=m.group(2), shared=True,
                                   doc=self._doc_above(ln))
                    self.members.setdefault(container.name, []).append(d)
            return
        many = len(split_top(names)) > 1
        for off, part in split_top(names):
            nm = part.strip()
            if not IDENT.fullmatch(nm or ""):
                continue
            c = col0 + m.start(1) + off + (len(part) - len(part.lstrip()))
            self._decl(nm, kind, ln, c, scope=scope, note=m.group(2), value=None if many else m.group(3),
                       private=private, doc=self._doc_above(ln) if scope is None else "")

    def _names(self, text, ln, col, scope, kind):
        for off, part in split_top(text):
            nm = part.strip()
            if IDENT.fullmatch(nm or "") and nm != "_":
                self._decl(nm, kind if kind != "loop" else "variable", ln, col + off + (len(part) - len(part.lstrip())),
                           scope=scope, value="__loop__" if kind == "loop" else None)

    def _pattern(self, body, ln, col0, scope):
        m = re.match(r"when\s+an?\s+([A-Za-z_][\w.]*)\s+with\s+(.*?)(?:\s+if\s+.*)?$", body)
        if m:
            self._names(m.group(2), ln, col0 + m.start(2), scope, "variable")
            return
        # [first, rest...] and {"key": name}: bare names inside brackets bind values
        for bm in re.finditer(r"\[([^\]]*)\]", body):
            for off, part in split_top(bm.group(1)):
                nm = part.strip().rstrip(".")
                if IDENT.fullmatch(nm or "") and nm not in ("_", "yes", "no", "nothing", "true", "false"):
                    self._decl(nm, "variable", ln, col0 + bm.start(1) + off + (len(part) - len(part.lstrip())), scope=scope)
        for bm in re.finditer(r'"[^"]*"\s*:\s*([A-Za-z_]\w*)', body):
            nm = bm.group(1)
            if nm not in ("_", "yes", "no", "nothing", "true", "false"):
                self._decl(nm, "variable", ln, col0 + bm.start(1), scope=scope)


def _depth(code):
    depth, in_str, i = 0, False, 0
    while i < len(code):
        c = code[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return depth


def format_params(d):
    out = []
    for name, note, default, rest in d.params:
        s = name + ("..." if rest else "")
        if note:
            s += f": {note}"
        if default:
            s += f" be {default.strip()}"
        out.append(s)
    return out


def format_signature(d):
    s = f"to {d.name}({', '.join(format_params(d))})"
    if d.returns:
        s += f" -> {d.returns}"
    return s


# ---------------------------------------------------------------------- the index

class Index:
    """Analyses of many files, and the questions an editor asks about them."""

    def __init__(self, V=None, root=None):
        self.V = V
        self.root = root
        self.open = {}               # path -> text of open (maybe unsaved) buffers
        self._cache = {}             # path -> (stamp, Analysis)
        self._ws_files = None
        self._ws_stamp = 0

    # -------------------------------------------------------------- files
    def set_text(self, path, text):
        self.open[path] = text

    def close(self, path):
        self.open.pop(path, None)

    def analysis(self, path):
        if path is None:
            return None
        if path in self.open:
            text = self.open[path]
            stamp = ("open", hash(text))
        else:
            try:
                st = os.stat(path)
            except OSError:
                return None
            stamp = ("disk", st.st_mtime, st.st_size)
            cached = self._cache.get(path)
            if cached and cached[0] == stamp:
                return cached[1]
            try:
                with open(path, encoding="utf-8") as f:
                    text = f.read()
            except (OSError, UnicodeDecodeError):
                return None
        cached = self._cache.get(path)
        if cached and cached[0] == stamp:
            return cached[1]
        a = Analysis(text, path, self.V)
        self._cache[path] = (stamp, a)
        return a

    def workspace_files(self):
        """Every .va file under the root (packages, hidden and build folders skipped)."""
        import time
        if self._ws_files is not None and time.time() - self._ws_stamp < 3:
            return self._ws_files
        files = set(p for p in self.open if p and p.endswith(".va"))
        if self.root and os.path.isdir(self.root):
            count = 0
            for folder, dirs, names in os.walk(self.root):
                dirs[:] = [d for d in dirs if not d.startswith(".") and d not in
                           ("packages", "node_modules", "build", "DerivedData", "__pycache__")]
                for n in names:
                    if n.endswith(".va") and not n.startswith(".vanta-lsp-"):
                        files.add(os.path.join(folder, n))
                        count += 1
                if count > 3000:
                    break
        self._ws_files = sorted(files)
        self._ws_stamp = time.time()
        return self._ws_files

    def plain_imports(self, a, seen=None):
        """Files whose names join this one's: plain `import "x"`, followed recursively."""
        seen = set() if seen is None else seen
        out = []
        for module, alias, names, ln, path in a.imports:
            if alias is None and names is None and path and path not in seen:
                seen.add(path)
                out.append(path)
                sub = self.analysis(path)
                if sub is not None:
                    out += self.plain_imports(sub, seen)
        return out

    # -------------------------------------------------------------- resolving names
    def resolve(self, a, tok):
        """The declarations a token refers to ([] when unknown)."""
        if tok.decl is not None:
            return [tok.decl]
        if tok.member:
            return self.resolve_member(a, tok)
        return self.resolve_name(a, tok.name, tok.line)

    def resolve_name(self, a, name, line, follow_imports=True):
        scope = a.scope_at(line)
        while scope is not None:
            found = [d for d in a.decls if d.name == name and d.scope is scope and d.kind != "test"]
            if found:
                return found[:1]
            scope = scope.scope
        found = a.top_level(name)
        if found:
            d = found[0]
            if d.kind == "import":
                target = self._module_decl(d.module, d.target)
                return [target] if target is not None else [d]
            return [d]
        if follow_imports:
            for p in self.plain_imports(a):
                sub = self.analysis(p)
                if sub is not None:
                    hit = [d for d in sub.top_level(name) if d.kind != "test"]
                    if hit:
                        return hit[:1]
        return []

    def _module_decl(self, path, name):
        sub = self.analysis(path) if path else None
        if sub is None:
            return None
        hit = [d for d in sub.top_level(name) if d.kind != "test"]
        if hit:
            return hit[0]
        for p in self.plain_imports(sub):
            s2 = self.analysis(p)
            if s2 is not None:
                hit = s2.top_level(name)
                if hit:
                    return hit[0]
        return None

    def type_decl(self, a, name):
        """A type (or kind) by name as seen from a file: here, plain imports, or `alias.Type`."""
        if not name:
            return None
        if "." in name:
            alias, _, tname = name.partition(".")
            mods = [d for d in a.top_level(alias) if d.kind == "module"]
            if mods:
                d = self._module_decl(mods[0].module, tname)
                return d if d is not None and d.kind in ("type", "kind") else None
            return None
        hit = self.resolve_name(a, name, 10 ** 9)
        hit = [d for d in hit if d.kind in ("type", "kind")]
        if hit:
            return hit[0]
        return None

    def members_of(self, tdecl, seen=None):
        """Fields, methods and shared values of a type, inherited ones after (or kind values)."""
        seen = set() if seen is None else seen
        if tdecl is None or tdecl.key in seen:
            return []
        seen.add(tdecl.key)
        a = self.analysis(tdecl.path)
        if a is None:
            return []
        own = list(a.members.get(tdecl.name, []))
        if tdecl.kind == "type" and tdecl.parent:
            names = {d.name for d in own}
            for d in self.members_of(self.type_decl(a, tdecl.parent), seen):
                if d.name not in names:
                    own.append(d)
        return own

    def value_type(self, a, d, depth=0):
        """The type of a variable/parameter/field as a word ("number", "text", "Point", ...) or None."""
        if d is None or depth > 6:
            return None
        if d.note:
            return d.note
        if d.kind in ("function", "method"):
            return "function"
        if d.kind in ("type",):
            return "type"
        if d.kind == "kind":
            return "kind"
        if d.kind == "member":
            return d.container
        if d.kind == "module":
            return "module"
        if d.value == "__loop__":
            return self._loop_type(a, d, depth)
        return self.infer(a, d.value, d.line, depth + 1) if d.value else None

    def _loop_type(self, a, d, depth):
        line = a.lines[d.line] if a.path == d.path else ""
        m = re.search(r"for each\s+[\w\s,]+?\s+in\s+(.*)$", _strip_comment(line).strip())
        if not m:
            return None
        src = m.group(1).strip()
        if re.match(r"range\s*\(", src):
            return "number"
        if src.startswith('"'):
            return "text"
        kd = self.type_decl(a, src)
        if kd is not None and kd.kind == "kind":
            return kd.name
        return None

    def infer(self, a, expr, line, depth=0):
        if not expr:
            return None
        e = _strip_comment(expr).strip()
        if not e:
            return None
        if e.startswith('"'):
            return "text"
        if re.fullmatch(r"-?\d[\d_]*(\.\d+)?(e-?\d+)?", e):
            return "number"
        if e in LITERAL_TYPES:
            return LITERAL_TYPES[e]
        if e.startswith("["):
            return "list"
        if e.startswith("{"):
            return "map"
        if e.startswith("make "):
            return "function"
        m = re.match(r"(?:new\s+)?([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)?)\s*\(", e)
        if m and _closes_at_end(e, m.end() - 1):
            name = m.group(1)
            if "." not in name:
                hit = self.resolve_name(a, name, line)
                if hit:
                    h = hit[0]
                    if h.kind == "type":
                        return h.name
                    if h.kind in ("function", "method") and h.returns:
                        return h.returns
                if not hit:
                    from . import checker
                    r = checker.BUILTIN_RETURNS.get(name)
                    if r:
                        return r
                    if name == "set":
                        return "set"
                return None
            alias, _, fn = name.partition(".")
            t = self.type_decl(a, name)
            if t is not None and t.kind == "type":
                return name
            q = self.resolve_name(a, alias, line)
            if q:
                qt = q[0]
                if qt.kind == "module":
                    d = self._module_decl(qt.module, fn)
                    return d.returns if d is not None and d.kind == "function" else None
                tname = self.value_type(a, qt, depth + 1)
                tdecl = self.type_decl(a, tname) if tname else None
                for md in self.members_of(tdecl):
                    if md.name == fn and md.kind == "method":
                        return md.returns
            return None
        if re.fullmatch(r"[A-Za-z_]\w*", e):
            hit = self.resolve_name(a, e, line)
            return self.value_type(self.analysis(hit[0].path) or a, hit[0], depth + 1) if hit else None
        m = re.fullmatch(r"([A-Za-z_]\w*)\.([A-Za-z_]\w*)", e)
        if m:
            q = self.resolve_name(a, m.group(1), line)
            if q and q[0].kind == "kind":
                return q[0].name
        if re.search(r'"', e) and re.search(r"\s\+\s", e):
            return "text"
        if re.search(r"\b(is|and|or|not)\b|[<>]=?", e) and not re.search(r'"', e):
            return "yes-no"
        if re.fullmatch(r"[\w\s.()+\-*/%^]+", e) and re.search(r"[-+*/%^]", e):
            kinds = set()
            for m in re.finditer(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?|\d[\d_.]*", e):
                w = m.group(0)
                if w[0].isdigit():
                    kinds.add("number")
                elif w in ("plus", "minus", "times", "mod", "divided", "by"):
                    continue
                else:
                    kinds.add(self.infer(a, w, line, depth + 1) if depth < 4 else None)
            if kinds == {"number"}:
                return "number"
            if "text" in kinds and "+" in e:
                return "text"
        return None

    def qualifier_type(self, a, qual, line):
        """What sits before a dot: ("module", path) / ("type", Decl) / ("kind", Decl) / ("instance", Decl)."""
        if qual in ("me", "super"):
            t = a.container_at(line)
            if t is None:
                return None
            if qual == "super":
                return ("instance", self.type_decl(a, t.parent)) if t.parent else None
            return ("instance", t)
        if qual is None or qual == "?":
            return None
        hit = self.resolve_name(a, qual, line)
        if not hit:
            return None
        d = hit[0]
        da = self.analysis(d.path) or a
        if d.kind == "module":
            return ("module", d.module)
        if d.kind == "type":
            return ("type", d)
        if d.kind == "kind":
            return ("kind", d)
        tname = self.value_type(da, d)
        if tname:
            t = self.type_decl(da, tname)
            if t is not None:
                return ("instance", t) if t.kind == "type" else ("kindvalue", t)
        return None

    def resolve_member(self, a, tok):
        q = self.qualifier_type(a, tok.qual, tok.line)
        if q is not None:
            kind, what = q
            if kind == "module":
                d = self._module_decl(what, tok.name)
                return [d] if d is not None else []
            if what is None:
                return []
            hits = [m for m in self.members_of(what) if m.name == tok.name]
            return hits[:1]
        # unknown qualifier: any member with that name (here, plain imports, the workspace)
        out = []
        for p in [a.path] + self.plain_imports(a):
            sub = self.analysis(p)
            if sub is None:
                continue
            for name, ms in sub.members.items():
                out += [m for m in ms if m.name == tok.name and m.kind != "member"]
        return out

    # -------------------------------------------------------------- references
    def references(self, decl, include_decl=True):
        """[(path, line, col, length)] for every use of a declaration."""
        if decl is None or decl.kind in ("test", "builtin"):
            return []
        out = []
        if decl.is_local:
            a = self.analysis(decl.path)
            if a is None:
                return []
            scope = decl.scope
            for t in a.tokens:
                if t.name == decl.name and not t.member and scope.line <= t.line <= scope.end_line:
                    hit = self.resolve(a, t)
                    if hit and hit[0].key == decl.key:
                        out.append((a.path, t.line, t.col, len(t.name)))
        else:
            files = set(self.workspace_files())
            files.add(decl.path)
            for p in sorted(files):
                if not p:
                    continue
                a = self.analysis(p)
                if a is None or decl.name not in a.text:
                    continue
                for t in a.tokens:
                    if t.name != decl.name:
                        continue
                    hit = self.resolve(a, t)
                    if hit and any(h is not None and h.key == decl.key for h in hit):
                        out.append((p, t.line, t.col, len(t.name)))
                        continue
                    # `from "x" use name` declares a local alias that points at decl
                    if t.decl is not None and t.decl.kind == "import" and \
                            self._module_decl(t.decl.module, t.decl.target) is not None and \
                            self._module_decl(t.decl.module, t.decl.target).key == decl.key:
                        out.append((p, t.line, t.col, len(t.name)))
        if not include_decl:
            out = [r for r in out if not (r[0] == decl.path and r[1] == decl.line and r[2] == decl.col)]
        seen, uniq = set(), []
        for r in out:
            if r not in seen:
                seen.add(r)
                uniq.append(r)
        return uniq

    # -------------------------------------------------------------- unused names
    def unused(self, a):
        """Local `let`s that nothing reads, and `import ... as` names never used."""
        out = []
        for d in a.decls:
            if d.name.startswith("_"):
                continue
            if d.kind == "variable" and d.scope is not None and d.value != "__loop__" and \
                    a.lines[d.line].lstrip().startswith(("let ", "fix ")):
                scope = d.scope
                used = any(t.name == d.name and t.decl is None and not t.member and
                           scope.line <= t.line <= scope.end_line for t in a.tokens)
                if not used:
                    out.append((d, f"'{d.name}' is never used"))
            elif d.kind == "module":
                used = any(t.name == d.name and t.decl is None and not t.member for t in a.tokens)
                if not used:
                    out.append((d, f"the module name '{d.name}' is never used"))
        return out


def _closes_at_end(e, open_idx):
    depth, in_str = 0, False
    for i in range(open_idx, len(e)):
        c = e[i]
        if in_str:
            if c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i == len(e) - 1
    return False
