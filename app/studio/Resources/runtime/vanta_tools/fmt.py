"""`vanta fmt` — the standard layout for Vanta code.

Rules: 4-space indentation from the block structure (`when` lines sit one level inside
their `match`), one space around operators and after commas, none inside brackets or
before a call's `(`, `{key: value}` maps, `[a:b]` slices, comments kept (an inline
comment keeps at least two spaces before its #), at most one blank line in a row, one
blank line around top-level functions/types/tests, no trailing spaces, one final newline.

Formatting is idempotent, and every result is checked: the formatted program must
parse to exactly the same program as the original, otherwise the file is left alone.
"""

import difflib
import glob
import os
import sys

INDENT = "    "
TOP_BLOCKS = ("to", "type", "test", "kind")
WORD_OPS = {"plus", "minus", "times", "divided", "by", "xor", "over", "under", "above", "below",
            "least", "most", "than", "greater", "bigger", "more", "less", "smaller", "give", "make",
            "back", "yield", "fails", "with"}


ALWAYS_OPEN = {"if", "repeat", "while", "for", "to", "attempt", "type", "match"}
_OPENER_CACHE = {}


def opens_block(V, text, head):
    """Does this line start a block that closes with `end`? The classic block words
    always do; for anything else (`test "..."`, `kind Direction`, newer statements) ask
    the parser: a line that opens a block can't be parsed without its `end`."""
    if head in ALWAYS_OPEN:
        return True
    if head in ("end", "say", "let", "change", "fix", "give", "add", "import", "ask", "stop",
                "skip", "increase", "decrease", "has", "note", "expect") or not head.isidentifier():
        return False
    key = text
    if key not in _OPENER_CACHE:
        result = False
        try:
            V.parse_program([(1, text)], keep_tests=True)
        except V.VantaError as e:
            msg = str(e)
            result = "missing its 'end'" in msg or "missing its end" in msg
        except Exception:
            result = False
        _OPENER_CACHE[key] = result
    return _OPENER_CACHE[key]


def mid_words(V):
    words = set(getattr(V, "BLOCK_TERMINATORS", ())) | {"otherwise", "rescue", "when"}
    return words - {"end", "when"}


def keywords(V):
    return set(getattr(V, "RESERVED", ())) | WORD_OPS


# ---------------------------------------------------------------- tokenizing

def scan(code):
    """Split one line into tokens: (kind, text). Kinds: str, comment, num, name, op,
    open, close, comma, colon, dot, triple (an unclosed triple-quoted string: rest of line)."""
    toks, i, n = [], 0, len(code)
    spaced = set()                    # indices of tokens that had whitespace before them
    scan.spaced = spaced
    while i < n:
        c = code[i]
        if c in " \t":
            i += 1
            spaced.add(len(toks))
            continue
        if c == "#":
            toks.append(("comment", code[i:]))
            break
        if c == '"':
            if code.startswith('"""', i):
                j = code.find('"""', i + 3)
                if j == -1:
                    toks.append(("triple", code[i:]))
                    break
                toks.append(("str", code[i:j + 3]))
                i = j + 3
                continue
            j = i + 1
            while j < n and code[j] != '"':
                j += 2 if code[j] == "\\" else 1
            toks.append(("str", code[i:j + 1]))
            i = j + 1
            continue
        if c.isdigit():
            j = i
            if code.startswith(("0x", "0X", "0b", "0B", "0o", "0O"), i):
                j = i + 2
                while j < n and (code[j].isalnum() or code[j] == "_"):
                    j += 1
            else:
                while j < n and (code[j].isdigit() or code[j] == "_" or
                                 (code[j] == "." and j + 1 < n and code[j + 1].isdigit() and "." not in code[i:j])):
                    j += 1
            toks.append(("num", code[i:j]))
            i = j
            continue
        if c.isalpha() or c == "_":
            j = i
            while j < n and (code[j].isalnum() or code[j] == "_"):
                j += 1
            toks.append(("name", code[i:j]))
            i = j
            continue
        two = code[i:i + 2]
        if two in (">=", "<=", "==", "!=", "<<", ">>", "->", "**", "//", "+=", "-="):
            toks.append(("op", two))
            i += 2
            continue
        if c in "([{":
            toks.append(("open", c))
        elif c in ")]}":
            toks.append(("close", c))
        elif c == ",":
            toks.append(("comma", c))
        elif c == ":":
            toks.append(("colon", c))
        elif c == ".":
            toks.append(("dot", c))
        else:
            toks.append(("op", c))
        i += 1
    return toks


