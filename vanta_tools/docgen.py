"""`vanta doc` — documentation from ## comments.

    ## Helpers for a shopping cart.          <- a ## block at the top: the file's summary

    ## The total price, with tax.            <- a ## block right above a definition
    to total(items, rate be 0.2)
        ...
    end

Documents functions (`to`), types (`type`, with their fields and methods), kinds
(`kind`) and fixed values (`fix`). Output is Markdown, or HTML with --html."""

import html
import os
import re
import sys

DEF = re.compile(r"^(to|type|kind|fix)\s+(.*)$")


def _doc_text(block):
    """Join ## comment lines: a blank ## line starts a new paragraph."""
    paras, cur = [], []
    for line in block:
        body = line[2:]
        if body.startswith(" "):
            body = body[1:]
        if not body.strip():
            if cur:
                paras.append(cur)
                cur = []
        else:
            cur.append(body.rstrip())
    if cur:
        paras.append(cur)
    out = []
    for p in paras:
        if all(l.startswith(("- ", "* ", "    ")) for l in p) or any(l.startswith("    ") for l in p):
            out.append("\n".join(p))
        else:
            out.append(" ".join(l.strip() for l in p))
    return "\n\n".join(out)


def extract(source):
    """Pull the documented items out of a source file.
    Returns (file_summary, items); each item is a dict: kind, name, signature, doc, members."""
    lines = source.splitlines()
    items, summary = [], ""
    pending, i = [], 0
    stack = []                         # the type a method belongs to
    first_code_seen = False
    while i < len(lines):
        raw = lines[i]
        text = raw.strip()
        if text.startswith("##"):
            pending.append(text)
            i += 1
            continue
        if not text:
            if pending and not first_code_seen and not summary and not items:
                summary = _doc_text(pending)       # top-of-file block followed by a blank line
                pending = []
            i += 1
            continue
        if text.startswith("#"):
            i += 1
            continue
        first_code_seen = True
        m = DEF.match(text)
        if m:
            word, rest = m.group(1), m.group(2).split("#", 1)[0].strip()
            doc = _doc_text(pending)
            indent = len(raw) - len(raw.lstrip())
            if word == "to":
                name = re.match(r"[A-Za-z_]\w*", rest)
                name = name.group(0) if name else rest
                sig = rest if "(" in rest else (name + "(" + ", ".join(
                    p.strip() for p in rest.partition(" with ")[2].split(",") if p.strip()) + ")")
                entry = {"kind": "method" if stack and indent > stack[-1][1] else "function",
                         "name": name, "signature": sig, "doc": doc, "members": [], "line": i + 1}
                if entry["kind"] == "method":
                    stack[-1][0]["members"].append(entry)
                elif indent == 0 and not name.startswith("_"):    # _name: private, not listed
                    items.append(entry)
            elif word == "type":
                name = rest.split()[0] if rest else "?"
                parent = rest.partition(" from ")[2].strip()
                entry = {"kind": "type", "name": name, "signature": f"type {rest}", "doc": doc,
                         "members": [], "fields": [], "parent": parent, "line": i + 1}
                items.append(entry)
                stack.append((entry, indent))
            elif word == "kind":
                name = rest.split()[0] if rest else "?"
                values = rest.partition(" is ")[2]
                entry = {"kind": "kind", "name": name, "signature": f"kind {rest}", "doc": doc,
                         "members": [], "values": [v.strip() for v in values.split(",") if v.strip()],
                         "line": i + 1}
                if not values:                         # block form: values on the following lines
                    j = i + 1
                    while j < len(lines) and lines[j].strip() != "end":
                        entry["values"] += [v.strip() for v in lines[j].split("#")[0].split(",") if v.strip()]
                        j += 1
                items.append(entry)
            elif word == "fix" and indent == 0 and doc:
                name = rest.partition(" be ")[0].strip()
                items.append({"kind": "constant", "name": name, "signature": f"fix {rest}", "doc": doc,
                              "members": [], "line": i + 1})
        elif text.startswith("has ") and stack:
            stack[-1][0]["fields"].append((text[4:].split("#")[0].strip(), _doc_text(pending)))
        elif text == "end" and stack:
            indent = len(raw) - len(raw.lstrip())
            if indent <= stack[-1][1]:
                stack.pop()
        pending = []
        i += 1
    return summary, items


