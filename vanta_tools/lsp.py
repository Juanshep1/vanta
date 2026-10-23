"""`vanta lsp` — a Language Server Protocol server for Vanta (stdio, JSON-RPC 2.0).

Features:
  * diagnostics as you type: syntax errors, the type checker's findings (`vanta check`) with
    exact ranges, and warnings for local names that are never used
  * quick fixes: "did you mean 'X'?" replaces the misspelled name
  * completion that knows where it is: members after a dot (a type's fields and methods,
    a module's names, a kind's values), module names inside import "...", your own names in
    scope, keywords, builtins with their signature and docs, and block snippets
  * hover (signature, ## docs, inferred type), signature help while typing arguments
  * go to definition, find all references and rename — across files and imports
  * document symbols (a tree: types with their fields and methods, kinds with their values),
    workspace symbols, and whole-document formatting (vanta fmt)

The analysis itself lives in analysis.py (lexical, so it works on half-typed code)."""

import json
import os
import re
import select
import sys
from urllib.parse import quote, unquote, urlparse

from . import analysis, builtin_docs, docgen, errors, fmt
from .checker import find_above

DEF_RE = r"^\s*(?:to\s+{n}\b|type\s+{n}\b|kind\s+{n}\b|fix\s+{n}\s+be\b|let\s+(?:[\w\s,]*,\s*)?{n}\s*(?:,[\w\s,]*)?\s+be\b|has\s+{n}\s*$)"
WORD_RE = re.compile(r"[A-Za-z_]\w*")
DID_YOU_MEAN = re.compile(r"did you mean '([A-Za-z_][\w.]*)'")

# LSP enums
K_TEXT, K_METHOD, K_FUNCTION, K_FIELD, K_VARIABLE, K_CLASS, K_MODULE, K_PROPERTY = 1, 2, 3, 5, 6, 7, 9, 10
K_ENUM, K_KEYWORD, K_SNIPPET, K_FILE, K_ENUM_MEMBER, K_CONSTANT = 13, 14, 15, 17, 20, 21
S_MODULE, S_CLASS, S_METHOD, S_FIELD, S_ENUM, S_FUNCTION, S_VARIABLE, S_CONSTANT = 2, 5, 6, 8, 10, 12, 13, 14
S_ENUM_MEMBER, S_EVENT = 22, 24

SNIPPETS = [
    ("to", "function", "to ${1:name}(${2})\n    $0\nend"),
    ("if", "if … end", "if ${1:condition}\n    $0\nend"),
    ("ifo", "if … otherwise … end", "if ${1:condition}\n    $0\notherwise\n    \nend"),
    ("for each", "loop over items", "for each ${1:item} in ${2:items}\n    $0\nend"),
    ("repeat", "repeat N times", "repeat ${1:3} times\n    $0\nend"),
    ("while", "loop while yes", "while ${1:condition}\n    $0\nend"),
    ("type", "type … end", "type ${1:Name}\n    has ${2:field}\n    $0\nend"),
    ("kind", "kind … end", "kind ${1:Name}\n    ${2:first}, ${3:second}\nend"),
    ("match", "match … when … end", "match ${1:value}\n    when ${2:case}\n        $0\n    otherwise\n        \nend"),
    ("when", "when case", "when ${1:case}\n    $0"),
    ("attempt", "attempt … rescue … end", "attempt\n    $0\nrescue problem\n    say problem\nend"),
    ("test", "test \"…\" … end", "test \"${1:what it checks}\"\n    expect ${2:value} is ${3:expected}\nend"),
    ("using", "using … be … end", "using ${1:f} be ${2:value}\n    $0\nend"),
]
PHRASES = ("is at least", "is at most", "is not", "is over", "is under", "is in", "is not in", "is a",
           "divided by", "give back", "for each", "otherwise if")
SYMBOL_KIND = {"function": S_FUNCTION, "method": S_METHOD, "type": S_CLASS, "kind": S_ENUM, "field": S_FIELD,
               "member": S_ENUM_MEMBER, "variable": S_VARIABLE, "constant": S_CONSTANT, "module": S_MODULE,
               "test": S_EVENT, "import": S_VARIABLE}
COMPLETION_KIND = {"function": K_FUNCTION, "method": K_METHOD, "type": K_CLASS, "kind": K_ENUM, "field": K_FIELD,
                   "member": K_ENUM_MEMBER, "variable": K_VARIABLE, "constant": K_CONSTANT, "module": K_MODULE,
                   "parameter": K_VARIABLE, "import": K_VARIABLE}


def uri_to_path(uri):
    p = urlparse(uri)
    return unquote(p.path) if p.scheme == "file" else uri


def path_to_uri(path):
    return "file://" + quote(os.path.abspath(path))


def rng(line, col, length):
    return {"start": {"line": line, "character": col}, "end": {"line": line, "character": col + length}}