def render(toks, kw, gaps=None, spaced=frozenset()):
    """Join a line's tokens with the standard spacing. `spaced` holds the indices of
    tokens the author put a space before (used where both styles are fine)."""
    out = []
    stack = []                        # open brackets
    prev = None                       # previous token
    prev_unary = False
    for idx, (kind, text) in enumerate(toks):
        if kind == "comment":
            if out:
                gap = max(2, gaps.get(idx, 2) if gaps else 2)
                out.append(" " * gap)
            out.append(text)
            break
        space = prev is not None
        if prev is not None:
            pk, pt = prev
            if pk == "open" or pk == "dot" or prev_unary:
                space = False
            elif kind in ("close", "comma", "dot"):
                space = False
            elif kind == "colon":
                space = False
            elif pk == "colon":
                space = not (stack and stack[-1] == "[")
            elif kind == "open" and text in "([":
                # a call or an index: name(...), xs[0], f(x)(y), xs[0][1]. After a
                # keyword (say (1 + 2), in [1, 2]) the author's choice is kept.
                if pk == "close" or pk == "str":
                    space = False
                elif pk == "name":
                    space = pt in kw and idx in spaced
        if kind == "colon" and stack and stack[-1] == "[":
            space = False
        unary = False
        if kind == "op" and text in ("-", "~", "+"):
            if prev is None or prev[0] in ("op", "open", "comma", "colon") or \
                    (prev[0] == "name" and prev[1] in kw):
                unary = True
        if space:
            out.append(" ")
        out.append(text)
        if kind == "open":
            stack.append(text)
        elif kind == "close" and stack:
            stack.pop()
        prev = (kind, text)
        prev_unary = unary
    return "".join(out)


def comment_gaps(line):
    """For an inline comment: how many spaces the author put before the #."""
    toks = scan(line)
    gaps = {}
    for idx, (kind, text) in enumerate(toks):
        if kind == "comment" and idx > 0:
            pos = line.rfind(text)
            j = pos
            while j > 0 and line[j - 1] in " \t":
                j -= 1
            gaps[idx] = pos - j
    return gaps


# ---------------------------------------------------------------- layout

def first_word(text):
    return text.split(None, 1)[0] if text.split() else ""


def format_source(V, source, spacing=True):
    """Return the formatted source text."""
    kw = keywords(V)
    mids = mid_words(V)
    lines = source.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []                          # (indent level or None for verbatim, text, top_block_marker)
    stack = []
    in_triple = False
    for raw in lines:
        if in_triple:
            out.append((None, raw.rstrip("\n"), None))
            if raw.count('"""') % 2 == 1:
                in_triple = False
            continue
        text = raw.strip()
        if not text:
            out.append((0, "", None))
            continue
        toks = scan(text)
        spaced = scan.spaced
        head = first_word(text)
        if toks and toks[0][0] == "name":
            head = toks[0][1]
        if any(k == "triple" for k, _ in toks):
            in_triple = True
        if spacing and not text.startswith("#") and head != "note" and not in_triple:
            gaps = comment_gaps(text)
            body = render(toks, kw, gaps, spaced)
        else:
            body = text
        level = len(stack)
        marker = None
        if head == "end" and stack:
            top = stack.pop()
            if top == "when" and stack:
                stack.pop()               # end of the last when + the match
            level = len(stack)
            if not stack and top in TOP_BLOCKS:
                marker = "close"
        elif head in mids and stack:
            if stack[-1] == "when":
                level = len(stack) - 1
            else:
                level = len(stack) - 1
        elif head == "when" and stack and stack[-1] in ("when", "match"):
            if stack[-1] == "when":
                stack.pop()
            level = len(stack)
            stack.append("when")
        elif not text.startswith("#") and opens_block(V, text, head):
            if not stack and head in TOP_BLOCKS:
                marker = "open"
            stack.append(head)
        out.append((level, body, marker))
    # blank lines: collapse runs, one blank line around top-level definitions
    result = []
    for i, (level, body, marker) in enumerate(out):
        if level is None:
            result.append(body)
            continue
        if body == "":
            if result and result[-1] != "":
                result.append("")
            continue
        if marker == "open":
            # put a blank line before the definition (and before its attached comments)
            j = len(result)
            while j > 0 and result[j - 1].startswith("#"):
                j -= 1
            if j > 0 and result[j - 1] != "":
                result.insert(j, "")
        if result and result[-1] == "__BLANK_AFTER__":
            result[-1] = ""
        result.append(INDENT * level + body)
        if marker == "close":
            result.append("__BLANK_AFTER__")
    while result and result[-1] in ("", "__BLANK_AFTER__"):
        result.pop()
    while result and result[0] == "":
        result.pop(0)
    result = [("" if r == "__BLANK_AFTER__" else r) for r in result]
    # a __BLANK_AFTER__ followed by a real blank becomes two blanks: collapse again
    final = []
    for r in result:
        if r == "" and final and final[-1] == "":
            continue
        final.append(r)
    return "\n".join(final) + "\n" if final else ""


