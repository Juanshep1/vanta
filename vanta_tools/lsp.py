"""`vanta lsp` — a Language Server Protocol server for Vanta (stdio, JSON-RPC 2.0).

Features: diagnostics (syntax errors, plus the type checker's findings when it is
available), completion (keywords, builtins, your own names), hover docs (builtins,
keywords, and your ## documented functions), go-to-definition (also into imported
files), document symbols (outline) and whole-document formatting (vanta fmt)."""

import json
import os
import re
import sys
from urllib.parse import unquote, urlparse

from . import builtin_docs, docgen, errors, fmt

DEF_RE = r"^\s*(?:to\s+{n}\b|type\s+{n}\b|kind\s+{n}\b|fix\s+{n}\s+be\b|let\s+(?:[\w\s,]*,\s*)?{n}\s*(?:,[\w\s,]*)?\s+be\b|has\s+{n}\s*$)"
SYMBOL_RE = re.compile(r"^(\s*)(to|type|kind|fix|test)\s+(\"[^\"]*\"|[A-Za-z_]\w*)")
WORD_RE = re.compile(r"[A-Za-z_]\w*")


def uri_to_path(uri):
    p = urlparse(uri)
    return unquote(p.path) if p.scheme == "file" else uri


def path_to_uri(path):
    from urllib.parse import quote
    return "file://" + quote(os.path.abspath(path))


