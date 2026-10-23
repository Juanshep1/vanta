"""Friendly error reports: file, line, the source line with a caret, a "did you mean"
hint and the Vanta call stack.

    Oops! line 3: I don't know what 'totl' is yet
      --> shop.va:3
       |
     3 |     give back totl + tax
       |               ^^^^
       = hint: did you mean 'total'?
      call stack (most recent call last):
        shop.va line 7, at the top level
        shop.va line 3, in price

The first line goes to stdout exactly as before (programs and tests that read it keep
working); the rest goes to stderr."""

import difflib
import os
import re
import sys

UNDEFINED = [
    re.compile(r"I don't know what '([A-Za-z_]\w*)' is yet"),
    re.compile(r"I don't know a function called '([A-Za-z_]\w*)'"),
    re.compile(r"'([A-Za-z_]\w*)' doesn't exist yet"),
]
QUOTED = re.compile(r"(?<!\w)'([A-Za-z_][\w.]*)'")
DEF_PATTERNS = [
    re.compile(r"^\s*(?:let|fix)\s+([A-Za-z_][\w, ]*?)\s+be\b"),
    re.compile(r"^\s*to\s+([A-Za-z_]\w*)\s*(?:\(([^)]*)\)|with\s+(.*))?"),
    re.compile(r"^\s*type\s+([A-Za-z_]\w*)"),
    re.compile(r"^\s*has\s+([A-Za-z_]\w*)"),
    re.compile(r"^\s*for\s+each\s+([A-Za-z_][\w, ]*?)\s+in\b"),
    re.compile(r"\binto\s+([A-Za-z_]\w*)\s*$"),
    re.compile(r"^\s*rescue\s+([A-Za-z_]\w*)"),
    re.compile(r"^\s*enum\s+([A-Za-z_]\w*)"),
]
STATEMENT_WORDS = ["say", "let", "change", "if", "otherwise", "repeat", "while", "for", "to",
                   "give", "ask", "add", "import", "stop", "skip", "attempt", "rescue", "type",
                   "match", "when", "increase", "decrease", "fix", "end", "test", "expect", "has"]


def defined_names(source):
    """Every name a source file defines (variables, functions, parameters, types, fields)."""
    names = set()
    for line in source.splitlines():
        code = line.split("#", 1)[0]
        for pat in DEF_PATTERNS:
            m = pat.search(code)
            if not m:
                continue
            for group in m.groups():
                if not group:
                    continue
                for part in group.split(","):
                    word = part.strip().split(" be ")[0].strip()
                    if re.fullmatch(r"[A-Za-z_]\w*", word):
                        names.add(word)
    return names


# Words beginners use most: offered before the rest of the (large) builtin library.
COMMON_WORDS = [
    "yes", "no", "nothing", "length", "text", "number", "range", "say",
    "uppercase", "lowercase", "trim", "split", "join", "replace", "contains", "first", "last", "sum",
    "min", "max", "round", "abs", "sqrt", "random", "sort", "reverse", "keys", "values", "push", "pop",
    "map", "keep", "reduce", "each", "read_file", "write_file", "type_of", "fail", "assert", "print",
    "arguments", "now", "sleep", "get", "has_key", "unique", "index_of", "slice", "format_number",
]


def suggest(V, name, sources=()):
    """'did you mean ...?' candidates for a misspelled name, best first (at most two).
    The program's own names are tried first, then common words, then the rest of the
    builtins, so beginners aren't pointed at obscure library functions."""
    own = set(n for n in V.GLOBAL_ENV.vars if n not in ("pi", "e"))
    for src in sources:
        own |= defined_names(src)
    cutoff = 0.5 if len(name) <= 4 else 0.6
    tiers = [(own, cutoff), (set(w for w in COMMON_WORDS if w in V.BUILTINS or w in ("yes", "no", "nothing")), 0.6), (set(V.BUILTINS), 0.75)]
    for tier, cut in tiers:
        pool = sorted(p for p in tier if p != name and not p.startswith("__"))
        found = difflib.get_close_matches(name, pool, n=2, cutoff=cut)
        if found:
            ratio = lambda w: difflib.SequenceMatcher(None, name, w).ratio()
            if len(found) == 2 and ratio(found[1]) < ratio(found[0]) - 0.05:
                found = found[:1]               # only offer a second guess when it's as good
            return found
    return []


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, TypeError, UnicodeDecodeError):
        return None