# ---------------------------------------------------------------- safety check

def _canon(node, V):
    if isinstance(node, tuple):
        return tuple(_canon(x, V) for x in node)
    if isinstance(node, list):
        return [_canon(x, V) for x in node]
    if isinstance(node, dict):
        return {k: _canon(v, V) for k, v in node.items()}
    if isinstance(node, V.Function):
        return ("Function", node.name, _canon(node.params, V), _canon(node.body, V))
    return node


def _numbered(V, src):
    """The program's lines renumbered 1, 2, 3... so moving blank lines doesn't count as a change."""
    return [(i, text) for i, (_, text) in enumerate(V.load_lines(src), start=1)]


def same_program(V, a, b):
    try:
        pa = V.parse_program(_numbered(V, a), keep_tests=True)
        pb = V.parse_program(_numbered(V, b), keep_tests=True)
    except V.VantaError:
        return False
    return _canon(pa, V) == _canon(pb, V)


def format_checked(V, source):
    """Format, proving the program is unchanged. Returns (new_source, problem_or_None)."""
    try:
        V.parse_program(V.load_lines(source), keep_tests=True)
    except V.VantaError as e:
        return source, f"has an error, not formatted: {e}"
    new = format_source(V, source, spacing=True)
    if same_program(V, source, new):
        return new, None
    new = format_source(V, source, spacing=False)
    if same_program(V, source, new):
        return new, None
    return source, "could not be formatted safely (left unchanged)"


def collect(targets):
    if not targets:
        targets = ["."]
    files = []
    for t in targets:
        if os.path.isdir(t):
            for p in sorted(glob.glob(os.path.join(t, "**", "*.va"), recursive=True)):
                norm = p.replace(os.sep, "/")
                if "/packages/" in norm or "/node_modules/" in norm or "/." in norm:
                    continue
                files.append(p)
        else:
            files.append(t)
    return files


def main(V, args):
    """vanta fmt [--check] [--diff] [files or folders]  (- formats stdin to stdout)"""
    check = "--check" in args
    show_diff = "--diff" in args
    targets = [a for a in args if a not in ("--check", "--diff")]
    if targets == ["-"]:
        src = sys.stdin.read()
        new, problem = format_checked(V, src)
        sys.stdout.write(new)
        if problem:
            print(f"Oops! stdin {problem}", file=sys.stderr)
            return 1
        return 0
    files = collect(targets)
    changed, problems = [], 0
    for path in files:
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        except OSError as e:
            print(f"Oops! could not open {path}: {e.strerror or e}")
            problems += 1
            continue
        new, problem = format_checked(V, src)
        if problem:
            print(f"{path}: {problem}")
            problems += 1
            continue
        if new == src:
            continue
        changed.append(path)
        if show_diff:
            sys.stdout.writelines(difflib.unified_diff(src.splitlines(True), new.splitlines(True),
                                                       path, path + " (formatted)"))
        elif check:
            print(f"would reformat {path}")
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            print(f"formatted {path}")
    if check or show_diff:
        n = len(changed)
        print(f"{n} file{'s' if n != 1 else ''} would be reformatted, "
              f"{len(files) - n - problems} already formatted" + (f", {problems} with problems" if problems else ""))
        return 1 if (changed or problems) else 0
    if not changed and not problems:
        print(f"{len(files)} file{'s' if len(files) != 1 else ''} already formatted")
    return 1 if problems else 0