class Server:
    def __init__(self, V, inp=None, out=None):
        self.V = V
        self.inp = inp or sys.stdin.buffer
        self.out = out or sys.stdout.buffer
        self.docs = {}
        self.running = True
        self.shutdown = False

    # ------------------------------------------------------------ transport
    def read_message(self):
        headers = {}
        while True:
            line = self.inp.readline()
            if not line:
                return None
            line = line.decode("ascii", "replace").strip()
            if not line:
                break
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        n = int(headers.get("content-length", 0))
        body = self.inp.read(n) if n else b""
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

    def handle(self, msg):
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method == "initialize":
            self.reply(mid, {
                "capabilities": {
                    "textDocumentSync": {"openClose": True, "change": 1, "save": {"includeText": True}},
                    "completionProvider": {"triggerCharacters": ["."]},
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "documentSymbolProvider": True,
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
            self.docs[d["uri"]] = d["text"]
            self.publish(d["uri"])
        elif method == "textDocument/didChange":
            uri = params["textDocument"]["uri"]
            changes = params.get("contentChanges") or []
            if changes:
                self.docs[uri] = changes[-1]["text"]
            self.publish(uri)
        elif method == "textDocument/didSave":
            uri = params["textDocument"]["uri"]
            if "text" in params:
                self.docs[uri] = params["text"]
            self.publish(uri)
        elif method == "textDocument/didClose":
            uri = params["textDocument"]["uri"]
            self.docs.pop(uri, None)
            self.notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": []})
        elif method == "textDocument/completion":
            self.reply(mid, self.completion(params))
        elif method == "textDocument/hover":
            self.reply(mid, self.hover(params))
        elif method == "textDocument/definition":
            self.reply(mid, self.definition(params))
        elif method == "textDocument/documentSymbol":
            self.reply(mid, self.symbols(params))
        elif method == "textDocument/formatting":
            self.reply(mid, self.formatting(params))
        elif mid is not None:
            self.reply(mid, error={"code": -32601, "message": f"method not found: {method}"})

    # ------------------------------------------------------------ features
    def text(self, uri):
        if uri in self.docs:
            return self.docs[uri]
        try:
            with open(uri_to_path(uri), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""

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
            start, width = errors.caret_span(src, body)
            d = {"range": {"start": {"line": ln, "character": start},
                           "end": {"line": ln, "character": start + width}},
                 "severity": 1, "source": "vanta", "message": body}
            hint = errors.hint_for(V, body, src, [text])
            if hint:
                d["message"] += f" ({hint})"
            out.append(d)
        except RecursionError:
            pass
        finally:
            V.CURRENT_FILE = None
        if not out:
            found = self.checker_findings(uri, text, lines)
            out += found if found is not None else self.unknown_calls(uri, text, lines)
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
                out.append({"range": {"start": {"line": i, "character": m.start(1)},
                                      "end": {"line": i, "character": m.end(1)}},
                            "severity": 2, "source": "vanta", "message": msg})
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
        out = []
        for item in found:
            if isinstance(item, dict):
                ln, msg = item.get("line", 1), item.get("message", "")
                sev = {"error": 1, "warning": 2, "info": 3}.get(item.get("severity", "error"), 1)
                col, width = item.get("column"), None
            else:
                ln, msg, sev, col, width = item[0], item[1], 1, None, None
            ln = max(0, min(int(ln or 1) - 1, len(lines) - 1))
            if col is None:
                col, width = errors.caret_span(lines[ln], msg)
            out.append({"range": {"start": {"line": ln, "character": col},
                                  "end": {"line": ln, "character": col + (width or 1)}},
                        "severity": sev, "source": "vanta check", "message": msg})
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

    def word_at(self, text, pos):
        lines = text.splitlines()
        if pos["line"] >= len(lines):
            return None, ""
        line = lines[pos["line"]]
        for m in WORD_RE.finditer(line):
            if m.start() <= pos["character"] <= m.end():
                return m.group(0), line
        return None, line

    def completion(self, params):
        V = self.V
        text = self.text(params["textDocument"]["uri"])
        items, seen = [], set()

        def add(label, kind, detail=None, doc=None):
            if label in seen or label.startswith("__"):
                return
            seen.add(label)
            item = {"label": label, "kind": kind}
            if detail:
                item["detail"] = detail
            if doc:
                item["documentation"] = {"kind": "markdown", "value": doc}
            items.append(item)

        for name in sorted(errors.defined_names(text)):
            add(name, 6)                                   # Variable
        for name in sorted(builtin_docs.KEYWORDS):
            add(name, 14, builtin_docs.KEYWORDS[name][0])  # Keyword
        for name in sorted(getattr(V, "RESERVED", ())):
            add(name, 14)
        for name in sorted(V.BUILTINS):
            d = builtin_docs.builtin_doc(name)
            add(name, 3, d[0] if d else f"{name}(...)", d[1] if d else None)   # Function
        for phrase in ("is at least", "is at most", "is not", "is over", "is under", "is in",
                       "is not in", "is a", "divided by", "give back", "for each", "otherwise if"):
            add(phrase, 14)
        return {"isIncomplete": False, "items": items}

    def hover(self, params):
        text = self.text(params["textDocument"]["uri"])
        word, _ = self.word_at(text, params["position"])
        if not word:
            return None
        # the user's own documented definitions first
        summary, items = docgen.extract(text)
        for it in items + [m for t in items for m in t.get("members", [])]:
            if it["name"] == word:
                body = f"```vanta\n{it['signature'] if it['kind'] != 'function' else 'to ' + it['signature']}\n```"
                if it["doc"]:
                    body += "\n" + it["doc"]
                return {"contents": {"kind": "markdown", "value": body}}
        md = builtin_docs.markdown(self.V, word)
        if md:
            return {"contents": {"kind": "markdown", "value": md}}
        return None

    def find_definition(self, word, text):
        pat = re.compile(DEF_RE.format(n=re.escape(word)))
        for i, line in enumerate(text.splitlines()):
            if pat.match(line):
                col = line.find(word)
                return i, max(col, 0)
        return None

    def imports(self, text, path):
        out = []
        for m in re.finditer(r'^\s*import\s+"([^"]+)"', text, re.M):
            try:
                out.append(os.path.abspath(self.V.resolve_import(m.group(1), os.path.dirname(path))))
            except Exception:
                pass
        return out

    def definition(self, params):
        uri = params["textDocument"]["uri"]
        text = self.text(uri)
        word, _ = self.word_at(text, params["position"])
        if not word:
            return None
        hit = self.find_definition(word, text)
        if hit:
            return {"uri": uri, "range": {"start": {"line": hit[0], "character": hit[1]},
                                          "end": {"line": hit[0], "character": hit[1] + len(word)}}}
        seen = set()
        todo = self.imports(text, uri_to_path(uri))
        while todo:
            p = todo.pop(0)
            if p in seen:
                continue
            seen.add(p)
            try:
                with open(p, encoding="utf-8") as f:
                    src = f.read()
            except OSError:
                continue
            hit = self.find_definition(word, src)
            if hit:
                return {"uri": path_to_uri(p), "range": {"start": {"line": hit[0], "character": hit[1]},
                                                         "end": {"line": hit[0], "character": hit[1] + len(word)}}}
            todo += self.imports(src, p)
        return None

    def symbols(self, params):
        text = self.text(params["textDocument"]["uri"])
        out = []
        kinds = {"to": 12, "type": 5, "kind": 10, "fix": 14, "test": 24}
        for i, line in enumerate(text.splitlines()):
            m = SYMBOL_RE.match(line)
            if m:
                name = m.group(3).strip('"')
                rng = {"start": {"line": i, "character": len(m.group(1))},
                       "end": {"line": i, "character": len(line)}}
                out.append({"name": name, "kind": kinds[m.group(2)], "range": rng, "selectionRange": rng,
                            "detail": m.group(2)})
        return out

    def formatting(self, params):
        text = self.text(params["textDocument"]["uri"])
        new, problem = fmt.format_checked(self.V, text)
        if problem or new == text:
            return []
        n = len(text.splitlines())
        return [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": n + 1, "character": 0}},
                 "newText": new}]


def main(V, args):
    """vanta lsp   (speaks LSP on stdin/stdout)"""
    if "--help" in args:
        print(__doc__)
        return 0
    return Server(V).serve()
