"""Docs for builtins and keywords (REPL :doc, language-server hover and completion).

Builtin docs are read from the reference pages in docs/ (STDLIB.md, GRAPHICS.md, ...):
every `### \\`name(args)\\`` heading followed by its description and example."""

import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CACHE = {}

KEYWORDS = {
    "say": ("say VALUE", "Prints a value on its own line."),
    "let": ("let NAME be VALUE", "Creates a variable. `let a, b be 1, 2` makes several at once."),
    "change": ("change NAME to VALUE", "Updates a variable that already exists (also `change xs at 0 to 5`, `change p.name to \"x\"`)."),
    "fix": ("fix NAME be VALUE", "Creates a constant: changing it later is an error."),
    "if": ("if CONDITION ... otherwise if ... otherwise ... end", "Runs a block only when the condition is yes."),
    "otherwise": ("otherwise / otherwise if CONDITION", "The 'else' part of an if, or the fallback of a match."),
    "repeat": ("repeat N times ... end", "Runs a block a fixed number of times."),
    "while": ("while CONDITION ... end", "Runs a block again and again while the condition is yes."),
    "for": ("for each NAME in LIST ... end", "Runs a block once for every item (two names for key, value)."),
    "each": ("for each NAME in LIST", "Part of a for-each loop or a comprehension."),
    "to": ("to NAME(PARAMS) ... end", "Defines a function. Parameters can have defaults: `to greet(who, greeting be \"Hi\")`."),
    "give": ("give back VALUE", "Returns a value from a function."),
    "ask": ("ask \"QUESTION\" into NAME", "Asks the user and stores the answer (numbers become numbers)."),
    "add": ("add VALUE to LIST", "Appends a value to a list."),
    "import": ("import \"MODULE\"", "Runs another file's definitions into your program (lib/, packages/ and paths)."),
    "stop": ("stop", "Leaves the loop it's in."),
    "skip": ("skip", "Jumps to the next round of the loop."),
    "attempt": ("attempt ... rescue NAME ... end", "Runs a block; if it fails, runs the rescue part with the error message in NAME."),
    "rescue": ("rescue NAME", "The part of an attempt that runs when something failed."),
    "type": ("type NAME [from PARENT] ... end", "Defines your own type with `has` fields and `to` methods."),
    "has": ("has FIELD", "Declares a field inside a type."),
    "new": ("new TYPE(VALUES)", "Builds an object of a type (the same as calling TYPE(VALUES))."),
    "me": ("me", "Inside a method: the object the method was called on."),
    "super": ("super.METHOD()", "Inside a method: the parent type's version of a method."),
    "match": ("match VALUE ... when X ... otherwise ... end", "Picks the first `when` that equals the value."),
    "when": ("when VALUE[, VALUE...]", "One case of a match."),
    "increase": ("increase NAME by AMOUNT", "Adds to a number variable."),
    "decrease": ("decrease NAME by AMOUNT", "Subtracts from a number variable."),
    "make": ("make PARAMS give VALUE", "An anonymous function: `make x give x * 2`."),
    "test": ("test \"WHAT IT CHECKS\" ... end", "A test block, run by `vanta test` and skipped by `vanta run`."),
    "expect": ("expect A is B / is not / contains / fails [with TEXT]", "Checks a value inside a test; a failure shows both values."),
    "end": ("end", "Closes a block."),
    "is": ("A is B", "Equal to. Also: is not, is over, is under, is at least, is at most, is in, is a."),
    "and": ("A and B", "Yes when both are yes."),
    "or": ("A or B", "Yes when either is yes."),
    "not": ("not A", "The opposite yes/no."),
    "yes": ("yes", "The true value (also `true`)."),
    "no": ("no", "The false value (also `false`)."),
    "nothing": ("nothing", "The empty value."),
    "note": ("note TEXT", "A comment line (like #)."),
    "plus": ("A plus B", "Addition (+)."),
    "minus": ("A minus B", "Subtraction (-)."),
    "times": ("A times B / repeat N times", "Multiplication (*)."),
}


def _load():
    if "builtins" in _CACHE:
        return _CACHE["builtins"]
    docs = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "docs", "*.md"))):
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        i = 0
        while i < len(lines):
            m = re.match(r"^###\s+`([A-Za-z_]\w*)\s*(\(.*?\))?`", lines[i])
            if not m:
                i += 1
                continue
            name, sig = m.group(1), m.group(1) + (m.group(2) or "")
            body, example = [], None
            i += 1
            while i < len(lines) and not lines[i].startswith("#"):
                line = lines[i].strip()
                if line.startswith("`") and line.endswith("`") and example is None and body:
                    example = line.strip("`")
                elif line and not line.startswith("```"):
                    body.append(line)
                i += 1
            if name not in docs:
                docs[name] = (sig, " ".join(body), example)
    _CACHE["builtins"] = docs
    return docs


def builtin_doc(name):
    """(signature, description, example or None) for a builtin, or None."""
    return _load().get(name)


def describe(V, name):
    """A short plain-text description of a builtin or keyword."""
    d = builtin_doc(name)
    if d:
        sig, desc, ex = d
        return f"{sig}\n  {desc}" + (f"\n  example: {ex}" if ex else "")
    if name in KEYWORDS:
        sig, desc = KEYWORDS[name]
        return f"{sig}\n  {desc}"
    if V is not None and name in getattr(V, "BUILTINS", {}):
        return f"{name}(...)\n  a builtin function (no reference entry yet)"
    return None


def markdown(V, name):
    """Hover text (Markdown) for a builtin or keyword, or None."""
    d = builtin_doc(name)
    if d:
        sig, desc, ex = d
        out = f"```vanta\n{sig}\n```\n{desc}"
        if ex:
            out += f"\n\n```vanta\n{ex}\n```"
        return out
    if name in KEYWORDS:
        sig, desc = KEYWORDS[name]
        return f"```vanta\n{sig}\n```\n{desc}"
    if V is not None and name in getattr(V, "BUILTINS", {}):
        return f"```vanta\n{name}(...)\n```\nA builtin function."
    return None