class Server:
    def __init__(self, V, inp=None, out=None):
        self.V = V
        self.inp = inp or sys.stdin.buffer
        self.out = out or sys.stdout.buffer
        self.docs = {}
        self.running = True
        self.shutdown = False
        self.index = analysis.Index(V)
        self._buf = bytearray()
        try:
            self._fd = self.inp.fileno()
        except (AttributeError, OSError, ValueError):
            self._fd = None

    # ------------------------------------------------------------ transport
    def _fill(self):
        """Read more bytes into our own buffer (so we can tell whether input is waiting)."""
        data = os.read(self._fd, 65536)
        if not data:
            return False
        self._buf += data
        return True

    def _readline(self):
        if self._fd is None:
            return self.inp.readline()
        while b"\n" not in self._buf:
            if not self._fill():
                line, self._buf = bytes(self._buf), bytearray()
                return line
        i = self._buf.index(b"\n") + 1
        line = bytes(self._buf[:i])
        del self._buf[:i]
        return line

    def _read(self, n):
        if self._fd is None:
            return self.inp.read(n)
        while len(self._buf) < n:
            if not self._fill():
                break
        data = bytes(self._buf[:n])
        del self._buf[:n]
        return data

    def read_message(self):
        headers = {}
        while True:
            line = self._readline()
            if not line:
                return None
            line = line.decode("ascii", "replace").strip()
            if not line:
                break
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        n = int(headers.get("content-length", 0))
        body = self._read(n) if n else b""
        return json.loads(body.decode("utf-8")) if body else None

    def send(self, msg):
        data = json.dumps(msg).encode("utf-8")
        self.out.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii") + data)
        self.out.flush()

    def reply(self, mid, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": mid}
        if error:
            msg["error"] = error
        else:
            msg["result"] = result
        self.send(msg)

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def input_waiting(self):
        """More messages already queued? (then diagnostics for a burst of edits wait)."""
        if self._fd is None:
            return False
        if self._buf:
            return True
        try:
            r, _, _ = select.select([self._fd], [], [], 0)
            return bool(r)
        except (ValueError, OSError):
            return False

    # ------------------------------------------------------------ loop
    def serve(self):
        while self.running:
            msg = self.read_message()
            if msg is None:
                break
            try:
                self.handle(msg)
            except Exception as e:                      # never die on one bad request
                if "id" in msg:
                    self.reply(msg["id"], error={"code": -32603, "message": f"internal error: {e}"})
        return 0 if self.shutdown else 1

    def queue(self, uri, change=False):
        """Diagnostics for every change, in order (editors debounce their didChange). If many
        changes are already waiting, only the last of a burst for the same file is checked."""
        if change and self.input_waiting() and self._next_is_change_of(uri):
            return
        self.publish(uri)

    def _next_is_change_of(self, uri):
        """Is the next queued message another didChange of this document? (peeks our buffer)"""
        head, sep, rest = bytes(self._buf).partition(b"\r\n\r\n")
        if not sep:
            return False
        m = re.search(rb"content-length:\s*(\d+)", head, re.I)
        if not m or len(rest) < int(m.group(1)):
            return False
        try:
            msg = json.loads(rest[:int(m.group(1))].decode("utf-8"))
        except ValueError:
            return False
        return msg.get("method") == "textDocument/didChange" and \
            (msg.get("params") or {}).get("textDocument", {}).get("uri") == uri

    def handle(self, msg):
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method == "initialize":
            root = params.get("rootUri") or (params.get("workspaceFolders") or [{}])[0].get("uri") \
                if params.get("rootUri") or params.get("workspaceFolders") else None
            if root:
                self.index.root = uri_to_path(root)
            elif params.get("rootPath"):
                self.index.root = params["rootPath"]
            self.reply(mid, {
                "capabilities": {
                    "textDocumentSync": {"openClose": True, "change": 1, "save": {"includeText": True}},
                    "completionProvider": {"triggerCharacters": [".", "\""]},
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "referencesProvider": True,
                    "renameProvider": {"prepareProvider": True},
                    "signatureHelpProvider": {"triggerCharacters": ["(", ","], "retriggerCharacters": [","]},
                    "documentSymbolProvider": True,
                    "workspaceSymbolProvider": True,
                    "documentHighlightProvider": True,
                    "codeActionProvider": {"codeActionKinds": ["quickfix"]},
                    "documentFormattingProvider": True,
                },
                "serverInfo": {"name": "vanta-lsp", "version": str(self.V.VERSION)},
            })
        elif method == "initialized":
            pass
        elif method == "shutdown":
            self.shutdown = True
            self.reply(mid, None)
        elif method == "exit":
            self.running = False
        elif method == "textDocument/didOpen":
            d = params["textDocument"]
            self.set_doc(d["uri"], d["text"])
            self.queue(d["uri"])
        elif method == "textDocument/didChange":
            uri = params["textDocument"]["uri"]
            changes = params.get("contentChanges") or []
            if changes:
                self.set_doc(uri, changes[-1]["text"])
            self.queue(uri, change=True)
        elif method == "textDocument/didSave":
            uri = params["textDocument"]["uri"]
            if "text" in params:
                self.set_doc(uri, params["text"])
            self.queue(uri)
        elif method == "textDocument/didClose":
            uri = params["textDocument"]["uri"]
            self.docs.pop(uri, None)
            self.index.close(uri_to_path(uri))
            self.notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": []})
        elif method == "workspace/didChangeWatchedFiles":
            self.index._ws_files = None
        elif mid is None:
            pass                                        # other notifications ($/cancelRequest, ...)
        else:
            handler = {
                "textDocument/completion": self.completion,
                "textDocument/hover": self.hover,
                "textDocument/definition": self.definition,
                "textDocument/references": self.references,
                "textDocument/prepareRename": self.prepare_rename,
                "textDocument/rename": self.rename,
                "textDocument/signatureHelp": self.signature_help,
                "textDocument/documentSymbol": self.symbols,
                "textDocument/documentHighlight": self.highlights,
                "textDocument/codeAction": self.code_actions,
                "textDocument/formatting": self.formatting,
                "workspace/symbol": self.workspace_symbols,
            }.get(method)
            if handler is None:
                self.reply(mid, error={"code": -32601, "message": f"method not found: {method}"})
                return
            try:
                self.reply(mid, handler(params))
            except RenameError as e:
                self.reply(mid, error={"code": -32602, "message": str(e)})

    # ------------------------------------------------------------ documents
    def set_doc(self, uri, text):
        self.docs[uri] = text
        self.index.set_text(uri_to_path(uri), text)

    def text(self, uri):
        if uri in self.docs:
            return self.docs[uri]
        try:
            with open(uri_to_path(uri), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

    def analysis_for(self, uri):
        path = uri_to_path(uri)
        if uri not in self.docs and not os.path.isfile(path):
            return None
        if uri not in self.docs:
            return self.index.analysis(path)
        return self.index.analysis(path)

    # ------------------------------------------------------------ diagnostics
    def diagnostics(self, uri, text):
        V = self.V
        out = []
        lines = text.splitlines() or [""]
        V.CURRENT_FILE = uri_to_path(uri)
        try:
            V.parse_program(V.load_lines(text), keep_tests=True)
        except V.VantaError as e:
            msg = str(e)
            m = re.match(r"line (\d+): (.*)", msg, re.S)
            if m:
                ln, body = int(m.group(1)) - 1, m.group(2)
            else:
                ln, body = self.unclosed_block(text), msg
            ln = max(0, min(ln, len(lines) - 1))
            src = lines[ln]
            start, width = self.span(src, body)
            d = {"range": rng(ln, start, width), "severity": 1, "source": "vanta", "message": body}
            hint = errors.hint_for(V, body, src, [text])
            if hint:
                d["message"] += f" ({hint})"
            self.add_fix(d)
            out.append(d)
        except RecursionError:
            pass
        finally:
            V.CURRENT_FILE = None
        if not out:
            found = self.checker_findings(uri, text, lines)
            out += found if found is not None else self.unknown_calls(uri, text, lines)
            out += self.unused_names(uri)
        return out

    def span(self, src, msg):
        """Columns of the name a message is about (the first 'quoted' name found in the line),
        falling back to the caret logic of error reports."""
        for m in errors.QUOTED.finditer(msg):
            name = m.group(1).split(".")[-1]
            hit = re.search(r"(?<![\w.])" + re.escape(name) + r"(?!\w)", src) or \
                re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", src)
            if hit:
                return hit.start(), len(name)
        start, width = errors.caret_span(src, msg)
        if width <= 1 and src.strip():                      # nothing better: the whole statement
            start = len(src) - len(src.lstrip())
            width = len(analysis._strip_comment(src).rstrip()) - start
        return start, max(1, width)

    def add_fix(self, d):
        m = DID_YOU_MEAN.search(d["message"])
        if m:
            d["code"] = "did-you-mean"
            d["data"] = {"replace": m.group(1).split(".")[-1]}

    def unused_names(self, uri):
        a = self.analysis_for(uri)
        if a is None:
            return []
        out = []
        for decl, msg in self.index.unused(a):
            out.append({"range": rng(decl.line, decl.col, len(decl.name)), "severity": 2, "source": "vanta",
                        "message": msg, "code": "unused", "tags": [1]})
        return out

    def unknown_calls(self, uri, text, lines):
        """Without the checker: warn about calls to functions that exist nowhere."""
        V = self.V
        known = set(V.BUILTINS) | set(V.GLOBAL_ENV.vars) | errors.defined_names(text) | {"pi", "e"}
        for p in self.imports(text, uri_to_path(uri)):
            try:
                with open(p, encoding="utf-8") as f:
                    known |= errors.defined_names(f.read())
            except OSError:
                pass
        if re.search(r'^\s*import\s+"[^"]+"\s+as\b', text, re.M):
            return []                  # namespaced imports: leave names to the checker
        out = []
        for i, line in enumerate(lines):
            code = line.split("#", 1)[0]
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
            for m in re.finditer(r"(?<![\w.])([A-Za-z_]\w*)\s*\(", code):
                name = m.group(1)
                if name in known or name in V.RESERVED or name in builtin_docs.KEYWORDS:
                    continue
                if code.lstrip().startswith(("to ", "type ")):
                    continue
                close = errors.suggest(V, name, [text])
                msg = f"I don't know a function called '{name}'"
                if close:
                    msg += f" (did you mean '{close[0]}'?)"
                d = {"range": rng(i, m.start(1), len(name)), "severity": 2, "source": "vanta", "message": msg}
                self.add_fix(d)
                out.append(d)
        return out

    def checker_findings(self, uri, text, lines):
        """Findings from the type/name checker (`vanta check`), if it's installed. The
        checker may expose check_source(text, path) giving [(line, message), ...] or
        [{"line":, "message":, "severity":}, ...]."""
        V = self.V
        fn = getattr(V, "check_source", None)
        if fn is None:
            try:
                from . import checker
            except ImportError:
                return None
            if getattr(checker, "check_source", None) is not None:
                fn = lambda t, p: checker.check_source(V, t, p)
            elif getattr(checker, "check_file", None) is not None:
                fn = lambda t, p: self.check_via_file(checker, t, p)
            else:
                return None
        try:
            found = fn(text, uri_to_path(uri)) or []
        except Exception:
            return []
        out, seen = [], set()
        for item in found:
            if isinstance(item, dict):
                ln, msg = item.get("line", 1), item.get("message", "")
                sev = {"error": 1, "warning": 2, "info": 3}.get(item.get("severity", "error"), 1)
                col, width = item.get("column"), None
            else:
                ln, msg, sev, col, width = item[0], item[1], 1, None, None
            ln = max(0, min(int(ln or 1) - 1, len(lines) - 1))
            if (ln, msg) in seen:
                continue
            seen.add((ln, msg))
            if col is None:
                col, width = self.span(lines[ln], msg)
            d = {"range": rng(ln, col, width or 1), "severity": sev, "source": "vanta check", "message": msg}
            self.add_fix(d)
            out.append(d)
        return out

    def check_via_file(self, checker, text, path):
        """checker.check_file reads a path: give it the saved file, or (for unsaved edits) a
        hidden copy next to it, so relative imports still resolve."""
        try:
            with open(path, encoding="utf-8") as f:
                if f.read() == text:
                    return checker.check_file(self.V, path)
        except OSError:
            pass
        folder = os.path.dirname(path) if os.path.isdir(os.path.dirname(path) or ".") else None
        import tempfile
        fd, tmp = tempfile.mkstemp(prefix=".vanta-lsp-", suffix=".va", dir=folder)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            return checker.check_file(self.V, tmp)
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass

    def unclosed_block(self, text):
        """The line of the innermost block that never got its `end`."""
        stack = []
        for i, raw in enumerate(text.splitlines()):
            t = raw.strip()
            if not t or t.startswith("#"):
                continue
            head = fmt.first_word(t)
            if head == "end":
                if stack:
                    stack.pop()
            elif fmt.opens_block(self.V, t, head):
                stack.append(i)
        return stack[-1] if stack else max(0, len(text.splitlines()) - 1)

    def publish(self, uri):
        self.notify("textDocument/publishDiagnostics",
                    {"uri": uri, "diagnostics": self.diagnostics(uri, self.text(uri))})

    # ------------------------------------------------------------ helpers
    def word_at(self, text, pos):
        lines = text.splitlines()
        if pos["line"] >= len(lines):
            return None, ""
        line = lines[pos["line"]]
        for m in WORD_RE.finditer(line):
            if m.start() <= pos["character"] <= m.end():
                return m.group(0), line
        return None, line

    def at(self, params):
        """(analysis, token, decls) for the position in a request."""
        uri = params["textDocument"]["uri"]
        a = self.analysis_for(uri) if uri in self.docs or os.path.isfile(uri_to_path(uri)) else None
        if a is None:
            a = analysis.Analysis(self.text(uri), uri_to_path(uri), self.V)
        pos = params["position"]
        tok = a.token_at(pos["line"], pos["character"])
        if tok is None:
            return a, None, []
        return a, tok, [d for d in self.index.resolve(a, tok) if d is not None]

    def loc(self, path, line, col, length):
        return {"uri": path_to_uri(path), "range": rng(line, col, length)}

    def imports(self, text, path):
        out = []
        for m in re.finditer(r'^\s*import\s+"([^"]+)"', text, re.M):
            try:
                out.append(os.path.abspath(self.V.resolve_import(m.group(1), os.path.dirname(path))))
            except Exception:
                found = find_above(m.group(1), os.path.dirname(path))
                if found:
                    out.append(found)
        return out

    # ------------------------------------------------------------ completion
    def completion(self, params):
        V = self.V
        uri = params["textDocument"]["uri"]
        text = self.text(uri)
        pos = params.get("position") or {"line": 0, "character": 0}
        lines = text.split("\n")
        line = lines[pos["line"]] if pos["line"] < len(lines) else ""
        before = line[:pos["character"]]
        a = self.analysis_for(uri) or analysis.Analysis(text, uri_to_path(uri), V)

        m = re.search(r'^\s*(?:import|from)\s+"([^"]*)$', before)
        if m:
            return {"isIncomplete": False, "items": self.module_items(uri_to_path(uri))}
        state = _string_state(before)
        if state in ("string", "comment"):
            return {"isIncomplete": False, "items": []}
        m = re.match(r'^\s*from\s+"([^"]+)"\s+use\s+', before)
        if m:
            path = a._resolve(m.group(1))
            sub = self.index.analysis(path) if path else None
            items = []
            if sub is not None:
                for d in sub.decls:
                    if d.scope is None and d.container is None and d.kind in ("function", "type", "kind", "variable",
                                                                              "constant") and not d.private:
                        items.append(self.decl_item(sub, d))
            return {"isIncomplete": False, "items": items}

        m = re.search(r"([A-Za-z_]\w*|\)|\])\s*\.\s*(\w*)$", before)
        if m and not re.search(r"\d\.\w*$", before):
            return {"isIncomplete": False, "items": self.member_items(a, m.group(1), pos["line"])}

        items, seen = [], set()

        def add(item):
            if item["label"] in seen or item["label"].startswith("__"):
                return
            seen.add(item["label"])
            items.append(item)

        word = re.search(r"\w*$", before).group(0)
        if re.search(r"\bnew\s+\w*$", before) or re.search(r"\bis an?\s+\w*$", before):
            for d in self.visible_decls(a, pos["line"]):
                if d.kind in ("type",):
                    add(self.decl_item(a, d))
            if re.search(r"\bis an?\s+\w*$", before):
                for w in ("number", "text", "list", "map", "set", "function", "nothing"):
                    add({"label": w, "kind": K_KEYWORD, "sortText": "1" + w})
            return {"isIncomplete": False, "items": items}

        for d in self.visible_decls(a, pos["line"]):
            if d.line == pos["line"] and d.col <= pos["character"] <= d.col + len(d.name) and d.name == word:
                continue                                    # the name being typed right now
            item = self.decl_item(a, d)
            item["sortText"] = ("0" if d.scope is not None else "1") + d.name
            add(item)
        at_statement_start = before.strip() == word
        if at_statement_start:
            for label, detail, body in SNIPPETS:
                add({"label": label, "kind": K_SNIPPET, "detail": detail, "insertText": body,
                     "insertTextFormat": 2, "sortText": "2" + label, "filterText": label})
        for name in sorted(builtin_docs.KEYWORDS):
            sig, doc = builtin_docs.KEYWORDS[name]
            add({"label": name, "kind": K_KEYWORD, "detail": sig, "documentation": {"kind": "markdown", "value": doc},
                 "sortText": "3" + name})
        for name in sorted(getattr(V, "RESERVED", ())):
            add({"label": name, "kind": K_KEYWORD, "sortText": "3" + name})
        common = set(errors.COMMON_WORDS)
        for name in sorted(V.BUILTINS):
            d = builtin_docs.builtin_doc(name)
            item = {"label": name, "kind": K_FUNCTION, "detail": d[0] if d else f"{name}(...)",
                    "sortText": ("4" if name in common else "5") + name}
            if d:
                doc = d[1] + (f"\n\n```vanta\n{d[2]}\n```" if d[2] else "")
                item["documentation"] = {"kind": "markdown", "value": doc}
            add(item)
        for phrase in PHRASES:
            add({"label": phrase, "kind": K_KEYWORD, "sortText": "6" + phrase})
        for name in sorted(errors.defined_names(text)):    # anything else this file names
            add({"label": name, "kind": K_VARIABLE, "sortText": "7" + name})
        return {"isIncomplete": False, "items": items}

    def visible_decls(self, a, line):
        """Names usable at a line: locals (innermost first), this file's, plain imports'."""
        out, names = [], set()

        def take(d):
            if d.name not in names and d.kind != "test":
                names.add(d.name)
                out.append(d)
        scope = a.scope_at(line)
        while scope is not None:
            for d in a.decls:
                if d.scope is scope:
                    take(d)
            scope = scope.scope
        for d in a.decls:
            if d.scope is None and d.container is None and d.kind in analysis.TOP_KINDS:
                take(d)
        for p in self.index.plain_imports(a):
            sub = self.index.analysis(p)
            if sub is not None:
                for d in sub.decls:
                    if d.scope is None and d.container is None and d.kind in analysis.TOP_KINDS and not d.private:
                        take(d)
        return out

    def decl_item(self, a, d):
        kind = COMPLETION_KIND.get(d.kind, K_TEXT)
        item = {"label": d.name, "kind": kind}
        detail = self.detail(a, d)
        if detail:
            item["detail"] = detail
        if d.doc:
            item["documentation"] = {"kind": "markdown", "value": d.doc}
        return item

    def detail(self, a, d):
        da = self.index.analysis(d.path) or a
        if d.kind in ("function", "method"):
            return d.signature
        if d.kind == "type":
            return d.signature
        if d.kind == "kind":
            return f"kind {d.name}"
        if d.kind == "module":
            return f'module "{d.module_name}"'
        if d.kind == "member":
            return f"{d.container}.{d.name}"
        if d.kind == "import":
            target = self.index._module_decl(d.module, d.target)
            return self.detail(a, target) if target is not None else f'from "{d.module_name}"'
        t = self.index.value_type(da, d)
        if d.kind == "field":
            return f"has {d.name}" + (f": {t}" if t else "") + (f"  (in {d.container})" if d.container else "")
        word = {"constant": "fix", "parameter": "parameter"}.get(d.kind, "let")
        return f"{word} {d.name}" + (f": {t}" if t else "")

    def member_items(self, a, qual, line):
        items = []
        q = self.index.qualifier_type(a, qual, line) if qual not in (")", "]") else None
        if q is not None and q[0] == "module":
            sub = self.index.analysis(q[1]) if q[1] else None
            if sub is not None:
                seen = set()
                for d in sub.decls:
                    if d.scope is None and d.container is None and d.kind in ("function", "type", "kind", "variable",
                                                                              "constant") and not d.private \
                            and d.name not in seen:
                        seen.add(d.name)
                        items.append(self.decl_item(sub, d))
            return items
        if q is not None and q[1] is not None:
            kind, t = q
            if kind == "kindvalue":
                return [{"label": "name", "kind": K_PROPERTY, "detail": "the value's name (text)"},
                        {"label": "index", "kind": K_PROPERTY, "detail": "its position in the kind (number)"}]
            for d in self.index.members_of(t):
                if kind == "type" and not (d.shared or d.kind == "member"):
                    continue
                if kind == "instance" and d.kind == "member":
                    continue
                item = self.decl_item(a, d)
                item["sortText"] = ("0" if d.container == t.name else "1") + d.name
                items.append(item)
            return items
        # unknown value: every field and method we know of
        seen = set()
        for p in [a.path] + self.index.plain_imports(a):
            sub = self.index.analysis(p) if p != a.path else a
            if sub is None:
                continue
            for cname, ms in sub.members.items():
                for d in ms:
                    if d.kind in ("field", "method") and d.name not in seen:
                        seen.add(d.name)
                        items.append(self.decl_item(sub, d))
        return items

    def module_items(self, path):
        items, seen = [], set()
        lib = os.path.join(os.path.dirname(os.path.abspath(self.V.__file__)), "lib")
        here = os.path.dirname(path) if path else None
        for folder, prefix, detail in ((lib, "", "standard library"), (here, "", "next to this file")):
            if not folder or not os.path.isdir(folder):
                continue
            for n in sorted(os.listdir(folder)):
                full = os.path.join(folder, n)
                if n.endswith(".va") and os.path.abspath(full) != os.path.abspath(path or ""):
                    name = n[:-3]
                    if name not in seen:
                        seen.add(name)
                        items.append({"label": name, "kind": K_MODULE, "detail": detail})
        pk = os.path.join(os.path.expanduser("~"), ".vanta", "packages")
        if os.path.isdir(pk):
            for n in sorted(os.listdir(pk)):
                name = n[:-3] if n.endswith(".va") else n
                if name not in seen and not n.startswith("."):
                    seen.add(name)
                    items.append({"label": name, "kind": K_MODULE, "detail": "package"})
        return items

    # ------------------------------------------------------------ hover
    def hover(self, params):
        a, tok, decls = self.at(params)
        if tok is None:
            return None
        r = rng(tok.line, tok.col, len(tok.name))
        if decls:
            return {"contents": {"kind": "markdown", "value": self.describe(a, decls[0])}, "range": r}
        if not tok.member:
            # the user's own documented definitions (other files' docs via docgen)
            summary, items = docgen.extract(a.text)
            for it in items + [m for t in items for m in t.get("members", [])]:
                if it["name"] == tok.name:
                    body = f"```vanta\n{it['signature'] if it['kind'] != 'function' else 'to ' + it['signature']}\n```"
                    if it["doc"]:
                        body += "\n" + it["doc"]
                    return {"contents": {"kind": "markdown", "value": body}, "range": r}
            md = builtin_docs.markdown(self.V, tok.name)
            if md:
                return {"contents": {"kind": "markdown", "value": md}, "range": r}
        return None

    def describe(self, a, d):
        da = self.index.analysis(d.path) or a
        where = ""
        if d.path and d.path != a.path:
            where = f"\n\n*from {os.path.basename(d.path)}*"
        if d.kind in ("function", "method"):
            head = ("shared " if d.shared else "") + d.signature
            sub = f"\n\nmethod of `{d.container}`" if d.container else ""
            if d.kind == "function" and d.scope is not None:
                sub = f"\n\nlocal function in `{d.scope.name}`"
            return f"```vanta\n{head}\n```" + sub + (f"\n\n{d.doc}" if d.doc else "") + where
        if d.kind == "type":
            fields = [m for m in self.index.members_of(d) if m.kind == "field"]
            methods = [m for m in self.index.members_of(d) if m.kind == "method"]
            lines = [d.signature]
            for f in fields[:12]:
                t = self.index.value_type(self.index.analysis(f.path) or da, f)
                lines.append(f"    has {f.name}" + (f": {t}" if t else ""))
            for m in methods[:12]:
                lines.append(f"    {m.signature}")
            lines.append("end")
            return "```vanta\n" + "\n".join(lines) + "\n```" + (f"\n\n{d.doc}" if d.doc else "") + where
        if d.kind == "kind":
            names = [m.name for m in da.members.get(d.name, [])]
            return f"```vanta\nkind {d.name} is {', '.join(names)}\n```" + (f"\n\n{d.doc}" if d.doc else "") + where
        if d.kind == "member":
            names = [m.name for m in da.members.get(d.container, [])]
            idx = names.index(d.name) if d.name in names else 0
            return f"```vanta\n{d.container}.{d.name}\n```\nvalue {idx} of the kind `{d.container}`" + where
        if d.kind == "module":
            sub = self.index.analysis(d.module) if d.module else None
            n = len([x for x in sub.decls if x.scope is None and x.container is None and x.kind != "test"]) if sub else 0
            path = d.module or "(not found)"
            return f"```vanta\nimport \"{d.module_name}\" as {d.name}\n```\nmodule `{path}` — {n} names"
        if d.kind == "import":
            target = self.index._module_decl(d.module, d.target)
            if target is not None:
                return self.describe(a, target)
            return f"```vanta\nfrom \"{d.module_name}\" use {d.name}\n```"
        t = self.index.value_type(da, d)
        if d.kind == "field":
            text = f"```vanta\n{'shared' if d.shared else 'has'} {d.name}" + (f": {t}" if t else "") + "\n```"
            return text + f"\nfield of `{d.container}`" + (f"\n\n{d.doc}" if d.doc else "") + where
        word = {"constant": "fix", "parameter": "(parameter)"}.get(d.kind, "let")
        text = f"```vanta\n{word} {d.name}" + (f": {t}" if t else "") + "\n```"
        if d.scope is not None:
            text += f"\n{'parameter of' if d.kind == 'parameter' else 'local in'} `{d.scope.name}`"
        elif d.doc:
            text += f"\n\n{d.doc}"
        return text + where

    # ------------------------------------------------------------ definition / references
    def definition(self, params):
        uri = params["textDocument"]["uri"]
        text = self.text(uri)
        lines = text.split("\n")
        pos = params["position"]
        line = lines[pos["line"]] if pos["line"] < len(lines) else ""
        m = re.match(r'^\s*(?:import|from)\s+"([^"]+)"', line)
        if m and m.start(1) <= pos["character"] <= m.end(1):
            a = self.analysis_for(uri) or analysis.Analysis(text, uri_to_path(uri), self.V)
            p = a._resolve(m.group(1))
            return {"uri": path_to_uri(p), "range": rng(0, 0, 0)} if p else None
        a, tok, decls = self.at(params)
        if tok is None:
            return None
        if decls:
            out = []
            for d in decls:
                if d.kind == "module" and tok.decl is d and d.module:
                    out.append({"uri": path_to_uri(d.module), "range": rng(0, 0, 0)})
                elif d.kind == "import":
                    target = self.index._module_decl(d.module, d.target)
                    t = target or d
                    out.append(self.loc(t.path, t.line, t.col, len(t.name)))
                elif d.path:
                    out.append(self.loc(d.path, d.line, d.col, len(d.name)))
            return out[0] if len(out) == 1 else out
        # the old text search (a name the analysis couldn't place)
        word = tok.name
        hit = self.find_definition(word, text)
        if hit:
            return {"uri": uri, "range": rng(hit[0], hit[1], len(word))}
        return None

    def find_definition(self, word, text):
        pat = re.compile(DEF_RE.format(n=re.escape(word)))
        for i, line in enumerate(text.splitlines()):
            if pat.match(line):
                col = line.find(word)
                return i, max(col, 0)
        return None

    def target_decl(self, params):
        a, tok, decls = self.at(params)
        if tok is None or not decls:
            return a, tok, None
        d = decls[0]
        if d.kind == "import":
            d = self.index._module_decl(d.module, d.target) or d
        return a, tok, d

    def references(self, params):
        a, tok, d = self.target_decl(params)
        if d is None:
            return []
        include = (params.get("context") or {}).get("includeDeclaration", True)
        return [self.loc(p, l, c, n) for p, l, c, n in self.index.references(d, include_decl=include)]

    def highlights(self, params):
        a, tok, d = self.target_decl(params)
        if d is None:
            return []
        out = []
        for p, l, c, n in self.index.references(d) if d.is_local else self._same_file_refs(a, d):
            if p == a.path:
                out.append({"range": rng(l, c, n), "kind": 3 if (l == d.line and c == d.col) else 2})
        return out

    def _same_file_refs(self, a, d):
        out = []
        for t in a.tokens:
            if t.name == d.name:
                hit = self.index.resolve(a, t)
                if hit and any(h is not None and h.key == d.key for h in hit):
                    out.append((a.path, t.line, t.col, len(t.name)))
        return out

    def prepare_rename(self, params):
        a, tok, d = self.target_decl(params)
        if tok is None:
            raise RenameError("Put the cursor on a name to rename it.")
        if d is None:
            if tok.name in self.V.BUILTINS or tok.name in builtin_docs.KEYWORDS:
                raise RenameError(f"'{tok.name}' is built into Vanta and can't be renamed.")
            raise RenameError(f"I can't tell what '{tok.name}' refers to.")
        self.check_writable(d)
        return {"range": rng(tok.line, tok.col, len(tok.name)), "placeholder": tok.name}

    def check_writable(self, d):
        lib = os.path.join(os.path.dirname(os.path.abspath(self.V.__file__)), "lib")
        if d.path and os.path.abspath(d.path).startswith(lib + os.sep):
            raise RenameError(f"'{d.name}' belongs to the standard library ({os.path.basename(d.path)}).")
        if d.path and os.path.abspath(d.path).startswith(os.path.join(os.path.expanduser("~"), ".vanta")):
            raise RenameError(f"'{d.name}' belongs to an installed package.")

    def rename(self, params):
        new = (params.get("newName") or "").strip()
        a, tok, d = self.target_decl(params)
        if d is None:
            raise RenameError("There's nothing to rename here.")
        self.check_writable(d)
        if not re.fullmatch(r"[A-Za-z_]\w*", new):
            raise RenameError(f"'{new}' is not a valid name (letters, digits and _, not starting with a digit).")
        if new in getattr(self.V, "RESERVED", ()) or new in builtin_docs.KEYWORDS:
            raise RenameError(f"'{new}' is a reserved word.")
        da = self.index.analysis(d.path) or a
        if d.kind in ("field", "method", "member"):
            clash = [m for m in self.index.members_of(da.types.get(d.container) or da.kinds.get(d.container))
                     if m.name == new]
        elif d.is_local:
            clash = [x for x in da.decls if x.name == new and x.scope is d.scope]
        else:
            clash = da.top_level(new)
        if clash:
            c = clash[0]
            raise RenameError(f"'{new}' already exists ({c.kind} on line {c.line + 1}).")
        changes = {}
        for p, l, c, n in self.index.references(d):
            changes.setdefault(path_to_uri(p), []).append({"range": rng(l, c, n), "newText": new})
        return {"changes": changes}

    # ------------------------------------------------------------ signature help
    def signature_help(self, params):
        uri = params["textDocument"]["uri"]
        text = self.text(uri)
        pos = params["position"]
        lines = text.split("\n")
        if pos["line"] >= len(lines):
            return None
        before = lines[pos["line"]][:pos["character"]]
        call = _open_call(before)
        if call is None:
            return None
        name_end, args_text = call
        a = self.analysis_for(uri) or analysis.Analysis(text, uri_to_path(uri), self.V)
        tok = a.token_at(pos["line"], name_end)
        if tok is None or tok.end != name_end:
            return None
        decls = self.index.resolve(a, tok)
        parts = analysis.split_top(args_text)
        active = len(parts) - 1
        named = re.match(r"\s*([A-Za-z_]\w*)\s*:", parts[-1][1])
        label, params_list, doc = None, [], ""
        d = decls[0] if decls else None
        if d is not None and d.kind == "import":
            d = self.index._module_decl(d.module, d.target)
        if d is not None and d.kind in ("function", "method"):
            label, params_list, doc = d.signature[3:], analysis.format_params(d), d.doc
        elif d is not None and d.kind == "type":
            setup = [m for m in self.index.members_of(d) if m.name == "setup" and m.kind == "method"]
            if setup:
                params_list = analysis.format_params(setup[0])
            else:
                params_list = [m.name for m in self.index.members_of(d) if m.kind == "field" and not m.shared]
            label = f"{d.name}({', '.join(params_list)})"
            doc = d.doc
        elif d is None and not tok.member:
            bd = builtin_docs.builtin_doc(tok.name)
            if bd:
                label, doc = bd[0], bd[1]
                inner = re.search(r"\((.*)\)", bd[0])
                params_list = [p.strip() for _, p in analysis.split_top(inner.group(1))] if inner and inner.group(1).strip() else []
        if label is None:
            return None
        if named:
            for i, p in enumerate(params_list):
                if re.match(re.escape(named.group(1)) + r"\b", p):
                    active = i
                    break
        if params_list and active >= len(params_list) and params_list[-1].split(":")[0].endswith("..."):
            active = len(params_list) - 1
        sig = {"label": label, "parameters": []}
        start = label.find("(") + 1
        for p in params_list:
            i = label.find(p, start)
            if i < 0:
                sig["parameters"].append({"label": p})
                continue
            sig["parameters"].append({"label": [i, i + len(p)]})
            start = i + len(p)
        if doc:
            sig["documentation"] = {"kind": "markdown", "value": doc}
        return {"signatures": [sig], "activeSignature": 0, "activeParameter": active}

    # ------------------------------------------------------------ symbols
    def symbols(self, params):
        uri = params["textDocument"]["uri"]
        a = self.analysis_for(uri) or analysis.Analysis(self.text(uri), uri_to_path(uri), self.V)
        out = []

        def sym(d, children=None):
            end_line = max(d.end_line, d.line)
            end_col = len(a.lines[end_line]) if end_line < len(a.lines) else 0
            s = {"name": d.name, "kind": SYMBOL_KIND.get(d.kind, S_VARIABLE),
                 "range": {"start": {"line": d.line, "character": 0}, "end": {"line": end_line, "character": end_col}},
                 "selectionRange": rng(d.line, d.col, len(d.name) if d.kind != "test" else 4),
                 "detail": self.symbol_detail(a, d)}
            if children:
                s["children"] = children
            return s
        for d in a.decls:
            if d.scope is not None or d.container is not None:
                continue
            if d.kind in ("type", "kind"):
                kids = [sym(m) for m in a.members.get(d.name, [])]
                out.append(sym(d, kids))
            elif d.kind in ("function", "variable", "constant", "module", "test", "import"):
                out.append(sym(d))
        return out

    def symbol_detail(self, a, d):
        if d.kind in ("function", "method"):
            return "(" + ", ".join(analysis.format_params(d)) + ")" + (f" -> {d.returns}" if d.returns else "")
        if d.kind == "type":
            return f"from {d.parent}" if d.parent else ""
        if d.kind == "test":
            return "test"
        if d.kind == "module":
            return f'"{d.module_name}"'
        if d.kind == "import":
            return f'from "{d.module_name}"'
        if d.kind in ("variable", "constant", "field"):
            t = self.index.value_type(a, d)
            return t or ""
        return ""

    def workspace_symbols(self, params):
        q = (params.get("query") or "").lower()
        out = []
        for p in self.index.workspace_files():
            a = self.index.analysis(p)
            if a is None:
                continue
            for d in a.decls:
                if d.scope is not None or d.kind in ("parameter", "import"):
                    continue
                if q and not _fuzzy(q, d.name.lower()):
                    continue
                out.append({"name": d.name, "kind": SYMBOL_KIND.get(d.kind, S_VARIABLE),
                            "location": self.loc(p, d.line, d.col, len(d.name)),
                            "containerName": d.container or os.path.basename(p)})
                if len(out) > 500:
                    return out
        return out

    # ------------------------------------------------------------ code actions
    def code_actions(self, params):
        uri = params["textDocument"]["uri"]
        out = []
        for d in (params.get("context") or {}).get("diagnostics", []):
            data = d.get("data") or {}
            new = data.get("replace")
            if not new:
                m = DID_YOU_MEAN.search(d.get("message", ""))
                new = m.group(1).split(".")[-1] if m else None
            if new:
                out.append({"title": f"Change to '{new}'", "kind": "quickfix", "diagnostics": [d], "isPreferred": True,
                            "edit": {"changes": {uri: [{"range": d["range"], "newText": new}]}}})
            elif d.get("code") == "unused":
                r = d["range"]
                lines = self.text(uri).split("\n")
                line = lines[r["start"]["line"]] if r["start"]["line"] < len(lines) else ""
                name = line[r["start"]["character"]:r["end"]["character"]]
                if name and not name.startswith("_"):
                    out.append({"title": f"Rename to '_{name}' (mark as unused)", "kind": "quickfix",
                                "diagnostics": [d],
                                "edit": {"changes": {uri: [{"range": r, "newText": "_" + name}]}}})
        return out

    # ------------------------------------------------------------ formatting
    def formatting(self, params):
        text = self.text(params["textDocument"]["uri"])
        new, problem = fmt.format_checked(self.V, text)
        if problem or new == text:
            return []
        n = len(text.splitlines())
        return [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": n + 1, "character": 0}},
                 "newText": new}]


class RenameError(Exception):
    pass


def _string_state(before):
    """Is the end of `before` inside a string (not in a {...} part) or a comment?"""
    in_str, depth, i = False, 0, 0
    while i < len(before):
        c = before[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == "{" and depth == 0:
                depth = 1
            elif c == "}" and depth:
                depth = 0
            elif c == '"' and not depth:
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "#":
            return "comment"
        i += 1
    if in_str and not depth:
        return "string"
    return "code"


def _open_call(before):
    """(column right after the called name, text of the arguments so far) for the innermost
    call still open at the end of `before`, or None."""
    depth, in_str = 0, False
    opens = []
    i = 0
    while i < len(before):
        c = before[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "#":
            break
        elif c in "([{":
            opens.append((c, i))
        elif c in ")]}":
            if opens:
                opens.pop()
        i += 1
    for c, idx in reversed(opens):
        if c != "(":
            continue
        j = idx
        while j > 0 and before[j - 1] == " ":
            j -= 1
        if j > 0 and (before[j - 1].isalnum() or before[j - 1] == "_"):
            return j, before[idx + 1:]
        return None
    return None


def _fuzzy(q, name):
    it = iter(name)
    return all(ch in it for ch in q)


def main(V, args):
    """vanta lsp   (speaks LSP on stdin/stdout)"""
    if "--help" in args:
        print(__doc__)
        return 0
    return Server(V).serve()