def hint_for(V, msg, source_line, sources):
    """A friendly hint for an error message, or None."""
    for pat in UNDEFINED:
        m = pat.search(msg)
        if m:
            close = suggest(V, m.group(1), sources)
            if close:
                return "did you mean " + " or ".join(f"'{c}'" for c in close) + "?"
            if m.group(1)[:1].isupper():
                return f'if you meant the text {m.group(1)}, put it in quotes: "{m.group(1)}"'
            return f"create it first with: let {m.group(1)} be ..."
    if source_line is not None and ("confused" in msg or "missing a value" in msg):
        head = source_line.strip().split(" ", 1)[0]
        if head and head not in STATEMENT_WORDS:
            close = difflib.get_close_matches(head, STATEMENT_WORDS, n=1, cutoff=0.6)
            if close:
                return f"did you mean '{close[0]}'?"
    if "missing its 'end'" in msg:
        return "every if / repeat / while / for each / to / type / match / attempt / test block closes with 'end'"
    if "missing its closing quote" in msg:
        return 'close the text with another " on the same line (or use """ for text over several lines)'
    if "can only compare numbers with numbers" in msg:
        return "turn one side into the same kind first, e.g. number(x) or text(x)"
    if "can't add" in msg or "can only add" in msg:
        return "use text(x) to join a number onto text"
    return None


def caret_span(source_line, msg):
    """(start column, width) to underline in the source line."""
    stripped = source_line.lstrip()
    start = len(source_line) - len(stripped)
    for m in QUOTED.finditer(msg):
        word = m.group(1)
        mm = re.search(r"(?<![\w.])" + re.escape(word) + r"(?!\w)", source_line)
        if mm:
            return mm.start(), len(word)
    return start, max(1, len(stripped.split("#", 1)[0].rstrip()))


def rel(path):
    try:
        r = os.path.relpath(path)
        return r if not r.startswith("../../") else path
    except ValueError:
        return path


def report(V, e, main_path, out=None, err=None):
    """Print a VantaError the friendly way."""
    out = out or sys.stdout
    err = err or sys.stderr
    msg = str(e)
    print(f"Oops! {msg}", file=out)
    out.flush()
    main_path = os.path.abspath(main_path) if main_path else None
    frames = [list(f) for f in (getattr(e, "vtrace", None) or [])]
    for f in frames:
        if f[2] is None:
            f[2] = main_path
    m = re.match(r"line (\d+): (.*)", msg, re.S)
    line_no = int(m.group(1)) if m else (frames[0][0] if frames else None)
    body = m.group(2) if m else msg
    path = frames[0][2] if frames else main_path
    source = _read(path) if path else None
    sources = [s for s in {source, _read(main_path) if main_path else None} if s]
    lines = source.splitlines() if source else []
    src_line = lines[line_no - 1] if line_no and 0 < line_no <= len(lines) else None
    if path and line_no:
        print(f"  --> {rel(path)}:{line_no}", file=err)
    if src_line is not None:
        gutter = len(str(line_no))
        start, width = caret_span(src_line.expandtabs(4), body)
        print(f"  {' ' * gutter} |", file=err)
        print(f"  {line_no} | {src_line.expandtabs(4)}", file=err)
        print(f"  {' ' * gutter} | {' ' * start}{'^' * width}", file=err)
    hint = hint_for(V, body, src_line, sources)
    if hint:
        print(f"  = hint: {hint}", file=err)
    if len(frames) > 1:
        print("  call stack (most recent call last):", file=err)
        for ln, fn, fpath in reversed(frames):
            where = "at the top level" if fn is None else ("in module" if fn == "<module>" else f"in {fn}")
            print(f"    {rel(fpath) if fpath else '?'} line {ln}, {where}", file=err)
    err.flush()