def to_markdown(path, summary, items):
    title = os.path.basename(path)
    out = [f"# {title}", ""]
    if summary:
        out += [summary, ""]
    groups = [("Functions", "function"), ("Types", "type"), ("Kinds", "kind"), ("Constants", "constant")]
    for heading, kind in groups:
        group = [it for it in items if it["kind"] == kind]
        if not group:
            continue
        out += [f"## {heading}", ""]
        for it in group:
            out += [f"### `{it['signature'] if kind != 'function' else it['signature']}`", ""]
            if it["doc"]:
                out += [it["doc"], ""]
            if kind == "type":
                if it.get("parent"):
                    out += [f"Inherits from `{it['parent']}`.", ""]
                if it["fields"]:
                    out += ["**Fields**", ""]
                    out += [f"- `{f}`" + (f" — {d}" if d else "") for f, d in it["fields"]] + [""]
                if it["members"]:
                    out += ["**Methods**", ""]
                    for m in it["members"]:
                        out += [f"- `{m['signature']}`" + (f" — {m['doc']}" if m["doc"] else "")]
                    out += [""]
            if kind == "kind" and it.get("values"):
                out += ["Values: " + ", ".join(f"`{v}`" for v in it["values"]), ""]
    if not items:
        out += ["*(nothing documented yet — add `##` comments above functions and types)*", ""]
    return "\n".join(out).rstrip() + "\n"


def _inline_md(text):
    t = html.escape(text)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    return t


def to_html(path, markdown):
    """A small, dependency-free Markdown → HTML for the subset to_markdown writes."""
    body, in_list = [], False
    for line in markdown.splitlines():
        if line.startswith("- "):
            if not in_list:
                body.append("<ul>")
                in_list = True
            body.append(f"<li>{_inline_md(line[2:])}</li>")
            continue
        if in_list:
            body.append("</ul>")
            in_list = False
        if line.startswith("### "):
            body.append(f"<h3>{_inline_md(line[4:])}</h3>")
        elif line.startswith("## "):
            body.append(f"<h2>{_inline_md(line[3:])}</h2>")
        elif line.startswith("# "):
            body.append(f"<h1>{_inline_md(line[2:])}</h1>")
        elif line.strip():
            body.append(f"<p>{_inline_md(line)}</p>")
    if in_list:
        body.append("</ul>")
    title = html.escape(os.path.basename(path))
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — Vanta docs</title>
<style>
:root {{ --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --code: #f2f2f5; --accent: #5b3cc4; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #141416; --fg: #ececf0; --muted: #a0a0a8; --code: #24242a; --accent: #a58cff; }} }}
body {{ background: var(--bg); color: var(--fg); font: 16px/1.6 -apple-system, system-ui, sans-serif;
       max-width: 760px; margin: 0 auto; padding: 24px 16px; }}
h1 {{ font-size: 1.8em; margin-bottom: .2em; }} h2 {{ margin-top: 2em; border-bottom: 1px solid var(--code); }}
h3 code {{ font-size: 1em; color: var(--accent); }}
code {{ background: var(--code); padding: 1px 5px; border-radius: 4px; font: .92em ui-monospace, Menlo, monospace; }}
</style></head><body>
{chr(10).join(body)}
</body></html>
"""


def main(V, args):
    """vanta doc FILE [--html] [-o OUT]"""
    as_html, out_path, files = False, None, []
    i = 0
    while i < len(args):
        if args[i] == "--html":
            as_html = True
        elif args[i] == "-o" and i + 1 < len(args):
            out_path = args[i + 1]
            i += 1
        else:
            files.append(args[i])
        i += 1
    if not files:
        print("Usage: vanta doc FILE [--html] [-o OUT]")
        return 1
    chunks = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        except OSError as e:
            print(f"Oops! could not open {path}: {e.strerror or e}")
            return 1
        summary, items = extract(src)
        chunks.append(to_markdown(path, summary, items))
    md = "\n".join(chunks)
    if out_path and out_path.endswith((".html", ".htm")):
        as_html = True
    text = to_html(files[0], md) if as_html else md
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {out_path}")
    else:
        sys.stdout.write(text)
    return 0
