#!/usr/bin/env python3
"""
Vanta - a real, plain-English programming language.

Vanta reads like English but is a genuine general-purpose language. It has
variables, arithmetic, the full set of control flow, functions with default
arguments and recursion, first-class and higher-order functions, user-defined
types with methods, error handling, lists and maps, string interpolation,
modules, file and system access, and a sizeable standard library.

The whole language is this one file, built in the three classic stages:

  1. TOKENIZE  - chop text into little pieces (words, numbers, symbols)
  2. PARSE     - turn those pieces into a structure (an "abstract syntax tree")
  3. RUN       - walk that structure and actually do what it says

Run a file:   python3 vanta.py program.va
Start REPL:   python3 vanta.py
"""

import sys
import os
import re
import shutil
import json
import time
import math
import subprocess
import random
import io
import base64
import hashlib
import contextlib
import ctypes
import struct as _struct
import threading as _threading

VERSION = "6.0"

# Command-line arguments passed to a Vanta program (after the script name).
PROGRAM_ARGS = []


class VantaError(Exception):
    """A friendly error in a Vanta program."""


# ===========================================================================
# STAGE 1 - TOKENIZER
# ===========================================================================

# English phrases that mean the same as a symbol.
PHRASES = {
    ("is", "at", "least"): ">=",
    ("is", "at", "most"): "<=",
    ("is", "greater", "than"): ">",
    ("is", "bigger", "than"): ">",
    ("is", "more", "than"): ">",
    ("is", "less", "than"): "<",
    ("is", "smaller", "than"): "<",
    ("is", "not", "in"): "notin",
    ("is", "not"): "!=",
    ("is", "a"): "isa",
    ("is", "an"): "isa",
    ("is", "in"): "in",
    ("is", "over"): ">",
    ("is", "above"): ">",
    ("is", "under"): "<",
    ("is", "below"): "<",
    ("divided", "by"): "/",
    ("is",): "==",
    ("plus",): "+",
    ("minus",): "-",
    ("times",): "*",
    ("xor",): "xor",
    ("mod",): "%",
}

COMPARE_OPS = {">", "<", ">=", "<=", "==", "!="}


def tokenize(text):
    """Turn a line of source into a list of (kind, value) tokens."""
    tokens = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]

        if c in " \t":
            i += 1
            continue

        if c == "#":            # rest of the line is a comment
            break

        if c == '"':
            j = i + 1
            chars = []
            escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    # \n \t \r \" \\ are escapes; any other backslash stays as written ("\d" is \d)
                    chars.append(escapes.get(text[j + 1], "\\" + text[j + 1]))
                    j += 2
                else:
                    chars.append(text[j])
                    j += 1
            if j >= n:
                raise VantaError('a text value is missing its closing quote (")')
            tokens.append(("STR", "".join(chars)))
            i = j + 1
            continue

        if c == "0" and i + 1 < n and text[i + 1] in "xXbBoO":      # 0xFF, 0b1010, 0o17
            base = {"x": 16, "b": 2, "o": 8}[text[i + 1].lower()]
            j = i + 2
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            digits = text[i + 2:j].replace("_", "")
            try:
                tokens.append(("NUM", int(digits, base)))
            except ValueError:
                raise VantaError(f"{text[i:j]} is not a valid number")
            i = j
            continue

        if c.isdigit():
            j, dot = i, False
            while j < n and (text[j].isdigit() or text[j] == "_" or (text[j] == "." and not dot and j + 1 < n and text[j + 1].isdigit())):
                dot = dot or text[j] == "."
                j += 1
            if j < n and text[j] in "eE" and j + 1 < n and (text[j + 1].isdigit() or
                                                           (text[j + 1] in "+-" and j + 2 < n and text[j + 2].isdigit())):
                j += 2                                   # an exponent: 1e3, 2.5e-4
                while j < n and text[j].isdigit():
                    j += 1
                dot = True
            chunk = text[i:j].replace("_", "")
            tokens.append(("NUM", float(chunk) if dot else int(chunk)))
            i = j
            continue

        if c.isalpha() or c == "_":
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            tokens.append(("NAME", text[i:j]))
            i = j
            continue

        two = text[i:i + 2]
        if two in (">=", "<=", "==", "!=", "<<", ">>", "//"):
            tokens.append(("OP", two))
            i += 2
            continue
        if c in "+-*/%><^&|~":
            tokens.append(("OP", c))
            i += 1
            continue
        if c == "=":
            tokens.append(("OP", "=="))
            i += 1
            continue
        simple = {"(": "LP", ")": "RP", "[": "LB", "]": "RB", "{": "LC",
                  "}": "RC", ",": "COMMA", ":": "COLON", ".": "DOT"}
        if c in simple:
            tokens.append((simple[c], c))
            i += 1
            continue

        raise VantaError(f"I don't understand the symbol: {c}")

    return combine_word_operators(tokens)


def combine_word_operators(tokens):
    """Fold word-phrases like ['is','at','least'] into a single OP token."""
    out, i = [], 0
    while i < len(tokens):
        if tokens[i][0] == "NAME":
            words, k = [], i
            while k < len(tokens) and tokens[k][0] == "NAME" and len(words) < 3:
                words.append(tokens[k][1].lower())
                k += 1
            matched = False
            for size in (3, 2, 1):
                phrase = tuple(words[:size])
                if len(phrase) == size and phrase in PHRASES:
                    out.append(("OP", PHRASES[phrase]))
                    i += size
                    matched = True
                    break
            if matched:
                continue
        out.append(tokens[i])
        i += 1
    return out


# ===========================================================================
# STAGE 2 - EXPRESSION PARSER  (text -> tree)
# ===========================================================================
#
# Precedence, lowest to highest:
#   or -> and -> not -> comparison -> + - -> * / % -> unary - / new -> ^
#   -> call() / index[] / .attr -> primary

class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def at_end(self):
        return self.pos >= len(self.tokens)

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else ("END", None)

    def take(self):
        tok = self.peek()
        self.pos += 1
        return tok

    def is_word(self, word):
        k, v = self.peek()
        return k == "NAME" and v.lower() == word

    def parse_expression(self):
        node = self.parse_or()
        if self.is_word("if"):                 # inline conditional: A if COND otherwise B
            self.take()
            cond = self.parse_or()
            if not self.is_word("otherwise"):
                raise VantaError("an inline 'if' needs an 'otherwise' value")
            self.take()
            return ("ternary", cond, node, self.parse_expression())
        return node

    def parse_or(self):
        node = self.parse_and()
        while self.is_word("or"):
            self.take()
            node = ("or", node, self.parse_and())
        return node

    def parse_and(self):
        node = self.parse_not()
        while self.is_word("and"):
            self.take()
            node = ("and", node, self.parse_not())
        return node

    def parse_not(self):
        if self.is_word("not"):
            self.take()
            return ("not", self.parse_not())
        return self.parse_comparison()

    def parse_comparison(self):
        left = self.parse_bitor()
        k, v = self.peek()
        if k == "OP" and v == "isa":
            self.take()
            return ("isa", left, self.parse_bitor())
        if k == "OP" and v in ("in", "notin"):
            self.take()
            return (v, left, self.parse_bitor())
        if k == "OP" and v in COMPARE_OPS:
            self.take()
            right = self.parse_bitor()
            node = ("cmp", v, left, right)
            while self.peek()[0] == "OP" and self.peek()[1] in COMPARE_OPS:   # 1 is under x is under 10
                op2 = self.take()[1]
                right2 = self.parse_bitor()
                node = ("and", node, ("cmp", op2, right, right2))
                right = right2
            return node
        return left

    # Bitwise operators, loosest to tightest:  |  then  xor  then  &  then  << >>
    def parse_bitor(self):
        node = self.parse_bitxor()
        while self.peek() == ("OP", "|"):
            self.take()
            node = ("arith", "|", node, self.parse_bitxor())
        return node

    def parse_bitxor(self):
        node = self.parse_bitand()
        while self.peek() == ("OP", "xor"):
            self.take()
            node = ("arith", "xor", node, self.parse_bitand())
        return node

    def parse_bitand(self):
        node = self.parse_shift()
        while self.peek() == ("OP", "&"):
            self.take()
            node = ("arith", "&", node, self.parse_shift())
        return node

    def parse_shift(self):
        node = self.parse_add_sub()
        while self.peek()[0] == "OP" and self.peek()[1] in ("<<", ">>"):
            op = self.take()[1]
            node = ("arith", op, node, self.parse_add_sub())
        return node

    def parse_add_sub(self):
        node = self.parse_mul_div()
        while self.peek()[0] == "OP" and self.peek()[1] in ("+", "-"):
            op = self.take()[1]
            node = ("arith", op, node, self.parse_mul_div())
        return node

    def parse_mul_div(self):
        node = self.parse_unary()
        while self.peek()[0] == "OP" and self.peek()[1] in ("*", "/", "%", "//"):
            op = self.take()[1]
            node = ("arith", op, node, self.parse_unary())
        return node

    def parse_unary(self):
        if self.peek() == ("OP", "-"):
            self.take()
            return ("neg", self.parse_unary())
        if self.peek() == ("OP", "~"):
            self.take()
            return ("bitnot", self.parse_unary())
        if self.is_word("make"):          # anonymous function: make x give x * 2
            return self.parse_lambda()
        nxt = self.tokens[self.pos + 1] if self.pos + 1 < len(self.tokens) else ("END", None)
        if self.is_word("start") and nxt[0] == "NAME":      # start fetch(url): run the call as a task
            self.take()
            call = self.parse_postfix()
            if call[0] != "call":
                raise VantaError("'start' runs a function call as a task: start NAME(VALUES)")
            return ("call", ("name", "spawn"), [call[1]] + call[2])
        if self.is_word("wait") and nxt[0] == "NAME" and nxt[1].lower() == "for":     # wait for task
            self.take()
            self.take()
            return ("call", ("name", "wait"), [self.parse_unary()])
        if self.is_word("receive") and nxt[0] == "NAME" and nxt[1].lower() == "from":  # receive from channel
            self.take()
            self.take()
            return ("call", ("name", "receive"), [self.parse_unary()])
        if self.is_word("new"):           # "new Dog(...)" is sugar for "Dog(...)"
            self.take()
            return self.parse_power()
        return self.parse_power()

    def parse_lambda(self):
        self.take()                       # 'make'
        params = []
        while not self.is_word("give"):
            k, v = self.take()
            if k == "NAME":
                params.append(v)
            elif k != "COMMA":
                raise VantaError("a 'make' function reads: make PARAMS give VALUE")
        self.take()                       # 'give'
        return ("lambda", params, self.parse_expression())

    def parse_power(self):
        base = self.parse_postfix()
        if self.peek() == ("OP", "^"):
            self.take()
            return ("arith", "^", base, self.parse_unary())   # right-associative
        return base

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            kind = self.peek()[0]
            if kind == "LP":
                self.take()
                node = self.parse_call_args(node)
            elif kind == "LB":
                self.take()
                start = None if self.peek()[0] == "COLON" else self.parse_expression()
                if self.peek()[0] == "COLON":          # a slice: [a:b], [a:], [:b], [:]
                    self.take()
                    end = None if self.peek()[0] == "RB" else self.parse_expression()
                    self.expect("RB", "a closing ] is missing")
                    node = ("sliceop", node, start, end)
                else:
                    self.expect("RB", "a closing ] is missing")
                    node = ("index", node, start)
            elif kind == "DOT":
                self.take()
                k, v = self.take()
                if k != "NAME":
                    raise VantaError("expected a name after '.'")
                node = ("getattr", node, v)
            else:
                return node

    def parse_primary(self):
        k, v = self.take()
        if k == "NUM":
            return ("lit", v)
        if k == "STR":
            return build_string_node(v)
        if k == "NAME":
            # lowercase or Capitalized; all-caps TRUE/FALSE are ordinary names (C-style constants)
            low = v.lower() if v in ("yes", "Yes", "true", "True", "no", "No", "false", "False", "nothing", "Nothing") else v
            if low in ("yes", "true"):
                return ("lit", True)
            if low in ("no", "false"):
                return ("lit", False)
            if low == "nothing":
                return ("lit", None)
            return ("name", v)
        if k == "LP":
            node = self.parse_expression()
            self.expect("RP", "a closing ) is missing")
            return node
        if k == "LB":
            return self.parse_list_or_comprehension()
        if k == "LC":
            return self.parse_map_or_comprehension()
        raise VantaError("that line is missing a value somewhere")

    def parse_list_or_comprehension(self):
        if self.peek()[0] == "RB":
            self.take()
            return ("list", [])
        first = self.parse_expression()
        if self.is_word("for"):                 # [EXPR for each NAME in LIST if COND]
            self.take()
            if not self.is_word("each"):
                raise VantaError("a comprehension reads [VALUE for each NAME in LIST]")
            self.take()
            name = self.comp_names()
            if not self.is_word("in"):
                raise VantaError("a comprehension needs 'in' before the list")
            self.take()
            iter_expr = self.parse_or()    # not parse_expression: leave the filter 'if' alone
            cond = None
            if self.is_word("if"):
                self.take()
                cond = self.parse_expression()
            self.expect("RB", "a closing ] is missing")
            return ("listcomp", first, name, iter_expr, cond)
        items = [first]
        while True:
            k = self.take()[0]
            if k == "RB":
                return ("list", items)
            if k != "COMMA":
                raise VantaError("expected a comma between values")
            if self.peek()[0] == "RB":         # a trailing comma: [1, 2, 3,]
                continue
            items.append(self.parse_expression())

    def parse_list_until(self, closer):
        items = []
        if self.peek()[0] == closer:
            self.take()
            return items
        while True:
            items.append(self.parse_expression())
            k = self.take()[0]
            if k == closer:
                return items
            if k != "COMMA":
                raise VantaError("expected a comma between values")

    def comp_names(self):
        """The name after 'for each' in a comprehension, or [key, value] for two names."""
        k, name = self.take()
        if k != "NAME":
            raise VantaError("expected a name after 'for each'")
        if self.peek()[0] == "COMMA":
            self.take()
            k2, name2 = self.take()
            if k2 != "NAME":
                raise VantaError("expected a second name after the comma")
            return [name, name2]
        return name

    def parse_call_args(self, callee):
        """f(a, b) -> ("call", f, args); with named values f(a, size: 2) -> ("callkw", f, args, [(name, node)])."""
        args, named = [], []
        if self.peek()[0] == "RP":
            self.take()
            return ("call", callee, args)
        while True:
            k, v = self.peek()
            if k == "NAME" and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1][0] == "COLON":
                self.take(); self.take()
                if any(n == v for n, _ in named):
                    raise VantaError(f"the value named '{v}' is given twice")
                named.append((v, self.parse_expression()))
            else:
                if named:
                    raise VantaError("plain values go before named ones (like f(1, size: 2))")
                args.append(self.parse_expression())
            k = self.take()[0]
            if k == "RP":
                break
            if k != "COMMA":
                raise VantaError("expected a comma between values")
            if self.peek()[0] == "RP":
                self.take()
                break
        if named:
            return ("callkw", callee, args, named)
        return ("call", callee, args)

    def parse_map_or_comprehension(self):
        if self.peek()[0] == "RC":
            self.take()
            return ("map", [])
        key = self.parse_expression()
        self.expect("COLON", "a map needs a : between key and value")
        value = self.parse_expression()
        if self.is_word("for"):              # {KEY: VALUE for each NAME in LIST if COND}
            self.take()
            if not self.is_word("each"):
                raise VantaError("a map comprehension reads {KEY: VALUE for each NAME in LIST}")
            self.take()
            name = self.comp_names()
            if not self.is_word("in"):
                raise VantaError("a comprehension needs 'in' before the list")
            self.take()
            iter_expr = self.parse_or()    # not parse_expression: leave the filter 'if' alone
            cond = None
            if self.is_word("if"):
                self.take()
                cond = self.parse_expression()
            self.expect("RC", "a closing } is missing")
            return ("mapcomp", key, value, name, iter_expr, cond)
        pairs = [(key, value)]
        while True:
            k = self.take()[0]
            if k == "RC":
                return ("map", pairs)
            if k != "COMMA":
                raise VantaError("expected a comma between map entries")
            if self.peek()[0] == "RC":
                continue
            key = self.parse_expression()
            self.expect("COLON", "a map needs a : between key and value")
            value = self.parse_expression()
            pairs.append((key, value))

    def expect(self, kind, message):
        if self.take()[0] != kind:
            raise VantaError(message)


def build_string_node(text):
    """Turn a string that may contain {expressions} into either a plain
    literal or a 'format' node that concatenates pieces at runtime.
    Use {{ and }} for literal braces."""
    if "{" not in text and "}" not in text:
        return ("lit", text)
    parts, buf = [], []
    has_expr = False
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "{" and i + 1 < n and text[i + 1] == "{":
            buf.append("{")
            i += 2
        elif ch == "}" and i + 1 < n and text[i + 1] == "}":
            buf.append("}")
            i += 2
        elif ch == "}":                       # a lone } is just a character
            buf.append(ch)
            i += 1
        elif ch == "{":
            j = i + 1
            while j < n and text[j] != "}":
                j += 1
            node = _interpolation(text[i + 1:j]) if j < n else None
            if node is None:                  # not {an expression}: keep the text as written (JSON, etc.)
                buf.append(ch)
                i += 1
                continue
            parts.append(("lit", "".join(buf)))
            buf = []
            parts.append(node)
            has_expr = True
            i = j + 1
        else:
            buf.append(ch)
            i += 1
    parts.append(("lit", "".join(buf)))
    if not has_expr:
        return ("lit", "".join(p[1] for p in parts))
    return ("format", parts)


def _interpolation(src):
    """The node for the inside of {...} in text, or None when it isn't an expression (then the braces are
    plain text). A real expression with a format spec Vanta doesn't know is an error that names the spec."""
    src = src.strip()
    if not src:
        return None
    spec = None
    cut = _format_spec_split(src)             # {price:.2}  {name:<10}  {n:,}
    if cut >= 0:
        src, spec = src[:cut].strip(), src[cut + 1:].strip()
    try:
        sub = Parser(tokenize(src))
        node = sub.parse_expression()
        if not sub.at_end():
            return None
    except VantaError:
        return None
    if spec is None:
        return node
    if not _FORMAT_SPEC.match(spec):
        if re.fullmatch(r"[A-Za-z_]\w+", spec) or " " in spec:
            return None                       # {"a": null} is JSON, not a format
        check_format_spec(spec)
    return ("fmtspec", node, spec)


def _format_spec_split(src):
    """Position of the ':' that starts a format spec in {expr:spec} (outside brackets), or -1."""
    depth, cut = 0, -1
    for i, c in enumerate(src):
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == ":" and depth == 0:
            cut = i
    return cut


# [[fill]align][0][width][,][.precision][type]   align: < left, > right, ^ centre
# type: f fixed, e scientific, % percent, x X hex, b binary, o octal, s text
_FORMAT_SPEC = re.compile(r"^(?:(.)?([<>^]))?(0)?(\d+)?(,)?(?:\.(\d+))?([feExXbo%s])?$")


def check_format_spec(spec):
    if not _FORMAT_SPEC.match(spec):
        raise VantaError(f"I don't understand the format ':{spec}' "
                         f"(try :.2 for two decimals, :8 for a width, :, for 1,000s)")


def _group_thousands(body):
    """Put commas into the whole-number part of a number's text: -1234567.5 -> -1,234,567.5"""
    sign = "-" if body.startswith("-") else ""
    digits = body[len(sign):]
    k = 0
    while k < len(digits) and digits[k].isdigit():
        k += 1
    whole, tail = digits[:k], digits[k:]
    groups = []
    while len(whole) > 3:
        groups.insert(0, whole[-3:])
        whole = whole[:-3]
    groups.insert(0, whole)
    return sign + ",".join(groups) + tail


def format_value(value, spec):
    """A value as text, shaped by a format spec (see _FORMAT_SPEC). Native builds do exactly the same."""
    m = _FORMAT_SPEC.match(spec)
    if not m:
        check_format_spec(spec)
    fill, align, zero, width, comma, prec, kind = m.groups()
    is_num = isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind in ("x", "X", "b", "o"):
        if not is_num or (isinstance(value, float) and value != int(value)):
            raise VantaError(f"the format ':{spec}' needs a whole number")
        body = format(int(value), kind)
    elif kind in ("e", "E"):
        if not is_num:
            raise VantaError(f"the format ':{spec}' needs a number")
        body = format(float(value), f".{6 if prec is None else int(prec)}{kind}")
    elif kind == "%":
        if not is_num:
            raise VantaError(f"the format ':{spec}' needs a number")
        body = format(float(value) * 100, f".{0 if prec is None else int(prec)}f") + "%"
    elif is_num and (kind == "f" or prec is not None):
        body = format(float(value), f".{6 if prec is None else int(prec)}f")
    elif prec is not None:                  # text cut to a length
        body = display(value)[:int(prec)]
    else:
        body = display(value)
    if comma and is_num and kind not in ("x", "X", "b", "o"):
        body = _group_thousands(body)
    w = int(width) if width else 0
    if zero and is_num and not align and len(body) < w:
        sign = "-" if body.startswith("-") else ""
        return sign + "0" * (w - len(body)) + body[len(sign):]
    if len(body) >= w:
        return body
    fill = fill or (" " if not zero or align else "0")
    align = align or (">" if is_num else "<")
    pad = w - len(body)
    if align == "<":
        return body + fill * pad
    if align == ">":
        return fill * pad + body
    return fill * (pad // 2) + body + fill * (pad - pad // 2)


def parse_expr_text(text, lineno):
    try:
        parser = Parser(tokenize(text))
        node = parser.parse_expression()
        if not parser.at_end():
            raise VantaError("I got confused near the end of that line")
        return node
    except VantaError as e:
        msg = str(e)
        raise VantaError(msg if msg.startswith("line ") else f"line {lineno}: {msg}")


# ===========================================================================
# STAGE 2b - STATEMENT PARSER  (lines -> list of statements)
# ===========================================================================

# Optional type notes (`let name: text be ...`, `to area(r: number) -> number`, `has age: number`).
# They don't change how a program runs; the parser records them here for `vanta check`:
# (line, what, name) -> type text, where what is "let", "param", "return" or "field".
TYPE_NOTES = {}


def strip_type_note(text, lineno, what):
    """'age: number' -> 'age' (remembering the note); 'age' -> 'age'."""
    if ":" not in text:
        return text.strip()
    name, _, note = text.partition(":")
    name, note = name.strip(), note.strip()
    if not re.fullmatch(r"[A-Za-z_][\w-]*( of [A-Za-z_][\w-]*)?", note):
        raise VantaError(f"line {lineno}: '{note}' is not a type name (like number, text, list, or a type)")
    TYPE_NOTES[(lineno, what, name)] = note
    return name


BLOCK_TERMINATORS = ("end", "otherwise", "rescue", "when")
BLOCK_OPENERS = ("if", "repeat", "while", "for", "to", "attempt", "type", "match", "using", "lock")


def first_word(line):
    return line.split(" ", 1)[0] if line else ""


def split_top_level(text, sep):
    """Split on sep, but not inside (), [], {} or "strings"."""
    parts, cur, depth, in_str, esc = [], [], 0, False, False
    for c in text:
        if in_str:
            cur.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            cur.append(c)
        elif c in "([{":
            depth += 1
            cur.append(c)
        elif c in ")]}":
            depth -= 1
            cur.append(c)
        elif c == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    parts.append("".join(cur))
    return parts


def parse_program(lines, keep_tests=False):
    stmts, pos = parse_block(lines, 0)
    if pos != len(lines):
        raise VantaError(f"line {lines[pos][0]}: an extra "
                         f"'{first_word(lines[pos][1])}' has no matching block")
    if not keep_tests:      # `test "..."` blocks only run under `vanta test`
        stmts = [s for s in stmts if s[0] != "test"]
    return stmts


def _top_level_word(text, word):
    """Index of ` word ` in text outside strings and brackets (or -1)."""
    depth, in_str, i, n = 0, False, 0, len(text)
    while i < n:
        c = text[i]
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
        elif depth == 0 and text.startswith(word, i) and (i == 0 or text[i - 1] == " ") \
                and (i + len(word) == n or text[i + len(word)] == " "):
            return i
        i += 1
    return -1


def parse_expect(text, lineno):
    """`expect A is B` / `is not` / any comparison / `contains` / `fails [with "msg"]` /
    plain `expect COND` -> a call to the __vanta_expect builtin that reports both values."""
    src = text.strip()
    lit = lambda v: ("lit", v)
    fi = _top_level_word(src, "fails")
    if fi > 0:
        after = src[fi + len("fails"):].strip()
        want = None
        if after:
            if not after.startswith("with "):
                raise VantaError(f'line {lineno}: use: expect ACTION fails  or  expect ACTION fails with "text"')
            want = parse_expr_text(after[len("with "):].strip(), lineno)
        action = ("lambda", [], parse_expr_text(src[:fi].strip(), lineno))
        return ("call", ("name", "__vanta_expect"), [lit("fails"), action, want or lit(None), lit(src)])
    ci = _top_level_word(src, "contains")
    if ci > 0:
        a = parse_expr_text(src[:ci].strip(), lineno)
        b = parse_expr_text(src[ci + len("contains"):].strip(), lineno)
        return ("call", ("name", "__vanta_expect"), [lit("contains"), a, b, lit(src)])
    node = parse_expr_text(src, lineno)
    if node[0] == "cmp":
        return ("call", ("name", "__vanta_expect"), [lit(node[1]), node[2], node[3], lit(src)])
    if node[0] in ("in", "notin", "isa"):
        return ("call", ("name", "__vanta_expect"), [lit(node[0]), node[1], node[2], lit(src)])
    return ("call", ("name", "__vanta_expect"), [lit("true"), node, lit(None), lit(src)])


def parse_block(lines, pos):
    stmts = []
    while pos < len(lines):
        if first_word(lines[pos][1]) in BLOCK_TERMINATORS:
            return stmts, pos
        stmt, pos = parse_one(lines, pos)
        stmts.append(stmt)
    return stmts, pos


def parse_one(lines, pos):
    try:
        return _parse_one(lines, pos)
    except VantaError as e:
        msg = str(e)
        if msg.startswith("your '") and "missing its 'end'" in msg:     # point at where the block starts
            raise VantaError(f"line {lines[pos][0]}: {msg} (the block starts here)")
        raise


def _parse_one(lines, pos):
    lineno, text = lines[pos]
    head = first_word(text)
    rest = text[len(head):].strip()

    if head == "if":
        return parse_if(lines, pos)

    if head == "repeat":
        count_text = rest[:-5].strip() if rest.endswith("times") else rest
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "repeat")
        return ("repeat", lineno, parse_expr_text(count_text, lineno), body), pos

    if head == "while":
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "while")
        return ("while", lineno, parse_expr_text(rest, lineno), body), pos

    if head == "for":
        if not rest.startswith("each "):
            raise VantaError(f"line {lineno}: use: for each NAME in LIST")
        after = rest[len("each "):]
        if " in " not in after:
            raise VantaError(f"line {lineno}: use: for each NAME in LIST")
        names_text, _, iter_text = after.partition(" in ")
        names = [n.strip() for n in names_text.split(",")]
        for nm in names:
            check_name(nm, lineno)
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "for")
        if len(names) == 1:
            return ("foreach", lineno, names[0],
                    parse_expr_text(iter_text, lineno), body), pos
        if len(names) == 2:
            return ("foreach2", lineno, names[0], names[1],
                    parse_expr_text(iter_text, lineno), body), pos
        raise VantaError(f"line {lineno}: 'for each' takes one or two names")

    if head == "increase" or head == "decrease":
        if " by " not in rest:
            raise VantaError(f"line {lineno}: use: {head} NAME by AMOUNT")
        target, _, amount_text = rest.partition(" by ")
        sign = "+" if head == "increase" else "-"
        target_node = parse_expr_text(target.strip(), lineno)
        amount = parse_expr_text(amount_text, lineno)
        return ("mutate", lineno, target_node, sign, amount), pos + 1

    if head == "match":
        return parse_match(lines, pos)

    if head == "to":
        name, params = parse_signature(rest, lineno)
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "to")
        return ("func", lineno, name, params, body), pos

    if head == "type":
        return parse_type(lines, pos)

    if head == "attempt":
        return parse_attempt(lines, pos)

    if head == "give":
        if not rest.startswith("back"):
            raise VantaError(f"line {lineno}: did you mean 'give back ...'?")
        value_text = rest[len("back"):].strip()
        node = parse_expr_text(value_text, lineno) if value_text else ("lit", None)
        return ("return", lineno, node), pos + 1

    if head == "let":
        name_part, sep, expr_text = rest.partition(" be ")
        if not sep:
            raise VantaError(f"line {lineno}: use: let NAME be VALUE")
        names = [strip_type_note(t, lineno, "let") for t in split_top_level(name_part, ",")]
        if len(names) > 1:
            for nm in names:
                check_name(nm, lineno)
            value_nodes = [parse_expr_text(s.strip(), lineno)
                           for s in split_top_level(expr_text, ",")]
            return ("let_multi", lineno, names, value_nodes), pos + 1
        check_name(names[0], lineno)
        return ("let", lineno, names[0], parse_expr_text(expr_text, lineno)), pos + 1

    if head == "fix":
        name, sep, expr_text = rest.partition(" be ")
        if not sep:
            raise VantaError(f"line {lineno}: use: fix NAME be VALUE")
        name = strip_type_note(name, lineno, "let")
        check_name(name.strip(), lineno)
        return ("fix", lineno, name.strip(), parse_expr_text(expr_text, lineno)), pos + 1

    if head == "change":
        if " to " not in rest:
            raise VantaError(f"line {lineno}: use: change NAME to VALUE")
        target, _, value_text = rest.partition(" to ")
        target = target.strip()
        target_segs = split_top_level(target, ",")
        if len(target_segs) > 1:
            target_nodes = [parse_expr_text(s.strip(), lineno) for s in target_segs]
            value_nodes = [parse_expr_text(s.strip(), lineno)
                           for s in split_top_level(value_text, ",")]
            return ("assign_multi", lineno, target_nodes, value_nodes), pos + 1
        value = parse_expr_text(value_text, lineno)
        if " at " in target and "[" not in target and "." not in target:
            name, _, index_text = target.partition(" at ")
            target_node = ("index", ("name", name.strip()),
                           parse_expr_text(index_text, lineno))
        else:
            target_node = parse_expr_text(target, lineno)
        return ("assign", lineno, target_node, value), pos + 1

    if head == "ask":
        if " into " not in rest:
            raise VantaError(f'line {lineno}: use: ask "question" into NAME')
        prompt_text, name = rest.rsplit(" into ", 1)
        check_name(name.strip(), lineno)
        prompt = parse_expr_text(prompt_text, lineno) if prompt_text.strip() else None
        return ("ask", lineno, prompt, name.strip()), pos + 1

    if head == "add" and " to " in rest:
        value_text, sep, list_text = rest.rpartition(" to ")
        return ("append", lineno, parse_expr_text(value_text, lineno),
                parse_expr_text(list_text, lineno)), pos + 1

    if head == "import":
        m = re.fullmatch(r'("(?:[^"\\]|\\.)*")\s+as\s+(\S+)', rest)
        if m:                                   # import "geometry" as geo
            check_name(m.group(2), lineno)
            return ("import_as", lineno, parse_expr_text(m.group(1), lineno), m.group(2)), pos + 1
        return ("import", lineno, parse_expr_text(rest, lineno)), pos + 1

    if head == "from":                          # from "geometry" use area, Circle
        m = re.fullmatch(r'("(?:[^"\\]|\\.)*")\s+use\s+(.+)', rest)
        if not m:
            raise VantaError(f'line {lineno}: use: from "module" use NAME, NAME')
        names = [n.strip() for n in m.group(2).split(",")]
        for nm in names:
            check_name(nm, lineno)
        return ("use", lineno, parse_expr_text(m.group(1), lineno), names), pos + 1

    if head == "kind" and re.fullmatch(r"[A-Za-z_]\w*(\s+is\s+.+)?", rest):
        return parse_kind(lines, pos)

    if head == "yield":                         # inside a function: hand out one value, then carry on
        return ("yield", lineno, parse_expr_text(rest, lineno) if rest else ("lit", None)), pos + 1

    if head == "using":                         # using f be open_thing(...) ... end   (f.close() at the end)
        name, sep, expr_text = rest.partition(" be ")
        if not sep:
            raise VantaError(f"line {lineno}: use: using NAME be VALUE")
        name = name.strip()
        check_name(name, lineno)
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "using")
        return ("using", lineno, name, parse_expr_text(expr_text, lineno), body), pos

    if head == "remove" and " from " in rest:   # remove x from a set / list / map
        value_text, _, coll_text = rest.rpartition(" from ")
        return ("remove", lineno, parse_expr_text(value_text, lineno),
                parse_expr_text(coll_text, lineno)), pos + 1

    if head == "private" and first_word(rest) in ("to", "let", "fix", "type", "kind"):
        saved, lines[pos] = lines[pos], (lineno, rest)
        try:
            inner, end_pos = parse_one(lines, pos)
        finally:
            lines[pos] = saved
        return ("private", lineno, inner), end_pos

    if head == "test" and rest.startswith('"'):         # test "name" ... end  (run by `vanta test`)
        name_node = parse_expr_text(rest, lineno)
        if name_node[0] != "lit" or not isinstance(name_node[1], str):
            raise VantaError(f'line {lineno}: use: test "what it checks"')
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "test")
        return ("test", lineno, name_node[1], body), pos

    if head == "expect" and rest and not rest.startswith("("):
        return ("expr", lineno, parse_expect(rest, lineno)), pos + 1

    if head == "send" and " to " in rest:                 # send VALUE to CHANNEL-OR-SOCKET
        value_text, _, target_text = rest.rpartition(" to ")
        return ("expr", lineno, ("call", ("name", "send"), [parse_expr_text(target_text, lineno),
                                                             parse_expr_text(value_text, lineno)])), pos + 1

    if head == "lock":                                     # lock [LOCK] ... end: one thread at a time
        target = parse_expr_text(rest, lineno) if rest else None
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "lock")
        return ("lock", lineno, target, body), pos

    if head == "say":
        node = parse_expr_text(rest, lineno) if rest else None
        return ("say", lineno, node), pos + 1

    if head == "stop":
        return ("stop", lineno), pos + 1

    if head == "skip":
        return ("skip", lineno), pos + 1

    # Anything else is a bare expression (typically a function or method call).
    return ("expr", lineno, parse_expr_text(text, lineno)), pos + 1


def parse_if(lines, pos):
    lineno, text = lines[pos]
    branches = []
    cond = parse_expr_text(text[len("if"):].strip(), lineno)
    body, pos = parse_block(lines, pos + 1)
    branches.append((cond, body))
    else_body = []
    while pos < len(lines) and first_word(lines[pos][1]) == "otherwise":
        after = lines[pos][1][len("otherwise"):].strip()
        if after.startswith("if"):
            cond2 = parse_expr_text(after[len("if"):].strip(), lines[pos][0])
            body2, pos = parse_block(lines, pos + 1)
            branches.append((cond2, body2))
        else:
            else_body, pos = parse_block(lines, pos + 1)
            break
    pos = expect_end(lines, pos, "if")
    return ("if", lineno, branches, else_body), pos


def parse_match(lines, pos):
    lineno, text = lines[pos]
    subject = parse_expr_text(text[len("match"):].strip(), lineno)
    branches, else_body = [], []
    pos += 1
    while pos < len(lines):
        head = first_word(lines[pos][1])
        if head == "when":
            value = parse_when(lines[pos][1][len("when"):].strip(), lines[pos][0])
            body, pos = parse_block(lines, pos + 1)
            branches.append((value, body))
        elif head == "otherwise":
            else_body, pos = parse_block(lines, pos + 1)
            break
        elif head == "end":
            break
        else:
            raise VantaError(f"line {lines[pos][0]}: inside 'match', "
                             f"use 'when VALUE' or 'otherwise'")
    pos = expect_end(lines, pos, "match")
    return ("match", lineno, subject, branches, else_body), pos


def parse_kind(lines, pos):
    """kind Color is red, green, blue      -- or a block with one or more names per line, ending in 'end'."""
    lineno, text = lines[pos]
    rest = text[len("kind"):].strip()
    if re.search(r"\s+is\s+", rest):
        name, members_text = re.split(r"\s+is\s+", rest, maxsplit=1)
        members = [m.strip() for m in members_text.split(",")]
        pos += 1
    else:
        name, members = rest, []
        pos += 1
        while pos < len(lines) and first_word(lines[pos][1]) != "end":
            members += [m.strip() for m in lines[pos][1].split(",") if m.strip()]
            pos += 1
        pos = expect_end(lines, pos, "kind")
    check_name(name.strip(), lineno)
    if not members:
        raise VantaError(f"line {lineno}: a kind needs at least one value (kind {name} is a, b, c)")
    for m in members:
        check_name(m, lineno)
        if members.count(m) > 1:
            raise VantaError(f"line {lineno}: '{m}' is listed twice in kind {name}")
    return ("enum", lineno, name.strip(), members), pos


def _find_word_outside(text, word):
    """Index of ' word ' outside strings and brackets, or -1."""
    depth, in_str, i = 0, False, 0
    pat = " " + word + " "
    while i < len(text):
        c = text[i]
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
        elif depth == 0 and text.startswith(pat, i):
            return i
        i += 1
    return -1


def parse_when(text, lineno):
    """The value(s) after 'when'. Plain values keep their old meaning (equality); patterns that take
    things apart give a ("pattern", [alternatives], guard) node:
        when [first, rest...]      when {"name": n}      when a Circle with radius      when [x, y] if x > y"""
    guard = None
    gi = _find_word_outside(text, "if")
    if gi >= 0 and _find_word_outside(text, "otherwise") < 0:
        guard = parse_expr_text(text[gi + 4:].strip(), lineno)
        text = text[:gi].strip()
    pats = []
    for alt in split_top_level(text, ","):
        try:
            p = Parser(tokenize(alt.strip()))
            pats.append(_parse_pattern(p, True))
            if not p.at_end():
                raise VantaError("I got confused in that 'when' pattern")
        except VantaError as e:
            msg = str(e)
            raise VantaError(msg if msg.startswith("line ") else f"line {lineno}: {msg}")
    if guard is None and all(p[0] == "pat_value" for p in pats):
        if len(pats) == 1:
            return pats[0][1]
        return ("anyof", [p[1] for p in pats])        # when 1, 2, 3  -> matches any of them
    return ("pattern", pats, guard)


_LITERAL_WORDS = {"yes", "no", "true", "false", "nothing", "Yes", "No", "True", "False", "Nothing"}


def _parse_pattern(p, top):
    k, v = p.peek()
    nxt = p.tokens[p.pos + 1] if p.pos + 1 < len(p.tokens) else ("END", None)
    if top and k == "NAME" and v in ("a", "an") and nxt[0] == "NAME":     # when a Circle with radius
        p.take()
        node = ("name", p.take()[1])
        while p.peek()[0] == "DOT":
            p.take()
            k2, v2 = p.take()
            if k2 != "NAME":
                raise VantaError("expected a name after '.'")
            node = ("getattr", node, v2)
        fields = []
        if p.is_word("with"):
            p.take()
            while True:
                k2, v2 = p.take()
                if k2 != "NAME":
                    raise VantaError("after 'with', list the fields to take out: with x, y")
                fields.append(v2)
                if p.peek()[0] != "COMMA":
                    break
                p.take()
        return ("pat_type", node, fields)
    if k == "LB":                                   # [a, b]  [first, rest...]  [0, y]
        p.take()
        items, rest = [], None
        if p.peek()[0] == "RB":
            p.take()
        else:
            while True:
                k2, v2 = p.peek()
                if k2 == "NAME" and p.tokens[p.pos + 1:p.pos + 4] == [("DOT", "."), ("DOT", "."), ("DOT", ".")]:
                    p.pos += 4
                    rest = v2
                    p.expect("RB", "'name...' takes the rest, so it goes last in a list pattern")
                    break
                items.append(_parse_pattern(p, False))
                k2 = p.take()[0]
                if k2 == "RB":
                    break
                if k2 != "COMMA":
                    raise VantaError("expected a comma between pattern items")
        if rest is None and all(i[0] == "pat_value" for i in items):
            return ("pat_value", ("list", [i[1] for i in items]))
        return ("pat_list", items, rest)
    if k == "LC":                                   # {"name": n, "age": a}
        p.take()
        pairs = []
        if p.peek()[0] == "RC":
            p.take()
        else:
            while True:
                key = p.parse_expression()
                p.expect("COLON", "a map pattern needs a : between key and value")
                pairs.append((key, _parse_pattern(p, False)))
                k2 = p.take()[0]
                if k2 == "RC":
                    break
                if k2 != "COMMA":
                    raise VantaError("expected a comma between pattern entries")
        if all(pv[0] == "pat_value" for _, pv in pairs):
            return ("pat_value", ("map", [(kn, pv[1]) for kn, pv in pairs]))
        return ("pat_map", pairs)
    if not top and k == "NAME" and v not in _LITERAL_WORDS and nxt[0] in ("COMMA", "RB", "RC", "END"):
        p.take()
        return ("pat_any",) if v == "_" else ("pat_bind", v)
    return ("pat_value", p.parse_expression())


def pattern_names(pat, out):
    """Names a pattern binds (in order)."""
    tag = pat[0]
    if tag == "pat_bind" and pat[1] not in out:
        out.append(pat[1])
    elif tag == "pat_list":
        for i in pat[1]:
            pattern_names(i, out)
        if pat[2] and pat[2] not in out:
            out.append(pat[2])
    elif tag == "pat_map":
        for _, pv in pat[1]:
            pattern_names(pv, out)
    elif tag == "pat_type":
        for f in pat[2]:
            if f not in out:
                out.append(f)
    return out


def parse_type(lines, pos):
    lineno, text = lines[pos]
    header = text[len("type"):].strip()
    parent_name = None
    if " from " in header:
        type_name, _, parent_name = header.partition(" from ")
        type_name, parent_name = type_name.strip(), parent_name.strip()
        for part in parent_name.split("."):        # a dotted name reaches into a module: from geo.Shape
            check_name(part, lineno)
    else:
        type_name = header
    check_name(type_name, lineno)
    fields, methods = [], TypeBody()
    pos += 1
    while pos < len(lines) and first_word(lines[pos][1]) != "end":
        l2, t2 = lines[pos]
        h2 = first_word(t2)
        shared = False
        if h2 == "shared":                  # shared to make() / shared count be 0: belongs to the type itself
            t2 = t2[len("shared"):].strip()
            h2 = first_word(t2)
            shared = True
            if h2 != "to":
                fname, sep, vtext = t2.partition(" be ")
                if not sep:
                    raise VantaError(f"line {l2}: use: shared NAME be VALUE  or  shared to METHOD()")
                fname = strip_type_note(fname, l2, "field")
                check_name(fname, l2)
                methods.shared_fields.append((fname, parse_expr_text(vtext, l2)))
                pos += 1
                continue
        if h2 == "has":
            field = strip_type_note(t2[len("has"):], l2, "field")
            check_name(field, l2)
            fields.append(field)
            pos += 1
        elif h2 == "to":
            start = pos
            saved, lines[start] = lines[start], (l2, t2)
            try:
                mstmt, pos = parse_one(lines, start)
            finally:
                lines[start] = saved
            fn = Function(mstmt[2], mstmt[3], mstmt[4])
            fn.file = CURRENT_FILE
            fn.shared = shared
            if shared and mstmt[2] in methods and not methods[mstmt[2]].shared or \
                    not shared and mstmt[2] in methods and methods[mstmt[2]].shared:
                raise VantaError(f"line {l2}: '{mstmt[2]}' is both a shared and an ordinary method")
            methods[mstmt[2]] = fn
        else:
            raise VantaError(f"line {l2}: inside a type, use 'has NAME', 'to METHOD()' or 'shared ...'")
    pos = expect_end(lines, pos, "type")
    return ("type", lineno, type_name, parent_name, fields, methods), pos


def parse_attempt(lines, pos):
    lineno = lines[pos][0]
    body, pos = parse_block(lines, pos + 1)
    if pos >= len(lines) or first_word(lines[pos][1]) != "rescue":
        raise VantaError(f"line {lineno}: 'attempt' needs a 'rescue NAME' part")
    errname = lines[pos][1][len("rescue"):].strip() or "error"
    check_name(errname, lines[pos][0])
    rescue_body, pos = parse_block(lines, pos + 1)
    pos = expect_end(lines, pos, "attempt")
    return ("attempt", lineno, body, errname, rescue_body), pos


REST_PARAM = ("rest",)      # the default of a `values...` parameter: it collects the remaining values


def parse_signature(sig, lineno):
    sig = sig.strip()
    returns = None
    m = re.search(r"\s*->\s*([A-Za-z_][\w-]*(?: of [A-Za-z_][\w-]*)?)$", sig)
    if m:                                       # to area(r) -> number
        returns = m.group(1)
        sig = sig[:m.start()].strip()
    if "(" in sig and sig.endswith(")"):
        name = sig[:sig.index("(")].strip()
        inside = sig[sig.index("(") + 1:-1].strip()
        param_texts = [p.strip() for p in split_top_level(inside, ",") if p.strip()]
    elif " with " in sig:
        name, _, rest = sig.partition(" with ")
        param_texts = [p.strip() for p in split_top_level(rest, ",") if p.strip()]
    else:
        name, param_texts = sig.strip(), []
    if name != "each":                          # `to each()` makes a type loopable, so it's allowed
        check_name(name, lineno)
    if returns is not None:
        TYPE_NOTES[(lineno, "return", name)] = returns
    params = []
    seen_default = False
    for i, p in enumerate(param_texts):
        if p.endswith("..."):                   # to total(numbers...)
            pname = strip_type_note(p[:-3], lineno, "param")
            check_name(pname, lineno)
            if i != len(param_texts) - 1:
                raise VantaError(f"line {lineno}: '{pname}...' collects the rest, so it must come last")
            params.append((pname, REST_PARAM))
        elif " be " in p:
            pname, _, dtext = p.partition(" be ")
            pname = strip_type_note(pname, lineno, "param")
            check_name(pname, lineno)
            params.append((pname, parse_expr_text(dtext.strip(), lineno)))
            seen_default = True
        else:
            p = strip_type_note(p, lineno, "param")
            check_name(p, lineno)
            if seen_default:
                raise VantaError(f"line {lineno}: '{p}' has no default but comes "
                                 f"after one that does")
            params.append((p, None))
    return name, params


def expect_end(lines, pos, what):
    if pos >= len(lines) or first_word(lines[pos][1]) != "end":
        raise VantaError(f"your '{what}' is missing its 'end'")
    return pos + 1


# ===========================================================================
# STAGE 3 - RUNTIME
# ===========================================================================

class Function:
    file = None                       # the .va file it was written in (for error traces)

    def __init__(self, name, params, body):
        self.name = name
        self.params = params          # list of (name, default_node_or_None)
        self.body = body
        self.compiled = None          # compiled body (a block runner); built on demand
        self.owner = None             # the type a method was defined in (for super)
        self.defining_env = None      # the scope it was defined in (for closures)

    shared = False                    # a type-level method (`shared to make()`), called as Type.make()
    _gen = None                       # does the body 'yield' (making it a generator function)? cached

    @property
    def is_generator(self):
        if self._gen is None:
            self._gen = body_yields(self.body)
        return self._gen


class TypeBody(dict):
    """A type's methods (name -> Function). Shared (type-level) methods are in it too, marked fn.shared;
    shared fields (`shared count be 0`) are listed in .shared_fields as (name, value node)."""
    def __init__(self):
        super().__init__()
        self.shared_fields = []


class Builtin:
    def __init__(self, name, fn):
        self.name = name
        self.fn = fn


class VantaType:
    def __init__(self, name, fields, methods, parent=None):
        self.name = name
        self.fields = fields
        self.methods = methods
        self.parent = parent
        self.shared = {}              # type-level values and methods: Type.name


class VantaInstance:
    def __init__(self, vtype, attrs):
        self.vtype = vtype
        self.attrs = attrs

    # `is` between two objects asks the type's `equals(other)` method, when it has one
    def __eq__(self, other):
        if self is other:
            return True
        if isinstance(other, VantaInstance):
            fn = self.vtype.methods.get("equals")
            if fn is not None and not fn.shared:
                return truthy(call_method(self, fn, [other]))
        return False

    __hash__ = object.__hash__

    def __lt__(self, other):                  # so sort() can order objects with less_than
        return less_than(self, other)

    def __gt__(self, other):
        return less_than(other, self)


class VantaModule:
    """What `import "geometry" as geo` gives: geo.area, geo.Circle (names marked private stay hidden)."""
    def __init__(self, name, env, private):
        self.name = name
        self.env = env
        self.private = private

    def exports(self):
        return [n for n in self.env.vars if n not in self.private and n not in ("pi", "e")]


class VantaEnum:
    """kind Color is red, green, blue"""
    def __init__(self, name, member_names):
        self.name = name
        self.members = [EnumMember(self, m, i) for i, m in enumerate(member_names)]
        self.by_name = {m.name: m for m in self.members}


class EnumMember:
    __slots__ = ("kind", "name", "index")

    def __init__(self, kind, name, index):
        self.kind = kind
        self.name = name
        self.index = index

    def __lt__(self, other):
        if isinstance(other, EnumMember) and other.kind is self.kind:
            return self.index < other.index
        return NotImplemented


class _BoolKey:
    """yes/no as a map key or set item. Python counts True == 1, Vanta doesn't: {1: "a", yes: "b"} has two keys.
    Keys go in through _key() and come out through _unkey()."""
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value

    def __repr__(self):
        return "yes" if self.value else "no"


_TRUE_KEY, _FALSE_KEY = _BoolKey(True), _BoolKey(False)


def _key(k):
    if k.__class__ is bool:
        return _TRUE_KEY if k else _FALSE_KEY
    return k


def _unkey(k):
    return k.value if k.__class__ is _BoolKey else k


class VantaSet:
    """A set: each value at most once, kept in the order added. set([1, 2]), add x to s, x is in s."""
    __slots__ = ("items",)

    def __init__(self, values=()):
        self.items = {}
        for v in values:
            self.add(v)

    def add(self, v):
        if isinstance(v, (list, dict, VantaSet, bytearray)):
            raise VantaError(f"a {type_name(v)} can't go in a set (only values like numbers, text, yes/no)")
        self.items[_key(v)] = True

    def __eq__(self, other):
        return isinstance(other, VantaSet) and self.items.keys() == other.items.keys()

    __hash__ = None

    def __iter__(self):
        return iter([_unkey(k) for k in self.items])

    def values(self):
        return [_unkey(k) for k in self.items]

    def __len__(self):
        return len(self.items)


class VantaGenerator:
    """What calling a function that uses `yield` gives back: values made one at a time, on demand."""
    def __init__(self, name, py_gen):
        self.name = name
        self.py_gen = py_gen
        self.done = False

    def __iter__(self):
        return self

    def __next__(self):
        if self.done:
            raise StopIteration
        try:
            return next(self.py_gen)
        except StopIteration:
            self.done = True
            raise
        except ValueError as e:             # "generator already executing"
            raise VantaError("a generator can't ask itself for its next value") from e
        except BaseException:
            self.done = True
            raise


class BoundMethod:
    def __init__(self, inst, fn):
        self.inst = inst
        self.fn = fn


class SuperProxy:
    """What 'super' resolves to inside a method: lets you call the parent's
    version of a method, bound to the same object."""
    def __init__(self, inst, parent_type):
        self.inst = inst
        self.parent_type = parent_type


_MISSING = object()


class Environment:
    # `consts` (names fixed with 'fix') defaults to a shared empty frozenset, so
    # the common environment — a function call frame — costs nothing extra. The
    # first 'fix' in a scope upgrades it to a real, mutable set.
    consts = frozenset()
    is_module = False         # the top level of a module loaded with `import "x" as y` / `from "x" use`

    def __init__(self, parent=None):
        self.vars = {}
        self.parent = parent

    def get(self, name):
        env = self
        while env is not None:
            if name in env.vars:
                return env.vars[name]
            env = env.parent
        return _MISSING

    def define(self, name, value):
        self.vars[name] = value

    def fix(self, name, value):
        self.vars[name] = value
        if type(self.consts) is frozenset:
            self.consts = set()
        self.consts.add(name)

    def assign(self, name, value):
        env = self
        while env is not None:
            if name in env.vars:
                if name in env.consts:
                    return "const"
                env.vars[name] = value
                return True
            env = env.parent
        return False


class ReturnSignal(Exception):
    def __init__(self, value):
        self.value = value


class BreakLoop(Exception):
    pass


class ContinueLoop(Exception):
    pass


def _at_line(e, lineno):
    """An error passing a statement on `lineno`: give it the line number (the innermost
    statement wins) and record the Vanta call stack in e.vtrace as [line, function, file]
    frames, innermost first (function/file are filled in as it leaves each function)."""
    tb = getattr(e, "vtrace", None)
    if tb is None:
        tb = []
    if not str(e).startswith("line "):
        new = VantaError(f"line {lineno}: {e}")
        new.vtrace = tb
        tb.append([lineno, None, None])
        return new
    e.vtrace = tb
    if getattr(e, "vpending", False):     # just left a function: this is the call site
        if len(tb) < 100:                 # (runaway recursion: keep the innermost 100 frames)
            tb.append([lineno, None, None])
        e.vpending = False
    return e


def _left_function(e, fn):
    """An error is leaving function `fn`: name the frame it happened in."""
    tb = getattr(e, "vtrace", None)
    if tb and tb[-1][1] is None:
        tb[-1][1] = fn.name
        tb[-1][2] = fn.file
    e.vpending = True


def run_block(stmts, env):
    # The per-statement try/except attaches a line number to runtime errors.
    # Inlined here (rather than via a run_stmt helper) to avoid a function call
    # on every statement — this is one of the hottest loops in the interpreter.
    for stmt in stmts:
        try:
            _run_stmt(stmt, env)
        except VantaError as e:
            raise _at_line(e, stmt[1])


def run_stmt(stmt, env):
    try:
        _run_stmt(stmt, env)
    except VantaError as e:
        raise _at_line(e, stmt[1])


def _run_stmt(stmt, env):
    tag = stmt[0]

    # --- hot statement types first (kept near the top for dispatch speed) ---

    if tag == "if":
        _, _, branches, else_body = stmt
        for cond, body in branches:
            if truthy(eval_expr(cond, env)):
                run_block(body, env)
                return
        run_block(else_body, env)

    elif tag == "return":
        raise ReturnSignal(eval_expr(stmt[2], env))

    elif tag == "assign":
        do_assign(stmt[2], eval_expr(stmt[3], env), env)

    elif tag == "let":
        if stmt[2] in env.consts:
            raise VantaError(f"'{stmt[2]}' is fixed and can't be changed")
        env.define(stmt[2], eval_expr(stmt[3], env))

    elif tag == "expr":
        eval_expr(stmt[2], env)

    elif tag == "mutate":
        _, _, target_node, sign, amount_node = stmt
        current = eval_expr(target_node, env)
        new_value = mutate_value(sign, current, eval_expr(amount_node, env))
        do_assign(target_node, new_value, env)

    elif tag == "say":
        node = stmt[2]
        print("" if node is None else display(eval_expr(node, env)))

    # --- everything else ---

    elif tag == "fix":
        env.fix(stmt[2], eval_expr(stmt[3], env))

    elif tag == "let_multi":
        names, value_nodes = stmt[2], stmt[3]
        for nm, val in zip(names, eval_value_group(value_nodes, len(names), env)):
            if nm in env.consts:
                raise VantaError(f"'{nm}' is fixed and can't be changed")
            env.define(nm, val)

    elif tag == "assign_multi":
        targets, value_nodes = stmt[2], stmt[3]
        for tnode, val in zip(targets, eval_value_group(value_nodes, len(targets), env)):
            do_assign(tnode, val, env)

    elif tag == "append":
        add_to(eval_expr(stmt[2], env), eval_expr(stmt[3], env))

    elif tag == "ask":
        prompt = "" if stmt[2] is None else display(eval_expr(stmt[2], env))
        try:
            answer = input(prompt + " " if prompt else "")
        except EOFError:
            raise VantaError("there was no answer to 'ask' (the input ended)")
        env.define(stmt[3], smart_value(answer))

    elif tag == "repeat":
        count = eval_expr(stmt[2], env)
        if not isinstance(count, int) or isinstance(count, bool):
            raise VantaError("repeat needs a whole number of times")
        for _ in range(count):
            try:
                run_block(stmt[3], env)
            except BreakLoop:
                break
            except ContinueLoop:
                continue

    elif tag == "while":
        while truthy(eval_expr(stmt[2], env)):
            try:
                run_block(stmt[3], env)
            except BreakLoop:
                break
            except ContinueLoop:
                continue

    elif tag == "foreach":
        _, _, name, iter_node, body = stmt
        for item in iterate(eval_expr(iter_node, env)):
            env.define(name, item)
            try:
                run_block(body, env)
            except BreakLoop:
                break
            except ContinueLoop:
                continue

    elif tag == "foreach2":
        _, _, name1, name2, iter_node, body = stmt
        for first, second in iterate_pairs(eval_expr(iter_node, env)):
            env.define(name1, first)
            env.define(name2, second)
            try:
                run_block(body, env)
            except BreakLoop:
                break
            except ContinueLoop:
                continue

    elif tag == "match":
        _, _, subject_node, branches, else_body = stmt
        subject = eval_expr(subject_node, env)
        for value_node, body in branches:
            if value_node[0] == "anyof":
                hit = any(subject == eval_expr(v, env) for v in value_node[1])
            elif value_node[0] == "pattern":
                hit = compile_when_test(value_node)(subject, env)
            else:
                hit = subject == eval_expr(value_node, env)
            if hit:
                run_block(body, env)
                return
        run_block(else_body, env)

    elif tag == "func":
        _, _, name, params, body = stmt
        fn = Function(name, params, body)
        fn.defining_env = env          # so a nested function closes over this scope
        env.define(name, fn)

    elif tag == "type":
        _, _, name, parent_name, fields, own_methods = stmt
        parent = None
        shared_methods = {n: m for n, m in own_methods.items() if m.shared}
        own_methods = {n: m for n, m in own_methods.items() if not m.shared}
        final_fields = list(fields)
        final_methods = dict(own_methods)
        if parent_name is not None:
            if "." in parent_name:
                parent = eval_expr(parse_expr_text(parent_name, stmt[1]), env)
            else:
                parent = env.get(parent_name)
            if not isinstance(parent, VantaType):
                raise VantaError(f"'{parent_name}' is not a type to inherit from")
            final_fields = list(parent.fields)
            for field in fields:
                if field not in final_fields:
                    final_fields.append(field)
            final_methods = dict(parent.methods)
            final_methods.update(own_methods)
        vtype = VantaType(name, final_fields, final_methods, parent)
        home = module_env_of(env)               # methods see the top level of the file they're in
        for method in own_methods.values():     # remember where each was defined
            method.owner = vtype
            method.defining_env = home
        for mname, method in shared_methods.items():
            method.owner = vtype
            method.defining_env = home
            vtype.shared[mname] = method
        for fname, vnode in getattr(stmt[5], "shared_fields", ()):
            vtype.shared[fname] = eval_expr(vnode, env)
        env.define(name, vtype)

    elif tag == "enum":
        env.define(stmt[2], VantaEnum(stmt[2], stmt[3]))

    elif tag == "private":
        _run_stmt(stmt[2], env)

    elif tag == "import_as":
        env.define(stmt[3], import_module(display(eval_expr(stmt[2], env))))

    elif tag == "use":
        use_names(import_module(display(eval_expr(stmt[2], env))), stmt[3], env)

    elif tag == "remove":
        remove_from(eval_expr(stmt[2], env), eval_expr(stmt[3], env))

    elif tag == "yield":
        raise VantaError("'yield' only works inside a function (it makes the function a generator)")

    elif tag == "using":
        _, _, name, value_node, body = stmt
        resource = eval_expr(value_node, env)
        env.define(name, resource)
        try:
            run_block(body, env)
        finally:
            close_resource(resource)

    elif tag == "attempt":
        _, _, body, errname, rescue_body = stmt
        try:
            run_block(body, env)
        except VantaError as e:
            env.define(errname, clean_message(str(e)))
            run_block(rescue_body, env)

    elif tag == "stop":
        raise BreakLoop()

    elif tag == "skip":
        raise ContinueLoop()

    elif tag == "import":
        import_file(display(eval_expr(stmt[2], env)))

    elif tag == "test":
        raise VantaError("a 'test' block goes at the top level of a file, not inside another block")

    else:
        raise VantaError(f"internal error: unknown statement {tag}")


def clean_message(msg):
    """Drop a leading 'line N: ' so rescue gets a tidy message."""
    if msg.startswith("line "):
        idx = msg.find(": ")
        if idx != -1:
            return msg[idx + 2:]
    return msg


# --------------------------------------------------------------------------
# Expression evaluation
# --------------------------------------------------------------------------

def eval_expr(node, env):
    tag = node[0]

    if tag == "lit":
        return node[1]

    if tag == "name":
        value = env.get(node[1])
        if value is not _MISSING:
            return value
        if node[1] in BUILTIN_VALUES:
            return BUILTIN_VALUES[node[1]]
        raise VantaError(f"I don't know what '{node[1]}' is yet")

    # --- hot node types first (kept near the top for dispatch speed) ---

    if tag == "arith":
        return arithmetic(node[1], eval_expr(node[2], env), eval_expr(node[3], env))

    if tag == "cmp":
        return compare(node[1], eval_expr(node[2], env), eval_expr(node[3], env))

    if tag == "call":
        callee = resolve_callee(node[1], env)
        args = [eval_expr(a, env) for a in node[2]]
        return apply_callable(callee, args)

    if tag == "index":
        return get_index(eval_expr(node[1], env), eval_expr(node[2], env))

    if tag == "getattr":
        return get_attr(eval_expr(node[1], env), node[2])

    # --- everything else ---

    if tag == "format":
        return "".join(display(eval_expr(part, env)) for part in node[1])

    if tag == "list":
        return [eval_expr(item, env) for item in node[1]]

    if tag == "map":
        result = {}
        for key_node, val_node in node[1]:
            result[_key(eval_expr(key_node, env))] = eval_expr(val_node, env)
        return result

    if tag == "bitnot":
        return bit_not(eval_expr(node[1], env))

    if tag == "neg":
        value = eval_expr(node[1], env)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return negate(value)
        return -value

    if tag == "callkw":
        callee = resolve_callee(node[1], env)
        args = [eval_expr(a, env) for a in node[2]]
        return apply_callable(callee, args, [(k, eval_expr(v, env)) for k, v in node[3]])

    if tag == "fmtspec":
        return format_value(eval_expr(node[1], env), node[2])

    if tag == "not":
        return not truthy(eval_expr(node[1], env))

    if tag == "and":
        if not truthy(eval_expr(node[1], env)):
            return False
        return truthy(eval_expr(node[2], env))

    if tag == "or":
        if truthy(eval_expr(node[1], env)):
            return True
        return truthy(eval_expr(node[2], env))

    if tag == "isa":
        target = eval_expr(node[2], env)
        if not isinstance(target, (VantaType, VantaEnum)):
            raise VantaError("the right side of 'is a' must be a type")
        return is_instance_of(eval_expr(node[1], env), target)

    if tag == "ternary":
        return eval_expr(node[2], env) if truthy(eval_expr(node[1], env)) \
            else eval_expr(node[3], env)

    if tag == "lambda":
        params = [(name, None) for name in node[1]]
        fn = Function("<anonymous>", params, [("return", 0, node[2])])
        fn.defining_env = env          # closes over the scope it was made in
        return fn

    if tag == "in":
        return is_member(eval_expr(node[1], env), eval_expr(node[2], env))

    if tag == "notin":
        return not is_member(eval_expr(node[1], env), eval_expr(node[2], env))

    if tag in ("listcomp", "mapcomp") and isinstance(node[-3], list):
        return compile_expr(node)(env)

    if tag == "listcomp":
        _, out_expr, var, iter_expr, cond = node
        loop_env = Environment(env)
        result = []
        for item in iterate(eval_expr(iter_expr, env)):
            loop_env.define(var, item)
            if cond is None or truthy(eval_expr(cond, loop_env)):
                result.append(eval_expr(out_expr, loop_env))
        return result

    if tag == "mapcomp":
        _, key_expr, val_expr, var, iter_expr, cond = node
        loop_env = Environment(env)
        result = {}
        for item in iterate(eval_expr(iter_expr, env)):
            loop_env.define(var, item)
            if cond is None or truthy(eval_expr(cond, loop_env)):
                result[_key(eval_expr(key_expr, loop_env))] = eval_expr(val_expr, loop_env)
        return result

    if tag == "sliceop":
        target = eval_expr(node[1], env)
        if not isinstance(target, (list, str, bytearray)):
            raise VantaError("you can only slice a list, text, or bytes")
        start = eval_expr(node[2], env) if node[2] is not None else None
        end = eval_expr(node[3], env) if node[3] is not None else None
        for bound in (start, end):
            if bound is not None and (isinstance(bound, bool) or not isinstance(bound, int)):
                raise VantaError("slice positions must be whole numbers")
        return target[start:end]

    raise VantaError(f"internal error: unknown expression {tag}")


# --------------------------------------------------------------------------
# Calling: functions, builtins, methods, constructors
# --------------------------------------------------------------------------

def resolve_callee(target, env):
    if target[0] == "name":
        name = target[1]
        value = env.get(name)
        if value is not _MISSING:
            return value
        if name in BUILTIN_VALUES:
            return BUILTIN_VALUES[name]
        raise VantaError(f"I don't know a function called '{name}'")
    return eval_expr(target, env)


def apply_callable(callee, args, kwargs=None):
    if isinstance(callee, Function):
        return call_function(callee, args, kwargs)
    if isinstance(callee, Builtin):
        if kwargs:
            raise VantaError(f"the builtin '{callee.name}' doesn't take named values")
        return callee.fn(args)
    if isinstance(callee, BoundMethod):
        return call_method(callee.inst, callee.fn, args, kwargs)
    if isinstance(callee, VantaType):
        return construct_instance(callee, args, kwargs)
    raise VantaError("that value is not a function you can call")


def bind_params(name, params, args, local, kwargs=None):
    # Writes straight into local.vars and only builds the (quoted) error label
    # on the failure paths — this runs on every function/method call.
    if kwargs:
        args = merge_named(name, [p for p, _ in params], args, kwargs,
                           params[-1][1] is REST_PARAM if params else False)
    nargs = len(args)
    if nargs > len(params) and not (params and params[-1][1] is REST_PARAM):
        raise VantaError(too_many_message(name, params, nargs))
    lv = local.vars
    for i, (pname, default) in enumerate(params):
        if default is REST_PARAM:
            lv[pname] = list(args[i:])
        elif i < nargs and args[i] is not _MISSING:
            lv[pname] = args[i]
        elif default is not None:
            lv[pname] = eval_expr(default, local)
        else:
            raise VantaError(f"'{name}' is missing a value for '{pname}'")


def too_many_message(name, params, nargs):
    n = len(params)
    if n == 0:
        return f"'{name}' doesn't take any values, but got {nargs}"
    word = "value" if n == 1 else "values"
    if any(d is not None for _, d in params):
        return f"'{name}' takes at most {n} {word}, but got {nargs}"
    return f"'{name}' takes {n} {word}, but got {nargs}"


def merge_named(name, pnames, args, kwargs, has_rest):
    """Place named values (f(size: 2)) into their positions; gaps are _MISSING (use the default)."""
    last = len(pnames) - 1 if has_rest else len(pnames)
    out = list(args)
    for key, value in kwargs:
        if key not in pnames:
            raise VantaError(f"'{name}' has no value named '{key}'")
        i = pnames.index(key)
        if i >= last:
            raise VantaError(f"'{key}...' collects plain values, so it can't be given by name")
        if i < len(args):
            raise VantaError(f"'{name}' got two values for '{key}'")
        while len(out) <= i:
            out.append(_MISSING)
        out[i] = value
    return out


def body_yields(stmts):
    """Does this block 'yield' (not counting functions defined inside it)?"""
    for st in stmts:
        tag = st[0]
        if tag == "yield":
            return True
        if tag == "if":
            if any(body_yields(b) for _, b in st[2]) or body_yields(st[3]):
                return True
        elif tag in ("while", "repeat"):
            if body_yields(st[3]):
                return True
        elif tag == "foreach":
            if body_yields(st[4]):
                return True
        elif tag == "foreach2":
            if body_yields(st[5]):
                return True
        elif tag == "match":
            if any(body_yields(b) for _, b in st[3]) or body_yields(st[4]):
                return True
        elif tag == "attempt":
            if body_yields(st[2]) or body_yields(st[4]):
                return True
        elif tag == "using":
            if body_yields(st[4]):
                return True
    return False


def compile_function_body(name, body_ast):
    """A function body as a runner. A body that yields becomes a generator: calling it gives back a
    generator object straight away, and the body runs a step at a time as values are asked for."""
    if not body_yields(body_ast):
        return compile_block(body_ast)
    gen_body = compile_block_gen(body_ast)

    def drive(env):
        yield from gen_body(env)          # 'give back' inside a generator just ends it

    def start(env):
        return _Return(VantaGenerator(name, drive(env)))
    return start


def call_function(fn, args, kwargs=None):
    body = fn.compiled
    if body is None:
        body = fn.compiled = compile_function_body(fn.name, fn.body)
    local = Environment(fn.defining_env or GLOBAL_ENV)
    bind_params(fn.name, fn.params, args, local, kwargs)
    try:
        sig = body(local)
    except VantaError as e:
        _left_function(e, fn)
        raise
    except RecursionError:
        raise VantaError(TOO_DEEP)
    if type(sig) is _Return:
        return sig.value
    return None


TOO_DEEP = "this went too deep: a function kept calling itself (is a stopping case missing?)"


def call_method(inst, fn, args, kwargs=None):
    body = fn.compiled
    if body is None:
        body = fn.compiled = compile_function_body(fn.name, fn.body)
    local = Environment(fn.defining_env or GLOBAL_ENV)    # methods see their module's top level
    lv = local.vars
    lv["me"] = inst
    parent_type = fn.owner.parent if getattr(fn, "owner", None) else None
    lv["super"] = SuperProxy(inst, parent_type)
    bind_params(fn.name, fn.params, args, local, kwargs)
    try:
        sig = body(local)
    except VantaError as e:
        _left_function(e, fn)
        raise
    except RecursionError:
        raise VantaError(TOO_DEEP)
    if type(sig) is _Return:
        return sig.value
    return None


def construct_instance(vtype, args, kwargs=None):
    inst = VantaInstance(vtype, {f: None for f in vtype.fields})
    if "setup" in vtype.methods:
        call_method(inst, vtype.methods["setup"], args, kwargs)
        return inst
    if kwargs:                                  # new Dog(name: "Rex", sound: "Woof")
        args = merge_named(vtype.name, vtype.fields, args, kwargs, False)
        if len(args) == len(vtype.fields) and _MISSING not in args:
            for field, value in zip(vtype.fields, args):
                inst.attrs[field] = value
            return inst
        missing = [f for i, f in enumerate(vtype.fields) if i >= len(args) or args[i] is _MISSING]
        raise VantaError(f"{vtype.name} is missing a value for '{missing[0]}'")
    if len(args) == len(vtype.fields):
        for field, value in zip(vtype.fields, args):
            inst.attrs[field] = value
    else:
        raise VantaError(f"{vtype.name} expects {len(vtype.fields)} value(s) "
                         f"({', '.join(vtype.fields)}), but got {len(args)}")
    return inst


def is_instance_of(value, vtype):
    if isinstance(vtype, VantaEnum):
        return isinstance(value, EnumMember) and value.kind is vtype
    if not isinstance(value, VantaInstance):
        return False
    t = value.vtype
    while t is not None:
        if t is vtype:
            return True
        t = t.parent
    return False


def get_attr(obj, attr):
    if isinstance(obj, SuperProxy):
        if obj.parent_type is None:
            raise VantaError("there is no parent type to reach with 'super'")
        method = obj.parent_type.methods.get(attr)
        if method is None:
            raise VantaError(f"the parent type has no '{attr}'")
        return BoundMethod(obj.inst, method)
    if isinstance(obj, VantaInstance):
        if attr in obj.attrs:
            return obj.attrs[attr]
        if attr in obj.vtype.methods:
            return BoundMethod(obj, obj.vtype.methods[attr])
        raise VantaError(f"a {obj.vtype.name} has no '{attr}'")
    return get_attr_other(obj, attr)


def shared_owner(vtype, attr):
    """The type (vtype or a parent) that has a shared value/method called attr, or None."""
    t = vtype
    while t is not None:
        if attr in t.shared:
            return t
        t = t.parent
    return None


def get_attr_other(obj, attr):
    if isinstance(obj, VantaModule):
        if attr in obj.private:
            raise VantaError(f"'{attr}' is private to the module '{obj.name}'")
        value = obj.env.vars.get(attr, _MISSING)
        if value is _MISSING:
            raise VantaError(f"the module '{obj.name}' has no '{attr}'")
        return value
    if isinstance(obj, VantaType):
        owner = shared_owner(obj, attr)
        if owner is None:
            raise VantaError(f"the type {obj.name} has no shared '{attr}'")
        return owner.shared[attr]
    if isinstance(obj, EnumMember):
        if attr == "name":
            return obj.name
        if attr == "index":
            return obj.index
        raise VantaError(f"a {obj.kind.name} value has 'name' and 'index', not '{attr}'")
    if isinstance(obj, VantaEnum):
        if attr in obj.by_name:
            return obj.by_name[attr]
        raise VantaError(f"the kind {obj.name} has no value '{attr}' "
                         f"(it has {', '.join(m.name for m in obj.members)})")
    raise VantaError("you can only use '.' on an object made from a type")


def set_attr(obj, attr, value):
    if isinstance(obj, VantaInstance):
        obj.attrs[attr] = value
        return
    if isinstance(obj, VantaType):
        owner = shared_owner(obj, attr)
        if owner is None:
            raise VantaError(f"the type {obj.name} has no shared '{attr}' (add: shared {attr} be ...)")
        owner.shared[attr] = value
        return
    if isinstance(obj, VantaModule):
        get_attr_other(obj, attr)
        obj.env.vars[attr] = value
        return
    raise VantaError("you can only set a '.' field on an object made from a type")


def eval_value_group(value_nodes, count, env):
    """Resolve the right-hand side of a multiple assignment into `count`
    values. One list value gets unpacked; several values are taken as-is."""
    if len(value_nodes) == 1:
        value = eval_expr(value_nodes[0], env)
        if not isinstance(value, list):
            raise VantaError("to unpack into several names, the value must be a list")
        if len(value) != count:
            raise VantaError(f"expected {count} values but the list has {len(value)}")
        return list(value)
    if len(value_nodes) != count:
        raise VantaError(f"there are {count} names but {len(value_nodes)} values")
    return [eval_expr(node, env) for node in value_nodes]


def do_assign(target, value, env):
    tag = target[0]
    if tag == "name":
        result = env.assign(target[1], value)
        if result == "const":
            raise VantaError(f"'{target[1]}' is fixed and can't be changed")
        if not result:
            raise VantaError(f"'{target[1]}' doesn't exist yet "
                             f"(use: let {target[1]} be ...)")
    elif tag == "index":
        set_index(eval_expr(target[1], env), eval_expr(target[2], env), value)
    elif tag == "getattr":
        set_attr(eval_expr(target[1], env), target[2], value)
    else:
        raise VantaError("you can't change that")


# --------------------------------------------------------------------------
# Operators and indexing
# --------------------------------------------------------------------------

BIT_OPS = {"&", "|", "xor", "<<", ">>"}


def bit_op(op, a, b):
    if type(a) is float and a == int(a):
        a = int(a)
    if type(b) is float and b == int(b):
        b = int(b)
    if type(a) is not int or type(b) is not int:
        raise VantaError(f"I can only do bit math ({op}) with whole numbers")
    if op == "&":
        return a & b
    if op == "|":
        return a | b
    if op == "xor":
        return a ^ b
    if b < 0:
        raise VantaError("you can't shift by a negative amount")
    return a << b if op == "<<" else a >> b


def bit_not(value):
    if type(value) is float and value == int(value):
        value = int(value)
    if type(value) is not int:
        raise VantaError("~ only works on whole numbers")
    return ~value


def arithmetic(op, a, b):
    if op in BIT_OPS:
        return bit_op(op, a, b)
    # Fast path: both operands are plain numbers (the overwhelmingly common
    # case). `type(x) is int` excludes bool — booleans aren't numbers here — so
    # this is exactly as strict as check_numbers, but without the isinstance
    # calls and the list/text special-casing below.
    ta = type(a)
    tb = type(b)
    if (ta is int or ta is float) and (tb is int or tb is float):
        if op == "+":
            return a + b
        if op == "-":
            return a - b
        if op == "*":
            return a * b
        if op == "%":
            if b == 0:
                raise VantaError("you can't take the remainder with zero")
            return a % b
        if op == "^":
            return a ** b
        if op == "//":                         # whole-number division, rounding down
            if b == 0:
                raise VantaError("you can't divide by zero")
            return a // b
        if op == "/":
            if b == 0:
                raise VantaError("you can't divide by zero")
            if ta is int and tb is int and a % b == 0:
                return a // b                  # exact, however big
            result = a / b
            return int(result) if result == int(result) else result

    if type(a) is VantaInstance:               # money + other -> money.add(other)
        method = a.vtype.methods.get(OPERATOR_METHODS.get(op))
        if method is not None:
            return call_method(a, method, [b])
    if op == "+":
        if isinstance(a, list) and isinstance(b, list):
            return a + b
        if isinstance(a, str) or isinstance(b, str):
            return display(a) + display(b)
        check_numbers(a, b, "+")
        return a + b
    if op == "*":
        # text/list repetition: "ab" * 3, [0] * 4
        if isinstance(a, (str, list)) and isinstance(b, int) and not isinstance(b, bool):
            return a * b
        if isinstance(b, (str, list)) and isinstance(a, int) and not isinstance(a, bool):
            return b * a
    check_numbers(a, b, op)
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "^":
        return a ** b
    if op == "%":
        if b == 0:
            raise VantaError("you can't take the remainder with zero")
        return a % b
    if op == "//":
        if b == 0:
            raise VantaError("you can't divide by zero")
        return a // b
    if op == "/":
        if b == 0:
            raise VantaError("you can't divide by zero")
        result = a / b
        return int(result) if result == int(result) else result


# the method an operator asks an object for (the object must be on the left)
OPERATOR_METHODS = {"+": "add", "-": "subtract", "*": "multiply", "/": "divide", "%": "remainder"}


def mutate_value(sign, current, amount):
    """increase/decrease: numbers only (joining text is `change x to x + ...`)."""
    for v in (current, amount):
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            word = "increase" if sign == "+" else "decrease"
            raise VantaError(f"'{word}' needs numbers, but got {type_name(v)} "
                             f"(to join text, use: change NAME to NAME + ...)")
    return current + amount if sign == "+" else current - amount


def check_numbers(a, b, op):
    for value in (a, b):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise VantaError(f"I can only do math ({op}) with numbers")


def compare(op, a, b):
    if op == "==":
        return a == b
    if op == "!=":
        return a != b
    ta = type(a)
    tb = type(b)
    both_numbers = (ta is int or ta is float) and (tb is int or tb is float)
    both_text = ta is str and tb is str
    if not (both_numbers or both_text):
        if ta is EnumMember and tb is EnumMember and a.kind is b.kind:
            a, b = a.index, b.index            # values of a kind compare in the order they're listed
        elif ta is VantaInstance or tb is VantaInstance:
            if op == "<":
                return less_than(a, b)
            if op == ">":
                return less_than(b, a)
            if op == "<=":
                return not less_than(b, a)
            return not less_than(a, b)
        else:
            raise VantaError("I can only compare numbers with numbers, or text with text")
    if op == ">":
        return a > b
    if op == "<":
        return a < b
    if op == ">=":
        return a >= b
    if op == "<=":
        return a <= b


def less_than(a, b):
    """a < b where at least one side is an object: asks its type's less_than(other) method."""
    if type(a) is VantaInstance:
        fn = a.vtype.methods.get("less_than")
        if fn is not None:
            return truthy(call_method(a, fn, [b]))
    if type(b) is VantaInstance:
        fn = b.vtype.methods.get("less_than")
        if fn is not None:
            return not truthy(call_method(b, fn, [a])) and not b == a
    raise VantaError("to compare objects with < or >, give their type a less_than(other) method")


def object_method(value, name):
    """The method `name` of an object value (not shared ones), or None."""
    if type(value) is VantaInstance:
        fn = value.vtype.methods.get(name)
        if fn is not None and not fn.shared:
            return fn
    return None


def _empty_check(collection):
    if len(collection) == 0:
        raise VantaError(f"the {type_name(collection)} is empty")


def get_index(collection, index):
    if isinstance(collection, (list, str, bytearray)):
        if not collection:
            _empty_check(collection)
        return collection[whole_index(index, len(collection))]
    if isinstance(collection, dict):
        index = _key(index)
        if index not in collection:
            raise VantaError(f"this map has no key {display_item(_unkey(index))}")
        return collection[index]
    fn = object_method(collection, "index")
    if fn is not None:                         # obj[i] -> obj.index(i)
        return call_method(collection, fn, [index])
    raise VantaError("you can only look inside a list, text, or map")


def set_index(collection, index, value):
    if isinstance(collection, (list, bytearray)) and not collection:
        _empty_check(collection)
    if isinstance(collection, list):
        collection[whole_index(index, len(collection))] = value
    elif isinstance(collection, bytearray):
        if type(value) is not int or not 0 <= value <= 255:
            raise VantaError("a byte must be a whole number from 0 to 255")
        collection[whole_index(index, len(collection))] = value
    elif isinstance(collection, dict):
        collection[_key(index)] = value
    elif object_method(collection, "set_index") is not None:   # change obj[i] to v -> obj.set_index(i, v)
        call_method(collection, object_method(collection, "set_index"), [index, value])
    else:
        raise VantaError("you can only change a position inside a list or map")


def whole_index(index, length):
    if isinstance(index, bool) or not isinstance(index, int):
        raise VantaError("a position must be a whole number")
    if length == 0:
        raise VantaError("the list is empty")
    resolved = index + length if index < 0 else index   # -1 means the last item
    if resolved < 0 or resolved >= length:
        raise VantaError(f"position {index} is outside the range "
                         f"-{length}..{length - 1}")
    return resolved


def is_member(value, collection):
    if isinstance(collection, dict):
        try:
            return _key(value) in collection
        except TypeError:                      # a list/map is never a key
            return False
    if isinstance(collection, (list, str)):
        return value in collection
    if isinstance(collection, VantaSet):
        try:
            return _key(value) in collection.items
        except TypeError:                      # a list/map is never in a set
            return False
    if isinstance(collection, VantaEnum):
        return isinstance(value, EnumMember) and value.kind is collection
    fn = object_method(collection, "contains")
    if fn is not None:                         # x is in obj -> obj.contains(x)
        return truthy(call_method(collection, fn, [value]))
    if isinstance(collection, VantaGenerator) or object_method(collection, "each") is not None:
        return any(value == item for item in iterate(collection))
    raise VantaError("'in' needs a list, text, map, or set on the right side")


def iterate_pairs(value):
    if isinstance(value, dict):
        return [(_unkey(k), v) for k, v in value.items()]
    if isinstance(value, (list, str)):
        return list(enumerate(value))
    if isinstance(value, (VantaSet, VantaGenerator, VantaEnum, VantaInstance)):
        return enumerate(iterate(value))
    raise VantaError("looping with two names needs a map, list, or text")


def iterate(value):
    if isinstance(value, list):
        return list(value)
    if isinstance(value, str):
        return list(value)
    if isinstance(value, dict):
        return [_unkey(k) for k in value]
    if isinstance(value, bytearray):
        return list(value)
    if isinstance(value, VantaGenerator):
        return value                           # lazily, one value at a time
    if isinstance(value, VantaSet):
        return value.values()
    if isinstance(value, VantaEnum):
        return list(value.members)
    fn = object_method(value, "each")
    if fn is not None:                         # a type that defines each() can be looped over
        return iterate(call_method(value, fn, []))
    raise VantaError("you can only loop over a list, text, map, set, or bytes")


# ===========================================================================
# STANDARD LIBRARY  (built-in functions)
# ===========================================================================

def _need(args, count, name):
    if len(args) != count:
        raise VantaError(f"{name} expects {count} value(s), got {len(args)}")


def int_arg(value, name):
    if isinstance(value, bool) or not isinstance(value, int):
        raise VantaError(f"{name} needs whole numbers")
    return value


def num_arg(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise VantaError(f"{name} needs a number")
    return value


def tidy_number(value):
    """Turn 4.0 into 4 but leave 4.5 alone."""
    if isinstance(value, float) and value == int(value):
        return int(value)
    return value


# ---- conversions & inspection -------------------------------------------

def b_length(args):
    _need(args, 1, "length")
    if isinstance(args[0], (str, list, dict, bytearray, VantaSet)):
        return len(args[0])
    if isinstance(args[0], VantaEnum):
        return len(args[0].members)
    fn = object_method(args[0], "length")
    if fn is not None:                         # length(obj) -> obj.length()
        return call_method(args[0], fn, [])
    raise VantaError("length works on text, lists, maps, or bytes")


def b_text(args):
    _need(args, 1, "text")
    return display(args[0])


def b_number(args):
    _need(args, 1, "number")
    v = args[0]
    if isinstance(v, bool):
        raise VantaError("can't turn yes/no into a number")
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                raise VantaError(f'"{v}" is not a number')
    raise VantaError("can't turn that into a number")


def b_type_of(args):
    _need(args, 1, "type_of")
    return type_name(args[0])


def b_is_number(args):
    _need(args, 1, "is_number")
    return isinstance(args[0], (int, float)) and not isinstance(args[0], bool)


def b_is_text(args):
    _need(args, 1, "is_text")
    return isinstance(args[0], str)


def b_is_list(args):
    _need(args, 1, "is_list")
    return isinstance(args[0], list)


def b_is_map(args):
    _need(args, 1, "is_map")
    return isinstance(args[0], dict)


def b_is_function(args):
    _need(args, 1, "is_function")
    return isinstance(args[0], (Function, Builtin, BoundMethod))


def b_is_nothing(args):
    _need(args, 1, "is_nothing")
    return args[0] is None


# ---- text helpers --------------------------------------------------------

def b_upper(args):
    _need(args, 1, "uppercase")
    return display(args[0]).upper()


def b_lower(args):
    _need(args, 1, "lowercase")
    return display(args[0]).lower()


def b_trim(args):
    _need(args, 1, "trim")
    return display(args[0]).strip()


def b_replace(args):
    _need(args, 3, "replace")
    return display(args[0]).replace(display(args[1]), display(args[2]))


def b_starts_with(args):
    _need(args, 2, "starts_with")
    return display(args[0]).startswith(display(args[1]))


def b_ends_with(args):
    _need(args, 2, "ends_with")
    return display(args[0]).endswith(display(args[1]))


def b_find(args):
    _need(args, 2, "find")
    return display(args[0]).find(display(args[1]))


def b_split(args):
    _need(args, 2, "split")
    sep = display(args[1])
    if sep == "":                              # split("abc", "") -> ["a", "b", "c"]
        return list(display(args[0]))
    return display(args[0]).split(sep)


def b_lines(args):
    _need(args, 1, "lines")
    return display(args[0]).split("\n")


def b_chr(args):
    _need(args, 1, "chr")
    n = int_arg(args[0], "chr")
    if n < 0 or n > 0x10FFFF:
        raise VantaError("chr needs a number from 0 to 1114111")
    return chr(n)


def b_code(args):
    _need(args, 1, "code")
    text = display(args[0])
    if len(text) == 0:
        raise VantaError("code needs a non-empty text value")
    return ord(text[0])


def b_pad_left(args):
    if len(args) not in (2, 3):
        raise VantaError("pad_left expects text, a width, and an optional character")
    fill = display(args[2])[:1] or " " if len(args) == 3 else " "
    return display(args[0]).rjust(int_arg(args[1], "pad_left"), fill)


def b_pad_right(args):
    if len(args) not in (2, 3):
        raise VantaError("pad_right expects text, a width, and an optional character")
    fill = display(args[2])[:1] or " " if len(args) == 3 else " "
    return display(args[0]).ljust(int_arg(args[1], "pad_right"), fill)


# ---- number helpers ------------------------------------------------------

def b_abs(args):
    _need(args, 1, "abs")
    return abs(num_arg(args[0], "abs"))


def b_round(args):
    if len(args) == 1:
        return round(num_arg(args[0], "round"))
    if len(args) == 2:
        digits = int_arg(args[1], "round")
        return round(num_arg(args[0], "round"), digits)
    raise VantaError("round expects a number (and an optional digit count)")


def b_floor(args):
    _need(args, 1, "floor")
    return math.floor(num_arg(args[0], "floor"))


def b_ceil(args):
    _need(args, 1, "ceil")
    return math.ceil(num_arg(args[0], "ceil"))


def b_sqrt(args):
    _need(args, 1, "sqrt")
    value = num_arg(args[0], "sqrt")
    if value < 0:
        raise VantaError("can't take the square root of a negative number")
    return tidy_number(math.sqrt(value))


def b_power(args):
    _need(args, 2, "power")
    return num_arg(args[0], "power") ** num_arg(args[1], "power")


def b_sin(args):
    _need(args, 1, "sin")
    return math.sin(num_arg(args[0], "sin"))


def b_cos(args):
    _need(args, 1, "cos")
    return math.cos(num_arg(args[0], "cos"))


def b_tan(args):
    _need(args, 1, "tan")
    return math.tan(num_arg(args[0], "tan"))


def b_log(args):
    if len(args) == 1:
        value = num_arg(args[0], "log")
        if value <= 0:
            raise VantaError("log needs a number above zero")
        return math.log(value)
    if len(args) == 2:
        value, base = num_arg(args[0], "log"), num_arg(args[1], "log")
        if value <= 0 or base <= 0:
            raise VantaError("log needs numbers above zero")
        return math.log(value, base)
    raise VantaError("log expects a number (and an optional base)")


def b_exp(args):
    _need(args, 1, "exp")
    return math.exp(num_arg(args[0], "exp"))


def b_sum(args):
    _need(args, 1, "sum")
    if not isinstance(args[0], list):
        raise VantaError("sum needs a list of numbers")
    total = 0
    for value in args[0]:
        total = total + num_arg(value, "sum")
    return total


def b_product(args):
    _need(args, 1, "product")
    if not isinstance(args[0], list):
        raise VantaError("product needs a list of numbers")
    result = 1
    for value in args[0]:
        result = result * num_arg(value, "product")
    return result


def _less(a, b):
    if type(a) is VantaInstance or type(b) is VantaInstance:
        return less_than(a, b)
    if type(a) is EnumMember and type(b) is EnumMember and a.kind is b.kind:
        return a.index < b.index
    both_num = (isinstance(a, (int, float)) and isinstance(b, (int, float))
                and not isinstance(a, bool) and not isinstance(b, bool))
    both_text = isinstance(a, str) and isinstance(b, str)
    if not (both_num or both_text):
        raise VantaError("min/max need all numbers or all text")
    return a < b


def _collect(args, name):
    values = args[0] if len(args) == 1 and isinstance(args[0], list) else list(args)
    if not values:
        raise VantaError(f"{name} needs at least one value")
    return values


def b_min(args):
    values = _collect(args, "min")
    best = values[0]
    for v in values[1:]:
        if _less(v, best):
            best = v
    return best


def b_max(args):
    values = _collect(args, "max")
    best = values[0]
    for v in values[1:]:
        if _less(best, v):
            best = v
    return best


def b_random(args):
    _need(args, 2, "random")
    low, high = int_arg(args[0], "random"), int_arg(args[1], "random")
    if low > high:
        raise VantaError("random needs the low number first")
    return random.randint(low, high)


def b_now(args):
    _need(args, 0, "now")
    return int(time.time())


# ---- list & map helpers --------------------------------------------------

def b_first(args):
    _need(args, 1, "first")
    if isinstance(args[0], (list, str)) and len(args[0]) > 0:
        return args[0][0]
    raise VantaError("first needs a non-empty list or text")


def b_last(args):
    _need(args, 1, "last")
    if isinstance(args[0], (list, str)) and len(args[0]) > 0:
        return args[0][-1]
    raise VantaError("last needs a non-empty list or text")


def b_range(args):
    if len(args) == 1:
        return list(range(int_arg(args[0], "range")))
    if len(args) == 2:
        return list(range(int_arg(args[0], "range"), int_arg(args[1], "range")))
    if len(args) == 3:                         # range(10, 0, -2) -> [10, 8, 6, 4, 2]
        step = int_arg(args[2], "range")
        if step == 0:
            raise VantaError("range's step can't be zero")
        return list(range(int_arg(args[0], "range"), int_arg(args[1], "range"), step))
    raise VantaError("range expects 1, 2 or 3 numbers (start, stop, step)")


def b_contains(args):
    _need(args, 2, "contains")
    coll, item = args
    if isinstance(coll, (list, str, dict, VantaSet)):
        return is_member(item, coll)
    raise VantaError("contains works on lists, text, or maps")


# ---- 6.0: sets, generators, formatting ------------------------------------

def _set_arg(value, name):
    if not isinstance(value, VantaSet):
        raise VantaError(f"{name} needs sets (make one with set([...]))")
    return value


def b_set(args):
    if len(args) == 0:
        return VantaSet()
    _need(args, 1, "set")
    return VantaSet(iterate(args[0]))


def b_is_set(args):
    _need(args, 1, "is_set")
    return isinstance(args[0], VantaSet)


def b_union(args):
    _need(args, 2, "union")
    a, b = _set_arg(args[0], "union"), _set_arg(args[1], "union")
    return VantaSet(a.values() + b.values())


def b_intersection(args):
    _need(args, 2, "intersection")
    a, b = _set_arg(args[0], "intersection"), _set_arg(args[1], "intersection")
    return VantaSet(x for x in a.values() if is_member(x, b))


def b_difference(args):
    _need(args, 2, "difference")
    a, b = _set_arg(args[0], "difference"), _set_arg(args[1], "difference")
    return VantaSet(x for x in a.values() if not is_member(x, b))


def b_is_subset(args):
    _need(args, 2, "is_subset")
    a, b = _set_arg(args[0], "is_subset"), _set_arg(args[1], "is_subset")
    return all(is_member(x, b) for x in a.values())


def b_list(args):
    if len(args) == 0:
        return []
    _need(args, 1, "list")
    return list(iterate(args[0]))


def b_next(args):
    if len(args) not in (1, 2):
        raise VantaError("next expects a generator (and an optional value for when it's finished)")
    g = args[0]
    if not isinstance(g, VantaGenerator):
        raise VantaError("next needs a generator (a function that uses yield)")
    try:
        return next(g)
    except StopIteration:
        if len(args) == 2:
            return args[1]
        raise VantaError(f"the generator {g.name} has no more values")


def b_format(args):
    _need(args, 2, "format")
    spec = display(args[1])
    check_format_spec(spec)
    return format_value(args[0], spec)


def b_join(args):
    _need(args, 2, "join")
    seq, sep = args
    if not isinstance(seq, list):
        raise VantaError("join needs a list as its first value")
    return display(sep).join(display(x) for x in seq)


def b_keys(args):
    _need(args, 1, "keys")
    if not isinstance(args[0], dict):
        raise VantaError("keys needs a map")
    return [_unkey(k) for k in args[0]]


def b_values(args):
    _need(args, 1, "values")
    if not isinstance(args[0], dict):
        raise VantaError("values needs a map")
    return list(args[0].values())


def b_sort(args):
    if len(args) not in (1, 2):
        raise VantaError('sort expects a list (and an optional "desc")')
    if not isinstance(args[0], list):
        raise VantaError("sort needs a list")
    desc = False
    if len(args) == 2:
        order = display(args[1]).lower()
        if order in ("desc", "descending", "reverse"):
            desc = True
        elif order not in ("asc", "ascending"):
            raise VantaError('sort\'s second value should be "asc" or "desc"')
    try:
        return sorted(args[0], reverse=desc)
    except TypeError:
        raise VantaError("sort needs a list of all numbers or all text")


def b_reverse(args):
    _need(args, 1, "reverse")
    if isinstance(args[0], list):
        return list(reversed(args[0]))
    if isinstance(args[0], str):
        return args[0][::-1]
    raise VantaError("reverse needs a list or text")


def b_slice(args):
    _need(args, 3, "slice")
    seq = args[0]
    if not isinstance(seq, (list, str)):
        raise VantaError("slice needs a list or text")
    return seq[int_arg(args[1], "slice"):int_arg(args[2], "slice")]


def b_push(args):
    _need(args, 2, "push")
    if not isinstance(args[0], list):
        raise VantaError("push needs a list")
    args[0].append(args[1])
    return None


def b_pop(args):
    _need(args, 1, "pop")
    if not isinstance(args[0], list) or not args[0]:
        raise VantaError("pop needs a non-empty list")
    return args[0].pop()


def b_remove_at(args):
    _need(args, 2, "remove_at")
    if not isinstance(args[0], list):
        raise VantaError("remove_at needs a list")
    return args[0].pop(whole_index(args[1], len(args[0])))


# ---- higher-order functions ---------------------------------------------

def b_map(args):
    _need(args, 2, "map")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("map needs a function and a list")
    return [apply_callable(fn, [x]) for x in seq]


def b_keep(args):
    _need(args, 2, "keep")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("keep needs a function and a list")
    return [x for x in seq if truthy(apply_callable(fn, [x]))]


def b_reduce(args):
    _need(args, 3, "reduce")
    fn, seq, start = args
    if not isinstance(seq, list):
        raise VantaError("reduce needs a function, a list, and a starting value")
    acc = start
    for x in seq:
        acc = apply_callable(fn, [acc, x])
    return acc


def b_each(args):
    _need(args, 2, "each")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("each needs a function and a list")
    for x in seq:
        apply_callable(fn, [x])
    return None


def b_count_where(args):
    _need(args, 2, "count_where")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("count_where needs a function and a list")
    return sum(1 for x in seq if truthy(apply_callable(fn, [x])))


def b_find_where(args):
    _need(args, 2, "find_where")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("find_where needs a function and a list")
    for x in seq:
        if truthy(apply_callable(fn, [x])):
            return x
    return None


def b_sort_by(args):
    _need(args, 2, "sort_by")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("sort_by needs a function and a list")
    try:
        return sorted(seq, key=lambda x: apply_callable(fn, [x]))
    except TypeError:
        raise VantaError("sort_by's keys must be all numbers or all text")


# ---- errors --------------------------------------------------------------

def b_fail(args):
    _need(args, 1, "fail")
    raise VantaError(display(args[0]))


def b_assert(args):
    if len(args) not in (1, 2):
        raise VantaError("assert expects a condition and an optional message")
    if not truthy(args[0]):
        raise VantaError(display(args[1]) if len(args) == 2 else "assertion failed")
    return None


def _shown(value):
    """A value as a test failure shows it: text in quotes, everything else as printed."""
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(_shown(v) for v in value) + "]"
    return display(value)


_EXPECT_WORDS = {">": "over", "<": "under", ">=": "at least", "<=": "at most"}


def b_vanta_expect(args):
    """What an `expect ...` line runs (the parser builds the call; see parse_expect)."""
    kind, a, b, src = args
    if kind == "fails":
        try:
            got = apply_callable(a, [])
        except VantaError as e:
            msg = clean_message(str(e))
            if b is not None and display(b) not in msg:
                raise VantaError(f"expect {src}: the error should mention {_shown(display(b))}, "
                                 f"but it was {_shown(msg)}")
            return None
        raise VantaError(f"expect {src}: expected an error, but it gave back {_shown(got)}")
    if kind == "==":
        if a != b or type(a) is bool and type(b) is not bool or type(b) is bool and type(a) is not bool:
            raise VantaError(f"expect {src}: expected {_shown(b)}, got {_shown(a)}")
    elif kind == "!=":
        if a == b:
            raise VantaError(f"expect {src}: expected anything but {_shown(b)}, got {_shown(a)}")
    elif kind in _EXPECT_WORDS:
        if not compare(kind, a, b):
            raise VantaError(f"expect {src}: expected a value {_EXPECT_WORDS[kind]} {_shown(b)}, got {_shown(a)}")
    elif kind == "contains":
        if isinstance(a, dict):
            ok = b in a
        elif isinstance(a, (list, str, bytearray)):
            ok = (display(b) in a) if isinstance(a, str) else (b in a)
        else:
            raise VantaError(f"expect {src}: 'contains' needs a list, text, or map, got {_shown(a)}")
        if not ok:
            raise VantaError(f"expect {src}: {_shown(a)} does not contain {_shown(b)}")
    elif kind in ("in", "notin"):
        if is_member(a, b) != (kind == "in"):
            raise VantaError(f"expect {src}: {_shown(a)} is {'not ' if kind == 'in' else ''}in {_shown(b)}")
    elif kind == "isa":
        if not isinstance(b, VantaType) or not is_instance_of(a, b):
            raise VantaError(f"expect {src}: got {_shown(a)} (a {type_name(a)})")
    elif not truthy(a):
        raise VantaError(f"expect {src}: it was {_shown(a)}")
    return None


# ---- files, system, json -------------------------------------------------

def b_read_file(args):
    _need(args, 1, "read_file")
    try:
        with open(display(args[0]), "r") as f:
            return f.read()
    except OSError as e:
        raise VantaError(f"could not read file: {e}")


def b_write_file(args):
    _need(args, 2, "write_file")
    try:
        with open(display(args[0]), "w") as f:
            f.write(display(args[1]))
    except OSError as e:
        raise VantaError(f"could not write file: {e}")
    return None


def b_run(args):
    if len(args) not in (1, 2):
        raise VantaError("run expects a command (and an optional directory)")
    cwd = display(args[1]) if len(args) == 2 else None
    result = subprocess.run(display(args[0]), shell=True,
                            capture_output=True, text=True, cwd=cwd)
    return (result.stdout + result.stderr).rstrip("\n")


def b_shell(args):
    if len(args) not in (1, 2, 3):
        raise VantaError("shell expects a command, an optional directory, "
                         "and an optional map of environment variables")
    cwd = display(args[1]) if len(args) >= 2 else None
    sub_env = None
    if len(args) == 3:
        if not isinstance(args[2], dict):
            raise VantaError("shell's third value must be a map of variables")
        sub_env = dict(os.environ)
        for key, value in args[2].items():
            sub_env[display(key)] = display(value)
    result = subprocess.run(display(args[0]), shell=True, capture_output=True,
                            text=True, cwd=cwd, env=sub_env)
    return {"output": (result.stdout + result.stderr).rstrip("\n"),
            "code": result.returncode}


def b_arguments(args):
    _need(args, 0, "arguments")
    return list(PROGRAM_ARGS)


def b_env(args):
    _need(args, 1, "env")
    return os.environ.get(display(args[0]), "")


def b_make_dir(args):
    _need(args, 1, "make_dir")
    os.makedirs(display(args[0]), exist_ok=True)
    return None


def b_remove_path(args):
    _need(args, 1, "remove_path")
    path = display(args[0])
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.remove(path)
    return None


def b_list_dir(args):
    _need(args, 1, "list_dir")
    try:
        return sorted(os.listdir(display(args[0])))
    except OSError as e:
        raise VantaError(f"could not list directory: {e}")


def b_path_exists(args):
    _need(args, 1, "path_exists")
    return os.path.exists(display(args[0]))


def b_copy_path(args):
    _need(args, 2, "copy_path")
    src, dst = display(args[0]), display(args[1])
    try:
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
            shutil.copy2(src, dst)
    except OSError as e:
        raise VantaError(f"could not copy {src}: {e}")
    return None


def b_to_json(args):
    _need(args, 1, "to_json")
    try:
        return json.dumps(args[0])
    except TypeError:
        raise VantaError("that value can't be turned into JSON")


def b_from_json(args):
    _need(args, 1, "from_json")
    try:
        return json.loads(display(args[0]))
    except ValueError:
        raise VantaError("that text is not valid JSON")


# ---- Vanta-in-Vanta: run Vanta code and capture its output ----------------
def b_run_vanta(args):
    """Run Vanta SOURCE in a fresh scope, capturing everything it `say`s.
    Returns {ok, output, error}. This is how Vanta can run Vanta (an editor,
    a REPL, an OS) entirely in-process - no subprocess, no external runtime."""
    if len(args) not in (1, 2):
        raise VantaError("run_vanta expects Vanta code (and an optional name)")
    code = display(args[0])
    buf = io.StringIO()
    env = Environment(GLOBAL_ENV)
    ok, err = True, ""
    try:
        with contextlib.redirect_stdout(buf):
            compile_block(parse_program(load_lines(code)))(env)
    except VantaError as e:
        ok, err = False, str(e)
    except RecursionError:
        ok, err = False, "this went too deep (runaway recursion?)"
    except Exception as e:
        ok, err = False, str(e)
    return {"ok": ok, "output": buf.getvalue(), "error": err}


def b_run_file(args):
    _need(args, 1, "run_file")
    path = display(args[0])
    try:
        with open(path, "r") as f:
            code = f.read()
    except OSError as e:
        raise VantaError(f"could not read file: {e}")
    return b_run_vanta([code])


def b_run_detached(args):
    """Launch a .va FILE in its own process (for programs that serve()/loop
    forever, which would otherwise block the caller)."""
    _need(args, 1, "run_detached")
    path = display(args[0])
    interp = os.path.abspath(sys.argv[0])
    proc = subprocess.Popen([sys.executable, interp, path])
    return proc.pid


# ---- filesystem completeness ---------------------------------------------
def b_append_file(args):
    _need(args, 2, "append_file")
    try:
        with open(display(args[0]), "a") as f:
            f.write(display(args[1]))
    except OSError as e:
        raise VantaError(f"could not append to file: {e}")
    return None


def b_write_bytes(args):
    _need(args, 2, "write_bytes")
    if not isinstance(args[1], list):
        raise VantaError("write_bytes needs a path and a list of 0-255 numbers")
    try:
        blob = bytes(int(x) & 0xFF for x in args[1])
        with open(display(args[0]), "wb") as f:
            f.write(blob)
    except OSError as e:
        raise VantaError(f"could not write file: {e}")
    return None


def b_is_dir(args):
    _need(args, 1, "is_dir")
    return os.path.isdir(display(args[0]))


def b_is_file(args):
    _need(args, 1, "is_file")
    return os.path.isfile(display(args[0]))


def b_file_size(args):
    _need(args, 1, "file_size")
    try:
        return os.path.getsize(display(args[0]))
    except OSError as e:
        raise VantaError(f"could not read file size: {e}")


def b_file_mtime(args):
    _need(args, 1, "file_mtime")
    try:
        return int(os.path.getmtime(display(args[0])))
    except OSError as e:
        raise VantaError(f"could not read file time: {e}")


def b_move_path(args):
    _need(args, 2, "move_path")
    src, dst = display(args[0]), display(args[1])
    try:
        parent = os.path.dirname(dst)
        if parent:
            os.makedirs(parent, exist_ok=True)
        shutil.move(src, dst)
    except OSError as e:
        raise VantaError(f"could not move {src}: {e}")
    return None


def b_path_join(args):
    if not args:
        return ""
    return os.path.join(*[display(a) for a in args])


def b_dirname(args):
    _need(args, 1, "dirname")
    return os.path.dirname(display(args[0]))


def b_basename(args):
    _need(args, 1, "basename")
    return os.path.basename(display(args[0]))


def b_extname(args):
    _need(args, 1, "extname")
    return os.path.splitext(display(args[0]))[1]


def b_home_dir(args):
    _need(args, 0, "home_dir")
    return os.path.expanduser("~")


# ---- encoding / hashing ---------------------------------------------------
def b_base64_encode(args):
    _need(args, 1, "base64_encode")
    return base64.b64encode(display(args[0]).encode("utf-8")).decode("ascii")


def b_base64_decode(args):
    _need(args, 1, "base64_decode")
    try:
        return base64.b64decode(display(args[0])).decode("utf-8", "replace")
    except Exception as e:
        raise VantaError(f"that is not valid base64: {e}")


def b_base64_to_bytes(args):
    # base64 text -> a list of 0-255 numbers (binary-safe: for PNGs etc.)
    _need(args, 1, "base64_to_bytes")
    try:
        return [b for b in base64.b64decode(display(args[0]))]
    except Exception as e:
        raise VantaError(f"that is not valid base64: {e}")


def b_bytes_to_base64(args):
    # a list of 0-255 numbers -> base64 text (e.g. to build a data: URI)
    _need(args, 1, "bytes_to_base64")
    if not isinstance(args[0], list):
        raise VantaError("bytes_to_base64 needs a list of 0-255 numbers")
    blob = bytes(int(x) & 0xFF for x in args[0])
    return base64.b64encode(blob).decode("ascii")


def b_hex_encode(args):
    _need(args, 1, "hex_encode")
    return display(args[0]).encode("utf-8").hex()


def b_hex_decode(args):
    _need(args, 1, "hex_decode")
    try:
        return bytes.fromhex(display(args[0])).decode("utf-8", "replace")
    except Exception as e:
        raise VantaError(f"that is not valid hex: {e}")


def b_sha256(args):
    _need(args, 1, "sha256")
    return hashlib.sha256(display(args[0]).encode("utf-8")).hexdigest()


def b_md5(args):
    _need(args, 1, "md5")
    return hashlib.md5(display(args[0]).encode("utf-8")).hexdigest()


def b_now_ms(args):
    _need(args, 0, "now_ms")
    return int(time.time() * 1000)


# ---- platform / portability ----------------------------------------------
def b_os_name(args):
    _need(args, 0, "os_name")
    p = sys.platform
    if p == "darwin":
        return "mac"
    if p.startswith("linux"):
        return "linux"
    if p.startswith("win") or os.name == "nt":
        return "windows"
    return p


def b_open_url(args):
    """Open a URL (or file) in the default browser - desktop OR phone (Android/Termux,
    iOS/iSH). Always prints the address too, so it's tappable when no opener exists."""
    _need(args, 1, "open_url")
    target = display(args[0])
    is_url = target.startswith(("http://", "https://"))
    # Android / Termux: webbrowser can't reach the phone browser; use termux-open(-url)
    if os.environ.get("TERMUX_VERSION") or "com.termux" in (os.environ.get("PREFIX") or ""):
        tool = (shutil.which("termux-open-url") if is_url else None) or shutil.which("termux-open")
        if tool:
            try:
                subprocess.Popen([tool, target],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print("opening " + target + " ...")
                return None
            except Exception:
                pass
        print("open this on your phone:  " + target +
              "   (for auto-open: pkg install termux-api)")
        return None
    # Desktop / other: honor $BROWSER (e.g. a chrome --app window), else the default
    import webbrowser
    try:
        webbrowser.open(target)
    except Exception:
        print("open this in your browser:  " + target)
    return None


def b_interpreter(args):
    _need(args, 0, "interpreter")
    return os.path.abspath(sys.argv[0])


# ---- bytes and bitwise (needed for emulators and low-level work) ---------

def b_read_bytes(args):
    _need(args, 1, "read_bytes")
    try:
        with open(display(args[0]), "rb") as f:
            return list(f.read())          # a list of whole numbers 0..255
    except OSError as e:
        raise VantaError(f"could not read file: {e}")


def b_read_binary(args):
    """read_binary(path) -> bytes: a whole file as a compact byte array (fast for big files like game data)."""
    _need(args, 1, "read_binary")
    try:
        with open(display(args[0]), "rb") as f:
            return bytearray(f.read())
    except OSError as e:
        raise VantaError(f"could not read file: {e}")


def b_bytes(args):
    """bytes(n) -> n zero bytes; bytes(list) -> the list's numbers as bytes; bytes(text) -> its UTF-8 bytes."""
    _need(args, 1, "bytes")
    v = args[0]
    if type(v) is int:
        if v < 0:
            raise VantaError("bytes needs a size of 0 or more")
        return bytearray(v)
    if isinstance(v, str):
        return bytearray(v.encode("utf-8"))
    if isinstance(v, (list, bytearray)):
        try:
            return bytearray(v)
        except (ValueError, TypeError):
            raise VantaError("bytes needs numbers from 0 to 255")
    raise VantaError("bytes takes a size, a list of numbers, or text")


def _byte_arg(args, name, width):
    data, off = args[0], args[1]
    if not isinstance(data, (bytearray, list)):
        raise VantaError(f"{name} reads from bytes")
    if type(off) is not int or off < 0 or off + width > len(data):
        raise VantaError(f"{name}: position {display(off)} is outside the {len(data)} bytes")
    return data, off


def _reader(width, signed):
    def read(args):
        name = ("s" if signed else "u") + str(width * 8)
        _need(args, 2, name)
        data, off = _byte_arg(args, name, width)
        return int.from_bytes(bytes(data[off:off + width]), "little", signed=signed)
    return read


def _writer(width):
    def write(args):
        name = "put_u" + str(width * 8)
        _need(args, 3, name)
        data, off = _byte_arg(args, name, width)
        value = args[2]
        if type(value) is not int:
            raise VantaError(f"{name} writes whole numbers")
        data[off:off + width] = (value & ((1 << (8 * width)) - 1)).to_bytes(width, "little")
        return None
    return write


def b_write_binary(args):
    _need(args, 2, "write_binary")
    try:
        with open(display(args[0]), "wb") as f:
            f.write(bytes(args[1]))
    except (OSError, ValueError, TypeError) as e:
        raise VantaError(f"could not write file: {e}")
    return None


def b_is_bytes(args):
    _need(args, 1, "is_bytes")
    return isinstance(args[0], bytearray)


def b_band(args):
    _need(args, 2, "band")
    return int_arg(args[0], "band") & int_arg(args[1], "band")


def b_bor(args):
    _need(args, 2, "bor")
    return int_arg(args[0], "bor") | int_arg(args[1], "bor")


def b_bxor(args):
    _need(args, 2, "bxor")
    return int_arg(args[0], "bxor") ^ int_arg(args[1], "bxor")


def b_bnot(args):
    _need(args, 2, "bnot")
    value, bits = int_arg(args[0], "bnot"), int_arg(args[1], "bnot")
    return (~value) & ((1 << bits) - 1)


def b_shift_left(args):
    _need(args, 2, "shift_left")
    return int_arg(args[0], "shift_left") << int_arg(args[1], "shift_left")


def b_shift_right(args):
    _need(args, 2, "shift_right")
    return int_arg(args[0], "shift_right") >> int_arg(args[1], "shift_right")


# ---- type checks ---------------------------------------------------------

def b_is_a(args):
    _need(args, 2, "is_a")
    if not isinstance(args[1], VantaType):
        raise VantaError("is_a's second value must be a type")
    return is_instance_of(args[0], args[1])


# ---- regular expressions -------------------------------------------------

def b_matches(args):
    _need(args, 2, "matches")
    try:
        return re.search(display(args[1]), display(args[0])) is not None
    except re.error as e:
        raise VantaError(f"that pattern is not valid: {e}")


def b_find_all(args):
    _need(args, 2, "find_all")
    try:
        return [m.group(0) for m in re.finditer(display(args[1]), display(args[0]))]
    except re.error as e:
        raise VantaError(f"that pattern is not valid: {e}")


def b_replace_all(args):
    _need(args, 3, "replace_all")
    try:
        return re.sub(display(args[1]), display(args[2]), display(args[0]))
    except (re.error, IndexError) as e:
        raise VantaError(f"that pattern is not valid: {e}")


# ---- dates & time --------------------------------------------------------

def b_today(args):
    _need(args, 0, "today")
    return time.strftime("%Y-%m-%d")


def b_clock(args):
    _need(args, 0, "clock")
    return time.strftime("%H:%M:%S")


# ---- the web: HTTP client, HTTP server, and friends ----------------------
# These make Vanta a real full-stack language: talk to APIs, and serve web
# pages / JSON like Node, Flask, or a Go/Rust server would. Imports are lazy
# so loading vanta.py never needs a network stack (e.g. in the browser).

def _headers_map(value, name):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise VantaError(f"{name}'s headers must be a map")
    return {display(k): display(v) for k, v in value.items()}


def _decode_http_body(raw, http_headers):
    # Undo gzip/deflate if the server compressed the reply, then decode text
    # using the charset the server declared (falling back to UTF-8). This lets
    # http_get read real-world pages that aren't plain UTF-8.
    import gzip
    import zlib
    enc = (http_headers.get("Content-Encoding") or "").lower()
    if "gzip" in enc:
        try:
            raw = gzip.decompress(raw)
        except Exception:
            pass
    elif "deflate" in enc:
        try:
            raw = zlib.decompress(raw)
        except Exception:
            try:
                raw = zlib.decompress(raw, -zlib.MAX_WBITS)
            except Exception:
                pass
    charset = "utf-8"
    ctype = (http_headers.get("Content-Type") or "").lower()
    if "charset=" in ctype:
        cand = ctype.split("charset=")[-1].split(";")[0].strip()
        if cand:
            charset = cand
    try:
        return raw.decode(charset, "replace")
    except LookupError:
        return raw.decode("utf-8", "replace")


def _http_request(method, url, body, headers):
    import urllib.request
    import urllib.error
    hdrs = _headers_map(headers, "http")
    data = None
    if body is not None and body != "":
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        else:
            data = display(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = _decode_http_body(resp.read(), resp.headers)
            return {"status": resp.status, "body": text,
                    "headers": {k: v for k, v in resp.headers.items()}}
    except urllib.error.HTTPError as e:
        text = _decode_http_body(e.read(), e.headers or {})
        return {"status": e.code, "body": text,
                "headers": {k: v for k, v in (e.headers or {}).items()}}
    except urllib.error.URLError as e:
        raise VantaError(f"could not reach {url}: {getattr(e, 'reason', e)}")


def b_http_get(args):
    if len(args) not in (1, 2):
        raise VantaError("http_get expects a url (and an optional headers map)")
    return _http_request("GET", display(args[0]), None,
                         args[1] if len(args) == 2 else None)


def b_http_post(args):
    if len(args) not in (2, 3):
        raise VantaError("http_post expects a url and a body "
                         "(and an optional headers map)")
    return _http_request("POST", display(args[0]), args[1],
                         args[2] if len(args) == 3 else None)


def b_http_request(args):
    if len(args) not in (2, 3, 4):
        raise VantaError("http_request expects a method, a url, an optional "
                         "body, and an optional headers map")
    return _http_request(display(args[0]).upper(), display(args[1]),
                         args[2] if len(args) >= 3 else None,
                         args[3] if len(args) == 4 else None)


def b_download(args):
    """download(url, dest [, headers]) -> map. Binary-safe: writes the raw response
    straight to a file (no text decoding), for images / PDFs / any binary."""
    if len(args) not in (2, 3):
        raise VantaError("download expects a url, a destination path "
                         "(and an optional headers map)")
    import urllib.request
    import urllib.error
    url = display(args[0])
    dest = os.path.expanduser(display(args[1]))
    hdrs = _headers_map(args[2] if len(args) == 3 else None, "download")
    req = urllib.request.Request(url, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        return {"ok": False, "status": e.code, "bytes": 0, "path": dest,
                "error": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return {"ok": False, "status": 0, "bytes": 0, "path": dest,
                "error": f"could not reach {url}: {getattr(e, 'reason', e)}"}
    try:
        with open(dest, "wb") as f:
            f.write(raw)
    except OSError as e:
        raise VantaError(f"could not write {dest}: {e}")
    return {"ok": True, "status": status, "bytes": len(raw), "path": dest, "error": ""}


def _find_chrome():
    cands = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
             "/Applications/Chromium.app/Contents/MacOS/Chromium",
             shutil.which("google-chrome"), shutil.which("chromium"),
             shutil.which("chromium-browser"), shutil.which("chrome")]
    for p in cands:
        if p and os.path.exists(p):
            return p
    return None


def b_render_html(args):
    """render_html(input, out [, width, height [, mode]]) -> map. Rasterizes an HTML
    file path (or http/file URL) with headless Chrome. mode "png" (default) -> a
    screenshot at width x height; mode "pdf" -> a printed PDF. Returns {ok, path, bytes}."""
    if len(args) < 2 or len(args) > 5:
        raise VantaError("render_html expects input, out "
                         "(and optional width, height, mode)")
    src = display(args[0])
    out = os.path.expanduser(display(args[1]))
    width = int_arg(args[2], "render_html") if len(args) >= 3 else 750
    height = int_arg(args[3], "render_html") if len(args) >= 4 else 1050
    mode = (display(args[4]) if len(args) == 5 else "png").lower()
    chrome = _find_chrome()
    if not chrome:
        return {"ok": False, "path": out, "bytes": 0,
                "error": "Chrome/Chromium not found - install Google Chrome"}
    url = src if "://" in src else "file://" + os.path.abspath(os.path.expanduser(src))
    base = [chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
            "--hide-scrollbars", "--force-device-scale-factor=1"]
    if mode == "pdf":
        cmd = base + ["--no-pdf-header-footer", f"--print-to-pdf={out}", url]
    else:
        cmd = base + [f"--screenshot={out}", f"--window-size={width},{height}", url]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=90)
    except Exception as e:
        return {"ok": False, "path": out, "bytes": 0, "error": str(e)}
    ok = os.path.exists(out) and os.path.getsize(out) > 0
    return {"ok": ok, "path": out,
            "bytes": (os.path.getsize(out) if ok else 0),
            "error": "" if ok else "Chrome produced no output"}


def b_serve(args):
    if len(args) not in (1, 2):
        raise VantaError("serve expects a port and a handler function "
                         "(or just a handler — port defaults to 8080)")
    if len(args) == 1:
        port, handler = 8080, args[0]
    else:
        port, handler = int_arg(args[0], "serve"), args[1]
    if not isinstance(handler, (Function, Builtin, BoundMethod)):
        raise VantaError("serve's handler must be a function that takes a "
                         "request map and gives back a page (text or a map)")

    import urllib.parse
    import threading
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

    # Slow clients get their own thread (so one can't block the whole server),
    # but the Vanta handler itself runs under a lock — the interpreter shares
    # one global scope, so handlers run one at a time and never race.
    handler_lock = threading.Lock()

    class VantaHandler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _reply(self, status, body, ctype, extra):
            blob = body if isinstance(body, (bytes, bytearray)) else body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(blob)))
            for k, v in extra.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(blob)

        def _handle(self, method):
            parsed = urllib.parse.urlparse(self.path)
            query = {k: (v[0] if len(v) == 1 else v)
                     for k, v in urllib.parse.parse_qs(parsed.query).items()}
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            request = {"method": method, "path": parsed.path, "query": query,
                       "headers": {k: v for k, v in self.headers.items()},
                       "body": body}
            try:
                with handler_lock:
                    result = apply_callable(handler, [request])
            except VantaError as e:
                self._reply(500, f"Vanta error: {e}", "text/plain; charset=utf-8", {})
                return
            status, ctype, extra = 200, "text/html; charset=utf-8", {}
            if isinstance(result, dict):
                status = int(result.get("status", 200))
                hh = result.get("headers")
                if isinstance(hh, dict):
                    extra = {display(k): display(v) for k, v in hh.items()}
                # binary: stream a file straight off disk (images, PDFs, downloads)
                if "file" in result:
                    fp = os.path.expanduser(display(result["file"]))
                    import mimetypes
                    ctype = display(result.get("type", result.get(
                        "content_type", mimetypes.guess_type(fp)[0] or "application/octet-stream")))
                    if result.get("download"):
                        extra.setdefault("Content-Disposition",
                                         'attachment; filename="%s"' % os.path.basename(fp))
                    try:
                        with open(fp, "rb") as f:
                            data = f.read()
                    except OSError:
                        self._reply(404, "not found: " + fp, "text/plain; charset=utf-8", {})
                        return
                    self._reply(status, data, ctype, extra)
                    return
                # binary: an explicit list of 0-255 byte numbers
                if isinstance(result.get("bytes"), list):
                    data = bytes(int(x) & 0xFF for x in result["bytes"])
                    ctype = display(result.get("type", result.get("content_type",
                                                                   "application/octet-stream")))
                    self._reply(status, data, ctype, extra)
                    return
                raw = result.get("body", "")
                if isinstance(raw, (dict, list)):
                    text = json.dumps(raw)
                    ctype = "application/json"
                else:
                    text = display(raw)
                if "type" in result or "content_type" in result:
                    ctype = display(result.get("type", result.get("content_type")))
            else:
                text = display(result)
            self._reply(status, text, ctype, extra)

        def do_GET(self):     self._handle("GET")
        def do_POST(self):    self._handle("POST")
        def do_PUT(self):     self._handle("PUT")
        def do_DELETE(self):  self._handle("DELETE")
        def do_PATCH(self):   self._handle("PATCH")
        def do_HEAD(self):    self._handle("HEAD")

    server = ThreadingHTTPServer(("", port), VantaHandler)
    server.daemon_threads = True
    print(f"Vanta server running on http://localhost:{port}  "
          f"(press Stop / Ctrl-C to quit)")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("Server stopped.")
    return None


def b_sleep(args):
    _need(args, 1, "sleep")
    secs = args[0]
    if isinstance(secs, bool) or not isinstance(secs, (int, float)):
        raise VantaError("sleep expects a number of seconds")
    time.sleep(secs)
    return None


def b_url_encode(args):
    _need(args, 1, "url_encode")
    import urllib.parse
    return urllib.parse.quote(display(args[0]), safe="")


def b_url_decode(args):
    _need(args, 1, "url_decode")
    import urllib.parse
    return urllib.parse.unquote(display(args[0]))


def b_html_escape(args):
    _need(args, 1, "html_escape")
    s = display(args[0])
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "&#39;"))


def b_typeof(args):
    _need(args, 1, "typeof")
    v = args[0]
    if isinstance(v, bool): return "bool"
    if isinstance(v, (int, float)): return "number"
    if isinstance(v, str): return "text"
    if isinstance(v, list): return "list"
    if isinstance(v, dict): return "map"
    if isinstance(v, bytearray): return "bytes"
    return "nothing"


# ===========================================================================
# GAME-CHEAT / MEMORY TOOLKIT
# Read & write another running program's memory the way a trainer or Cheat
# Engine does - find the health/ammo/gold value, then write or freeze it.
# Cross-platform: macOS (mach), Linux (/proc/<pid>/mem), Windows (kernel32).
# Your OWN process always works; editing ANOTHER process needs privileges
# (sudo / Administrator), and on macOS System Integrity Protection may block
# it. For single-player / offline games - online games have anti-cheat and
# editing them breaks their terms of service.
# ===========================================================================
_MEM_HANDLES = {}
_FREEZES = {}
_FREEZE_ID = [0]
_SIZES = {"byte": 1, "int": 4, "float": 4, "long": 8, "double": 8}


def _mem_proc_list():
    out = []
    try:
        if sys.platform.startswith("win"):
            r = subprocess.run(["tasklist", "/fo", "csv", "/nh"],
                               capture_output=True, text=True, timeout=15)
            import csv
            for row in csv.reader(io.StringIO(r.stdout)):
                if len(row) >= 2 and row[1].isdigit():
                    out.append((int(row[1]), row[0]))
        else:
            r = subprocess.run(["ps", "-axo", "pid=,comm="],
                               capture_output=True, text=True, timeout=15)
            for ln in r.stdout.splitlines():
                ln = ln.strip()
                if not ln:
                    continue
                a, _, b = ln.partition(" ")
                if a.isdigit():
                    out.append((int(a), os.path.basename(b.strip())))
    except Exception:
        pass
    return out


def _addr(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise VantaError("a memory address must be a number")
    return int(v)


def _mac_task(pid):
    c = ctypes.CDLL(None, use_errno=True)
    c.mach_task_self.restype = ctypes.c_uint
    if pid == os.getpid():
        return c.mach_task_self()
    task = ctypes.c_uint(0)
    c.task_for_pid.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)]
    kr = c.task_for_pid(c.mach_task_self(), pid, ctypes.byref(task))
    if kr != 0:
        raise VantaError("can't attach to pid %d (mach error %d). Editing another app "
                         "needs `sudo`, and macOS SIP may still block it; your own "
                         "process works without sudo." % (pid, kr))
    return task.value


def _open(pid):
    if pid in _MEM_HANDLES:
        return _MEM_HANDLES[pid]
    if sys.platform == "darwin":
        h = ("darwin", _mac_task(pid))
    elif sys.platform.startswith("linux"):
        h = ("linux", pid)
    elif sys.platform.startswith("win"):
        k = ctypes.windll.kernel32
        hp = k.OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x0400, False, pid)
        if not hp:
            raise VantaError("OpenProcess failed for pid %d (run as Administrator)." % pid)
        h = ("win", hp)
    else:
        raise VantaError("memory editing isn't supported on this platform")
    _MEM_HANDLES[pid] = h
    return h


def _mem_read_raw(pid, addr, size):
    kind, h = _open(pid)
    if kind == "darwin":
        c = ctypes.CDLL(None, use_errno=True)
        buf = (ctypes.c_char * size)()
        out = ctypes.c_ulonglong(0)
        f = c.mach_vm_read_overwrite
        f.restype = ctypes.c_int
        f.argtypes = [ctypes.c_uint, ctypes.c_ulonglong, ctypes.c_ulonglong,
                      ctypes.c_ulonglong, ctypes.POINTER(ctypes.c_ulonglong)]
        if f(h, addr, size, ctypes.addressof(buf), ctypes.byref(out)) != 0:
            return None
        return bytes(buf[:out.value])
    if kind == "linux":
        try:
            fd = os.open("/proc/%d/mem" % pid, os.O_RDONLY)
            try:
                return os.pread(fd, size, addr)
            finally:
                os.close(fd)
        except Exception:
            return None
    if kind == "win":
        k = ctypes.windll.kernel32
        buf = (ctypes.c_char * size)()
        n = ctypes.c_size_t(0)
        if not k.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, size, ctypes.byref(n)):
            return None
        return bytes(buf[:n.value])
    return None


def _mem_write_raw(pid, addr, data):
    kind, h = _open(pid)
    if kind == "darwin":
        c = ctypes.CDLL(None, use_errno=True)
        f = c.mach_vm_write
        f.restype = ctypes.c_int
        f.argtypes = [ctypes.c_uint, ctypes.c_ulonglong, ctypes.c_ulonglong, ctypes.c_uint]
        buf = (ctypes.c_char * len(data)).from_buffer_copy(data)
        return f(h, addr, ctypes.addressof(buf), len(data)) == 0
    if kind == "linux":
        try:
            fd = os.open("/proc/%d/mem" % pid, os.O_WRONLY)
            try:
                os.pwrite(fd, data, addr)
                return True
            finally:
                os.close(fd)
        except Exception:
            return False
    if kind == "win":
        k = ctypes.windll.kernel32
        buf = (ctypes.c_char * len(data)).from_buffer_copy(data)
        n = ctypes.c_size_t(0)
        return bool(k.WriteProcessMemory(h, ctypes.c_void_p(addr), buf, len(data), ctypes.byref(n)))
    return False


def _mem_regions(pid):
    kind, h = _open(pid)
    regs = []
    if kind == "darwin":
        c = ctypes.CDLL(None, use_errno=True)
        f = c.mach_vm_region
        f.restype = ctypes.c_int
        f.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_ulonglong),
                      ctypes.POINTER(ctypes.c_ulonglong), ctypes.c_int, ctypes.c_void_p,
                      ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        info = (ctypes.c_int * 16)()
        addr = 0
        for _ in range(200000):
            a = ctypes.c_ulonglong(addr); s = ctypes.c_ulonglong(0)
            cnt = ctypes.c_uint(16); obj = ctypes.c_uint(0)
            if f(h, ctypes.byref(a), ctypes.byref(s), 9, ctypes.cast(info, ctypes.c_void_p),
                 ctypes.byref(cnt), ctypes.byref(obj)) != 0:
                break
            if info[0] & 1:                       # VM_PROT_READ
                regs.append((a.value, s.value))
            nxt = a.value + s.value
            if nxt <= addr:
                break
            addr = nxt
    elif kind == "linux":
        try:
            for ln in open("/proc/%d/maps" % pid):
                p = ln.split()
                if len(p) >= 2 and "r" in p[1]:
                    s, e = p[0].split("-")
                    regs.append((int(s, 16), int(e, 16) - int(s, 16)))
        except Exception:
            pass
    elif kind == "win":
        k = ctypes.windll.kernel32

        class MBI(ctypes.Structure):
            _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                        ("AllocationProtect", ctypes.c_ulong), ("RegionSize", ctypes.c_size_t),
                        ("State", ctypes.c_ulong), ("Protect", ctypes.c_ulong), ("Type", ctypes.c_ulong)]
        addr = 0
        mbi = MBI()
        while k.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
            if mbi.State == 0x1000 and (mbi.Protect & 0xEE):
                regs.append((addr, mbi.RegionSize))
            addr += mbi.RegionSize or 0x1000
            if addr > 0x7FFFFFFFFFFF:
                break
    return regs


def _pack(value, kind):
    if kind == "float":  return _struct.pack("<f", float(value))
    if kind == "double": return _struct.pack("<d", float(value))
    if kind == "byte":   return bytes([int(value) & 0xFF])
    if kind == "long":   return _struct.pack("<q", int(value))
    return _struct.pack("<i", int(value))


def _unpack(data, kind):
    if kind == "float":  return _struct.unpack("<f", data)[0]
    if kind == "double": return _struct.unpack("<d", data)[0]
    if kind == "byte":   return data[0]
    if kind == "long":   return _struct.unpack("<q", data)[0]
    return _struct.unpack("<i", data)[0]


def _mem_kind(args, i, name):
    return display(args[i]) if len(args) > i else "int"


def b_process_list(args):
    _need(args, 0, "process_list")
    return [{"pid": p, "name": n} for (p, n) in _mem_proc_list()]


def b_find_pid(args):
    _need(args, 1, "find_pid")
    q = display(args[0]).lower()
    for (p, n) in _mem_proc_list():
        if q in n.lower():
            return p
    return 0


def b_read_int(args):
    if len(args) not in (2, 3):
        raise VantaError("read_int expects a pid and an address (+ optional kind)")
    kind = _mem_kind(args, 2, "read_int")
    size = _SIZES.get(kind, 4)
    data = _mem_read_raw(int_arg(args[0], "read_int"), _addr(args[1]), size)
    if data is None or len(data) < size:
        raise VantaError("could not read that address (wrong pid/address, or needs sudo)")
    return _unpack(data, kind)


def b_read_float(args):
    if len(args) != 2:
        raise VantaError("read_float expects a pid and an address")
    return b_read_int([args[0], args[1], "float"])


def b_write_int(args):
    if len(args) not in (3, 4):
        raise VantaError("write_int expects a pid, an address, and a value (+ optional kind)")
    kind = _mem_kind(args, 3, "write_int")
    return _mem_write_raw(int_arg(args[0], "write_int"), _addr(args[1]), _pack(args[2], kind))


def b_write_float(args):
    if len(args) != 3:
        raise VantaError("write_float expects a pid, an address, and a value")
    return b_write_int([args[0], args[1], args[2], "float"])


def b_read_mem(args):
    _need(args, 3, "read_mem")
    data = _mem_read_raw(int_arg(args[0], "read_mem"), _addr(args[1]),
                         int_arg(args[2], "read_mem"))
    return list(data) if data is not None else []


def b_write_mem(args):
    _need(args, 3, "write_mem")
    if not isinstance(args[2], list):
        raise VantaError("write_mem needs a pid, an address, and a list of 0-255 bytes")
    return _mem_write_raw(int_arg(args[0], "write_mem"), _addr(args[1]),
                          bytes(int(x) & 0xFF for x in args[2]))


def b_mem_regions(args):
    _need(args, 1, "mem_regions")
    return [{"address": s, "size": sz}
            for (s, sz) in _mem_regions(int_arg(args[0], "mem_regions"))]


def b_mem_scan(args):
    if len(args) not in (2, 3):
        raise VantaError("mem_scan expects a pid and a value (+ optional kind like \"float\")")
    pid = int_arg(args[0], "mem_scan")
    kind = _mem_kind(args, 2, "mem_scan")
    needle = _pack(args[1], kind)
    hits = []
    for (start, size) in _mem_regions(pid):
        if size > 64 * 1024 * 1024:               # skip huge mappings to stay responsive
            continue
        data = _mem_read_raw(pid, start, size)
        if not data:
            continue
        off = data.find(needle)
        while off != -1:
            hits.append(start + off)
            if len(hits) >= 200000:
                return hits
            off = data.find(needle, off + 1)
    return hits


def b_mem_next(args):
    if len(args) not in (3, 4):
        raise VantaError("mem_next expects a pid, the previous addresses, and the new value")
    if not isinstance(args[1], list):
        raise VantaError("mem_next needs the list of addresses from a previous mem_scan")
    pid = int_arg(args[0], "mem_next")
    kind = _mem_kind(args, 3, "mem_next")
    target = _pack(args[2], kind)
    n = len(target)
    out = []
    for a in args[1]:
        d = _mem_read_raw(pid, _addr(a), n)
        if d == target:
            out.append(_addr(a))
    return out


def _freeze_loop(pid, addr, data, stop):
    while not stop.is_set():
        _mem_write_raw(pid, addr, data)
        stop.wait(0.03)


def b_freeze(args):
    if len(args) not in (3, 4):
        raise VantaError("freeze expects a pid, an address, and a value (+ optional kind)")
    pid = int_arg(args[0], "freeze")
    addr = _addr(args[1])
    kind = _mem_kind(args, 3, "freeze")
    data = _pack(args[2], kind)
    stop = _threading.Event()
    t = _threading.Thread(target=_freeze_loop, args=(pid, addr, data, stop), daemon=True)
    t.start()
    _FREEZE_ID[0] += 1
    fid = _FREEZE_ID[0]
    _FREEZES[fid] = stop
    return fid


def b_unfreeze(args):
    _need(args, 1, "unfreeze")
    fid = int_arg(args[0], "unfreeze")
    if fid in _FREEZES:
        _FREEZES[fid].set()
        del _FREEZES[fid]
        return True
    return False


def b_my_pid(args):
    _need(args, 0, "my_pid")
    return os.getpid()


# ===========================================================================
# INPUT TOOLKIT — press keys, type, move/click the mouse, read whether a key is
# held, and register GLOBAL HOTKEYS (so a trainer can toggle a cheat with F1).
# macOS (CoreGraphics), Windows (user32), Linux (xdotool). On macOS this needs
# Accessibility / Input-Monitoring permission for your terminal the first time.
# ===========================================================================
_HOTKEYS = {}
_HOTKEY_ID = [0]
_CG = [None]

_MAC_KEYS = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    "`": 50, "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
    "backspace": 51, "escape": 53, "esc": 53, "cmd": 55, "command": 55, "shift": 56,
    "capslock": 57, "option": 58, "alt": 58, "control": 59, "ctrl": 59,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "left": 123, "right": 124, "down": 125, "up": 126,
}

_WIN_KEYS = {
    "space": 0x20, "enter": 0x0D, "return": 0x0D, "tab": 0x09, "escape": 0x1B,
    "esc": 0x1B, "backspace": 0x08, "delete": 0x2E, "shift": 0x10, "ctrl": 0x11,
    "control": 0x11, "alt": 0x12, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
}
for _i in range(1, 13):
    _WIN_KEYS["f%d" % _i] = 0x70 + (_i - 1)
for _ch in "abcdefghijklmnopqrstuvwxyz":
    _WIN_KEYS[_ch] = ord(_ch.upper())
for _ch in "0123456789":
    _WIN_KEYS[_ch] = ord(_ch)


def _mac_cg():
    if _CG[0] is None:
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")

        class CGPoint(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
        cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventKeyboardSetUnicodeString.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_uint16)]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventSourceKeyState.restype = ctypes.c_bool
        cg.CGEventSourceKeyState.argtypes = [ctypes.c_int32, ctypes.c_uint16]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
        cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]
        cg.CGEventCreate.restype = ctypes.c_void_p
        cg.CGEventCreate.argtypes = [ctypes.c_void_p]
        cg.CGEventGetLocation.restype = CGPoint
        cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
        _CG[0] = (cg, CGPoint, ctypes.CDLL(None))
    return _CG[0]


def _keycode(name):
    nm = display(name).lower()
    if sys.platform == "darwin":
        if nm not in _MAC_KEYS:
            raise VantaError("unknown key %r" % name)
        return _MAC_KEYS[nm]
    if sys.platform.startswith("win"):
        if nm not in _WIN_KEYS:
            raise VantaError("unknown key %r" % name)
        return _WIN_KEYS[nm]
    return nm   # linux: pass the name to xdotool


def _send_key(name, down):
    if sys.platform == "darwin":
        cg, _pt, cf = _mac_cg()
        ev = cg.CGEventCreateKeyboardEvent(None, _keycode(name), down)
        cg.CGEventPost(0, ev)
        cf.CFRelease(ev)
        return True
    if sys.platform.startswith("win"):
        flags = 0 if down else 2
        ctypes.windll.user32.keybd_event(_keycode(name), 0, flags, 0)
        return True
    if not down:
        return True
    if shutil.which("xdotool"):
        subprocess.run(["xdotool", "key", display(name)], timeout=5)
        return True
    raise VantaError("key input on Linux needs xdotool (apt install xdotool)")


def _key_state(name):
    if sys.platform == "darwin":
        cg, _pt, _cf = _mac_cg()
        return bool(cg.CGEventSourceKeyState(1, _keycode(name)))   # HID system state
    if sys.platform.startswith("win"):
        return bool(ctypes.windll.user32.GetAsyncKeyState(_keycode(name)) & 0x8000)
    return False


def _type_text(text):
    if sys.platform == "darwin":
        cg, _pt, cf = _mac_cg()
        for ch in text:
            u16 = ch.encode("utf-16-le")
            n = len(u16) // 2
            arr = (ctypes.c_uint16 * n).from_buffer_copy(u16)
            for d in (True, False):
                ev = cg.CGEventCreateKeyboardEvent(None, 0, d)
                cg.CGEventKeyboardSetUnicodeString(ev, n, arr)
                cg.CGEventPost(0, ev)
                cf.CFRelease(ev)
        return True
    if sys.platform.startswith("win"):
        u = ctypes.windll.user32
        for ch in text:
            code = ord(ch)
            u.keybd_event(0, code, 0x4, 0)   # KEYEVENTF_UNICODE down
            u.keybd_event(0, code, 0x4 | 0x2, 0)
        return True
    if shutil.which("xdotool"):
        subprocess.run(["xdotool", "type", text], timeout=10)
        return True
    raise VantaError("typing on Linux needs xdotool")


def _mouse_move(x, y):
    if sys.platform == "darwin":
        cg, CGPoint, _cf = _mac_cg()
        cg.CGWarpMouseCursorPosition(CGPoint(float(x), float(y)))
        return True
    if sys.platform.startswith("win"):
        ctypes.windll.user32.SetCursorPos(int(x), int(y))
        return True
    if shutil.which("xdotool"):
        subprocess.run(["xdotool", "mousemove", str(int(x)), str(int(y))], timeout=5)
        return True
    raise VantaError("mouse on Linux needs xdotool")


def _mouse_click(button):
    b = display(button).lower() if button is not None else "left"
    if sys.platform == "darwin":
        cg, CGPoint, cf = _mac_cg()
        loc = cg.CGEventGetLocation(cg.CGEventCreate(None))
        down, up, bt = (1, 2, 0) if b != "right" else (3, 4, 1)
        for ty in (down, up):
            ev = cg.CGEventCreateMouseEvent(None, ty, loc, bt)
            cg.CGEventPost(0, ev)
            cf.CFRelease(ev)
        return True
    if sys.platform.startswith("win"):
        u = ctypes.windll.user32
        dn, upf = (0x0002, 0x0004) if b != "right" else (0x0008, 0x0010)
        u.mouse_event(dn, 0, 0, 0, 0)
        u.mouse_event(upf, 0, 0, 0, 0)
        return True
    if shutil.which("xdotool"):
        subprocess.run(["xdotool", "click", "3" if b == "right" else "1"], timeout=5)
        return True
    raise VantaError("mouse on Linux needs xdotool")


def _mouse_pos():
    if sys.platform == "darwin":
        cg, _pt, _cf = _mac_cg()
        p = cg.CGEventGetLocation(cg.CGEventCreate(None))
        return {"x": p.x, "y": p.y}
    if sys.platform.startswith("win"):
        class PT(ctypes.Structure):
            _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
        pt = PT()
        ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))
        return {"x": pt.x, "y": pt.y}
    if shutil.which("xdotool"):
        r = subprocess.run(["xdotool", "getmouselocation"], capture_output=True, text=True, timeout=5)
        x = y = 0
        for tok in r.stdout.split():
            if tok.startswith("x:"): x = int(tok[2:])
            if tok.startswith("y:"): y = int(tok[2:])
        return {"x": x, "y": y}
    return {"x": 0, "y": 0}


def b_press_key(args):
    _need(args, 1, "press_key")
    _send_key(args[0], True)
    time.sleep(0.01)
    _send_key(args[0], False)
    return True

def b_key_down(args):
    _need(args, 1, "key_down")
    return _send_key(args[0], True)

def b_key_up(args):
    _need(args, 1, "key_up")
    return _send_key(args[0], False)

def b_type_text(args):
    _need(args, 1, "type_text")
    return _type_text(display(args[0]))

def b_key_pressed(args):
    _need(args, 1, "key_pressed")
    return _key_state(args[0])

def b_wait_key(args):
    if len(args) not in (1, 2):
        raise VantaError("wait_key expects a key (and an optional timeout in seconds)")
    name = args[0]
    deadline = None
    if len(args) == 2:
        deadline = time.time() + num_arg(args[1], "wait_key")
    while _key_state(name):                 # let a held key release first
        time.sleep(0.01)
        if deadline and time.time() > deadline:
            return False
    while not _key_state(name):              # then wait for a fresh press
        time.sleep(0.01)
        if deadline and time.time() > deadline:
            return False
    return True

def b_mouse_move(args):
    _need(args, 2, "mouse_move")
    return _mouse_move(num_arg(args[0], "mouse_move"), num_arg(args[1], "mouse_move"))

def b_mouse_click(args):
    if len(args) not in (0, 1):
        raise VantaError("mouse_click takes an optional button (\"left\" or \"right\")")
    return _mouse_click(args[0] if args else None)

def b_mouse_pos(args):
    _need(args, 0, "mouse_pos")
    return _mouse_pos()


def _hotkey_loop(name, fn, stop):
    was = False
    while not stop.is_set():
        try:
            now = _key_state(name)
        except Exception:
            now = False
        if now and not was:
            try:
                apply_callable(fn, [])
            except Exception:
                pass
        was = now
        stop.wait(0.02)

def b_on_hotkey(args):
    _need(args, 2, "on_hotkey")
    name = args[0]
    fn = args[1]
    if not isinstance(fn, (Function, Builtin, BoundMethod)):
        raise VantaError("on_hotkey's second argument must be a function to run")
    _keycode(name)                          # validate the key now
    stop = _threading.Event()
    t = _threading.Thread(target=_hotkey_loop, args=(name, fn, stop), daemon=True)
    t.start()
    _HOTKEY_ID[0] += 1
    hid = _HOTKEY_ID[0]
    _HOTKEYS[hid] = stop
    return hid

def b_clear_hotkey(args):
    _need(args, 1, "clear_hotkey")
    hid = int_arg(args[0], "clear_hotkey")
    if hid in _HOTKEYS:
        _HOTKEYS[hid].set()
        del _HOTKEYS[hid]
        return True
    return False


# ---- v5.0 stdlib completeness: lists, maps, text, numbers, dates ---------

def b_unique(args):
    _need(args, 1, "unique")
    if not isinstance(args[0], list):
        raise VantaError("unique needs a list")
    seen, out = [], []
    for v in args[0]:
        if v not in seen:
            seen.append(v)
            out.append(v)
    return out


def b_zip(args):
    _need(args, 2, "zip")
    a, b = args
    if not (isinstance(a, list) and isinstance(b, list)):
        raise VantaError("zip needs two lists")
    return [[x, y] for x, y in zip(a, b)]


def b_flatten(args):
    _need(args, 1, "flatten")
    if not isinstance(args[0], list):
        raise VantaError("flatten needs a list")
    out = []
    for v in args[0]:
        if isinstance(v, list):
            out.extend(v)
        else:
            out.append(v)
    return out


def b_index_of(args):
    _need(args, 2, "index_of")
    coll, item = args
    if isinstance(coll, str):
        return coll.find(display(item))
    if isinstance(coll, list):
        for i, v in enumerate(coll):
            if v == item:
                return i
        return -1
    raise VantaError("index_of works on lists or text")


def b_insert_at(args):
    _need(args, 3, "insert_at")
    if not isinstance(args[0], list):
        raise VantaError("insert_at needs a list, a position, and a value")
    out = list(args[0])
    out.insert(int_arg(args[1], "insert_at"), args[2])
    return out


def b_shuffle(args):
    _need(args, 1, "shuffle")
    if not isinstance(args[0], list):
        raise VantaError("shuffle needs a list")
    out = list(args[0])
    random.shuffle(out)
    return out


def b_pick(args):
    _need(args, 1, "pick")
    if not isinstance(args[0], list) or not args[0]:
        raise VantaError("pick needs a non-empty list")
    return random.choice(args[0])


def b_chunk(args):
    _need(args, 2, "chunk")
    if not isinstance(args[0], list):
        raise VantaError("chunk needs a list and a size")
    size = int_arg(args[1], "chunk")
    if size < 1:
        raise VantaError("chunk needs a size of at least 1")
    return [args[0][i:i + size] for i in range(0, len(args[0]), size)]


def b_any_where(args):
    _need(args, 2, "any_where")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("any_where needs a function and a list")
    return any(truthy(apply_callable(fn, [x])) for x in seq)


def b_all_where(args):
    _need(args, 2, "all_where")
    fn, seq = args
    if not isinstance(seq, list):
        raise VantaError("all_where needs a function and a list")
    return all(truthy(apply_callable(fn, [x])) for x in seq)


def b_get(args):
    if len(args) not in (2, 3):
        raise VantaError("get expects a map, a key, and an optional fallback")
    m = args[0]
    if not isinstance(m, dict):
        raise VantaError("get needs a map")
    key = _key(args[1])
    if not isinstance(key, (list, dict)) and key in m:
        return m[key]
    return args[2] if len(args) == 3 else None


def b_has_key(args):
    _need(args, 2, "has_key")
    if not isinstance(args[0], dict):
        raise VantaError("has_key needs a map")
    return is_member(args[1], args[0])


def b_remove_key(args):
    _need(args, 2, "remove_key")
    if not isinstance(args[0], dict):
        raise VantaError("remove_key needs a map")
    out = dict(args[0])
    if not isinstance(args[1], (list, dict)):
        out.pop(_key(args[1]), None)
    return out


def b_merge(args):
    if len(args) < 1:
        raise VantaError("merge needs at least one map")
    out = {}
    for m in args:
        if not isinstance(m, dict):
            raise VantaError("merge needs maps")
        out.update(m)
    return out


def b_entries(args):
    _need(args, 1, "entries")
    if not isinstance(args[0], dict):
        raise VantaError("entries needs a map")
    return [[_unkey(k), v] for k, v in args[0].items()]


def b_repeat_text(args):
    _need(args, 2, "repeat_text")
    n = int_arg(args[1], "repeat_text")
    if n < 0:
        raise VantaError("repeat_text needs a count of 0 or more")
    return display(args[0]) * n


def b_title_case(args):
    _need(args, 1, "title_case")
    return display(args[0]).title()


def b_capitalize(args):
    _need(args, 1, "capitalize")
    s = display(args[0])
    return s[:1].upper() + s[1:] if s else s


def b_last_index_of(args):
    _need(args, 2, "last_index_of")
    coll, item = args
    if isinstance(coll, str):
        return coll.rfind(display(item))
    if isinstance(coll, list):
        for i in range(len(coll) - 1, -1, -1):
            if coll[i] == item:
                return i
        return -1
    raise VantaError("last_index_of works on lists or text")


def b_format_number(args):
    if len(args) not in (1, 2):
        raise VantaError("format_number expects a number and an optional digit count")
    value = num_arg(args[0], "format_number")
    digits = int_arg(args[1], "format_number") if len(args) == 2 else 0
    if digits < 0:
        raise VantaError("format_number needs a digit count of 0 or more")
    return f"{value:,.{digits}f}"


def b_clamp(args):
    _need(args, 3, "clamp")
    value = num_arg(args[0], "clamp")
    low = num_arg(args[1], "clamp")
    high = num_arg(args[2], "clamp")
    if low > high:
        raise VantaError("clamp needs the low bound first")
    return min(max(value, low), high)


def b_sign(args):
    _need(args, 1, "sign")
    value = num_arg(args[0], "sign")
    return (value > 0) - (value < 0)


def b_asin(args):
    _need(args, 1, "asin")
    value = num_arg(args[0], "asin")
    if value < -1 or value > 1:
        raise VantaError("asin needs a number between -1 and 1")
    return math.asin(value)


def b_acos(args):
    _need(args, 1, "acos")
    value = num_arg(args[0], "acos")
    if value < -1 or value > 1:
        raise VantaError("acos needs a number between -1 and 1")
    return math.acos(value)


def b_atan(args):
    _need(args, 1, "atan")
    return math.atan(num_arg(args[0], "atan"))


def b_atan2(args):
    _need(args, 2, "atan2")
    return math.atan2(num_arg(args[0], "atan2"), num_arg(args[1], "atan2"))


def b_random_float(args):
    _need(args, 0, "random_float")
    return random.random()


def b_format_date(args):
    if len(args) not in (1, 2):
        raise VantaError("format_date expects a timestamp and an optional pattern")
    stamp = num_arg(args[0], "format_date")
    pattern = display(args[1]) if len(args) == 2 else "%Y-%m-%d %H:%M:%S"
    try:
        return time.strftime(pattern, time.localtime(stamp))
    except (ValueError, OverflowError, OSError):
        raise VantaError("format_date couldn't format that timestamp")


def b_parse_date(args):
    if len(args) not in (1, 2):
        raise VantaError("parse_date expects a date text and an optional pattern")
    text_val = display(args[0])
    pattern = display(args[1]) if len(args) == 2 else "%Y-%m-%d"
    try:
        return int(time.mktime(time.strptime(text_val, pattern)))
    except (ValueError, OverflowError):
        raise VantaError(f"parse_date couldn't read '{text_val}' with pattern '{pattern}'")


BUILTINS = {
    # bytes (game data, file formats)
    "read_binary": b_read_binary, "write_binary": b_write_binary, "bytes": b_bytes, "is_bytes": b_is_bytes,
    "u8": _reader(1, False), "s8": _reader(1, True), "u16": _reader(2, False), "s16": _reader(2, True),
    "u32": _reader(4, False), "s32": _reader(4, True),
    "put_u8": _writer(1), "put_u16": _writer(2), "put_u32": _writer(4),
    # conversions & inspection
    "length": b_length, "text": b_text, "number": b_number, "typeof": b_typeof,
    "type_of": b_type_of, "is_number": b_is_number, "is_text": b_is_text,
    "is_list": b_is_list, "is_map": b_is_map, "is_function": b_is_function,
    "is_nothing": b_is_nothing, "is_a": b_is_a,
    # regular expressions & dates
    "matches": b_matches, "find_all": b_find_all, "replace_all": b_replace_all,
    "today": b_today, "clock": b_clock,
    # text
    "uppercase": b_upper, "lowercase": b_lower, "trim": b_trim,
    "replace": b_replace, "starts_with": b_starts_with, "ends_with": b_ends_with,
    "find": b_find, "split": b_split, "lines": b_lines,
    "pad_left": b_pad_left, "pad_right": b_pad_right,
    "chr": b_chr, "code": b_code,
    # numbers
    "abs": b_abs, "round": b_round, "floor": b_floor, "ceil": b_ceil,
    "sqrt": b_sqrt, "power": b_power, "min": b_min, "max": b_max,
    "sin": b_sin, "cos": b_cos, "tan": b_tan, "log": b_log, "exp": b_exp,
    "sum": b_sum, "product": b_product,
    "random": b_random, "now": b_now,
    # lists & maps
    "first": b_first, "last": b_last, "range": b_range, "contains": b_contains,
    "join": b_join, "keys": b_keys, "values": b_values, "sort": b_sort,
    "reverse": b_reverse, "slice": b_slice, "push": b_push, "pop": b_pop,
    "remove_at": b_remove_at,
    # higher-order
    "map": b_map, "keep": b_keep, "reduce": b_reduce, "each": b_each,
    "count_where": b_count_where, "find_where": b_find_where, "sort_by": b_sort_by,
    # errors
    "fail": b_fail, "assert": b_assert,
    # files, system, json
    "read_file": b_read_file, "write_file": b_write_file, "run": b_run,
    "shell": b_shell, "arguments": b_arguments, "env": b_env,
    "make_dir": b_make_dir, "remove_path": b_remove_path, "list_dir": b_list_dir,
    "path_exists": b_path_exists, "copy_path": b_copy_path,
    "to_json": b_to_json, "from_json": b_from_json, "interpreter": b_interpreter,
    # run Vanta from Vanta + filesystem completeness + encoding (v4.3)
    "run_vanta": b_run_vanta, "run_file": b_run_file, "run_detached": b_run_detached,
    "append_file": b_append_file, "write_bytes": b_write_bytes,
    "is_dir": b_is_dir, "is_file": b_is_file, "file_size": b_file_size,
    "file_mtime": b_file_mtime, "move_path": b_move_path,
    "path_join": b_path_join, "dirname": b_dirname, "basename": b_basename,
    "extname": b_extname, "home_dir": b_home_dir, "now_ms": b_now_ms,
    "base64_encode": b_base64_encode, "base64_decode": b_base64_decode,
    "base64_to_bytes": b_base64_to_bytes, "bytes_to_base64": b_bytes_to_base64,
    "hex_encode": b_hex_encode, "hex_decode": b_hex_decode,
    "sha256": b_sha256, "md5": b_md5,
    "os_name": b_os_name, "open_url": b_open_url,
    # bytes & bitwise
    "read_bytes": b_read_bytes, "band": b_band, "bor": b_bor, "bxor": b_bxor,
    "bnot": b_bnot, "shift_left": b_shift_left, "shift_right": b_shift_right,
    # the web: HTTP client, HTTP server, and helpers
    "http_get": b_http_get, "http_post": b_http_post,
    "http_request": b_http_request, "serve": b_serve, "sleep": b_sleep,
    "download": b_download, "render_html": b_render_html,
    "url_encode": b_url_encode, "url_decode": b_url_decode,
    "html_escape": b_html_escape,
    # game-cheat / memory toolkit (read & write a running program's memory)
    "process_list": b_process_list, "find_pid": b_find_pid, "my_pid": b_my_pid,
    "read_int": b_read_int, "write_int": b_write_int,
    "read_float": b_read_float, "write_float": b_write_float,
    "read_mem": b_read_mem, "write_mem": b_write_mem, "mem_regions": b_mem_regions,
    "mem_scan": b_mem_scan, "mem_next": b_mem_next,
    "freeze": b_freeze, "unfreeze": b_unfreeze,
    # input + global hotkeys (press keys, move/click mouse, toggle a cheat with F1)
    "press_key": b_press_key, "key_down": b_key_down, "key_up": b_key_up,
    "type_text": b_type_text, "key_pressed": b_key_pressed, "wait_key": b_wait_key,
    "mouse_move": b_mouse_move, "mouse_click": b_mouse_click, "mouse_pos": b_mouse_pos,
    "on_hotkey": b_on_hotkey, "clear_hotkey": b_clear_hotkey,
    # v5.0 stdlib completeness
    "unique": b_unique, "zip": b_zip, "flatten": b_flatten,
    "index_of": b_index_of, "insert_at": b_insert_at, "shuffle": b_shuffle,
    "pick": b_pick, "chunk": b_chunk,
    "any_where": b_any_where, "all_where": b_all_where,
    "get": b_get, "has_key": b_has_key, "remove_key": b_remove_key,
    "merge": b_merge, "entries": b_entries,
    "repeat_text": b_repeat_text, "title_case": b_title_case,
    "capitalize": b_capitalize, "last_index_of": b_last_index_of,
    "format_number": b_format_number,
    "clamp": b_clamp, "sign": b_sign,
    "asin": b_asin, "acos": b_acos, "atan": b_atan, "atan2": b_atan2,
    "random_float": b_random_float,
    "format_date": b_format_date, "parse_date": b_parse_date,
    # 6.0 core: sets, generators, formatting
    "set": b_set, "is_set": b_is_set, "union": b_union, "intersection": b_intersection,
    "difference": b_difference, "is_subset": b_is_subset, "list": b_list, "next": b_next,
    "format": b_format,
}

# ===========================================================================
# 6.0 STANDARD LIBRARY — concurrency, networking, system, data
# (Vanta 6.0 "batteries included". Every function here also exists in native
# builds — see native/runtime/vrt_thread.c, vrt_net.c, vrt_sys.c, vrt_data.c —
# and docs/STDLIB.md documents each one. Imports of rarely-needed modules are
# lazy so loading vanta.py stays fast and works in the browser.)
# ===========================================================================

class Handle:
    """A runtime object owned by the host — a task, channel, lock, socket, file, process, server or database.
    `say` shows it as <kind>; type_of gives its kind."""
    __slots__ = ("kind", "obj")

    def __init__(self, kind, obj):
        self.kind = kind
        self.obj = obj

    def __str__(self):
        return f"<{self.kind}>"


def _handle(value, kind, name):
    if isinstance(value, Handle) and value.kind == kind:
        return value.obj
    raise VantaError(f"{name} needs a {kind}")


def _is_callable(v):
    return isinstance(v, (Function, Builtin, BoundMethod, VantaType))


def _to_bytes(v):
    """Text becomes UTF-8; bytes stay as they are; anything else is shown as text first."""
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    return display(v).encode("utf-8")


def _opt(args, i, default=None):
    return args[i] if len(args) > i and args[i] is not None else default


def _arity(args, low, high, usage):
    if not (low <= len(args) <= high):
        raise VantaError(usage)


# ---- concurrency: tasks, channels, locks ----------------------------------
# A task is a function running on its own thread. Python's own lock means only
# one thread runs Vanta code at a time, but sleeping, network I/O, waiting for
# processes and channel waits let the others run — so I/O-bound programs really
# do run concurrently. run_parallel uses separate processes for CPU work.

class _Task:
    __slots__ = ("done", "result", "error")

    def __init__(self):
        self.done = _threading.Event()
        self.result = None
        self.error = None


_STACK_SET = [False]
_LIVE = [0]          # tasks and servers running right now (a channel wait with none of them would never end)


def _new_thread(target):
    if not _STACK_SET[0]:
        try:
            _threading.stack_size(64 * 1024 * 1024)     # deep recursion works inside tasks too
        except (ValueError, RuntimeError):
            pass
        _STACK_SET[0] = True
    t = _threading.Thread(target=target, daemon=True)
    t.start()
    return t


def b_spawn(args):
    if not args or not _is_callable(args[0]):
        raise VantaError("spawn needs a function to run (and the values to give it)")
    fn, fargs, task = args[0], list(args[1:]), _Task()
    _LIVE[0] += 1

    def body():
        try:
            task.result = apply_callable(fn, fargs)
        except VantaError as e:
            task.error = str(e)
        except RecursionError:
            task.error = "that task went too deep (too much recursion)"
        except Exception as e:                       # never let a task die silently
            task.error = f"{type(e).__name__}: {e}"
        finally:
            _LIVE[0] -= 1
            task.done.set()
    _new_thread(body)
    return Handle("task", task)


def _wait_one(v, timeout=None):
    if isinstance(v, Handle) and v.kind == "task":
        t = v.obj
        if timeout is None:
            while not t.done.wait(0.25):
                pass
        elif not t.done.wait(timeout):
            return None
        if t.error is not None:
            raise VantaError(t.error)
        return t.result
    if isinstance(v, Handle) and v.kind == "process":
        try:
            return v.obj.p.wait(timeout)
        except subprocess.TimeoutExpired:
            return None
    raise VantaError("wait needs a task or a process")


def b_wait(args):
    _arity(args, 1, 2, "wait expects a task (or a list of tasks, or a process) and an optional timeout")
    timeout = num_arg(args[1], "wait") if len(args) == 2 and args[1] is not None else None
    if isinstance(args[0], list):
        return [_wait_one(v, timeout) for v in args[0]]
    return _wait_one(args[0], timeout)


def b_is_done(args):
    _need(args, 1, "is_done")
    if isinstance(args[0], Handle) and args[0].kind == "process":
        return args[0].obj.p.poll() is not None
    return _handle(args[0], "task", "is_done").done.is_set()


class _Channel:
    def __init__(self, cap):
        import collections
        self.items = collections.deque()
        self.cap = cap
        self.closed = False
        self.cond = _threading.Condition()

    def put(self, v):
        with self.cond:
            while self.cap and len(self.items) >= self.cap and not self.closed:
                if _LIVE[0] <= 0:
                    raise VantaError("send would wait forever (nothing else is running)")
                self.cond.wait(0.25)
            if self.closed:
                raise VantaError("can't send on a closed channel")
            self.items.append(v)
            self.cond.notify_all()

    def get(self, timeout):
        deadline = None if timeout is None else time.monotonic() + timeout
        with self.cond:
            while not self.items and not self.closed:
                if deadline is None and _LIVE[0] <= 0:
                    raise VantaError("receive would wait forever (nothing else is running)")
                left = 0.25 if deadline is None else min(0.25, deadline - time.monotonic())
                if left <= 0:
                    return None
                self.cond.wait(left)
            if self.items:
                v = self.items.popleft()
                self.cond.notify_all()
                return v
            return None

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()


def b_channel(args):
    _arity(args, 0, 1, "channel expects an optional capacity")
    cap = int_arg(args[0], "channel") if args else 0
    if cap < 0:
        raise VantaError("a channel's capacity can't be negative")
    return Handle("channel", _Channel(cap))


def b_new_lock(args):
    _need(args, 0, "new_lock")
    return Handle("lock", _threading.RLock())


_GLOBAL_LOCK = _threading.RLock()


def _lock_of(value):
    if value is None:
        return _GLOBAL_LOCK
    return _handle(value, "lock", "lock")


def _plain(v):
    """Only plain values cross a process boundary (run_parallel)."""
    if v is None or isinstance(v, (bool, int, float, str, bytearray)):
        return True
    if isinstance(v, list):
        return all(_plain(x) for x in v)
    if isinstance(v, dict):
        return all(_plain(k) and _plain(x) for k, x in v.items())
    return False


def b_run_parallel(args):
    _arity(args, 2, 3, "run_parallel expects a function, a list, and an optional number of workers")
    fn, items = args[0], args[1]
    if not _is_callable(fn):
        raise VantaError("run_parallel needs a function first")
    if not isinstance(items, list):
        raise VantaError("run_parallel needs a list of values")
    workers = int_arg(args[2], "run_parallel") if len(args) == 3 else (os.cpu_count() or 2)
    workers = max(1, min(workers, len(items)))
    if workers <= 1 or not hasattr(os, "fork"):
        return [apply_callable(fn, [x]) for x in items]
    import pickle
    import warnings
    size = (len(items) + workers - 1) // workers
    chunks = [items[i:i + size] for i in range(0, len(items), size)]
    sys.stdout.flush()
    kids = []
    for chunk in chunks:
        r, w = os.pipe()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            pid = os.fork()
        if pid == 0:                                  # the worker: compute, send back, vanish
            os.close(r)
            try:
                res = [apply_callable(fn, [x]) for x in chunk]
                if not all(_plain(x) for x in res):
                    raise VantaError("run_parallel results must be plain values (numbers, text, lists, maps, bytes)")
                blob = pickle.dumps(("ok", res))
            except VantaError as e:
                blob = pickle.dumps(("error", str(e)))
            except BaseException as e:
                blob = pickle.dumps(("error", f"{type(e).__name__}: {e}"))
            try:
                sys.stdout.flush()
                view = memoryview(blob)
                while view:
                    view = view[os.write(w, view):]
            finally:
                os._exit(0)
        os.close(w)
        kids.append((pid, r))
    out, err = [], None
    for pid, r in kids:
        parts = []
        while True:
            b = os.read(r, 1 << 16)
            if not b:
                break
            parts.append(b)
        os.close(r)
        os.waitpid(pid, 0)
        try:
            status, value = pickle.loads(b"".join(parts))
        except Exception:
            status, value = "error", "a run_parallel worker stopped unexpectedly"
        if status == "error" and err is None:
            err = value
        elif status == "ok":
            out.extend(value)
    if err is not None:
        raise VantaError(err)
    return out


# ---- polymorphic I/O: send / receive / read_line / read_all / write_to / close ----

def b_send(args):
    _need(args, 2, "send")
    h = args[0]
    if isinstance(h, Handle):
        if h.kind == "channel":
            h.obj.put(args[1])
            return None
        if h.kind == "socket":
            h.obj.send(_to_bytes(args[1]))
            return None
        if h.kind == "websocket":
            h.obj.send(args[1])
            return None
    raise VantaError("send needs a channel or a socket")


def b_receive(args):
    _arity(args, 1, 2, "receive expects a channel or socket (and a timeout or a size)")
    h = args[0]
    if isinstance(h, Handle):
        if h.kind == "channel":
            timeout = num_arg(args[1], "receive") if len(args) == 2 and args[1] is not None else None
            return h.obj.get(timeout)
        if h.kind == "socket":
            n = int_arg(args[1], "receive") if len(args) == 2 else 65536
            return h.obj.recv(n).decode("utf-8", "replace")
        if h.kind == "websocket":
            timeout = num_arg(args[1], "receive") if len(args) == 2 and args[1] is not None else None
            return h.obj.receive(timeout)
    raise VantaError("receive needs a channel or a socket")


def b_receive_bytes(args):
    _arity(args, 1, 2, "receive_bytes expects a socket and an optional size")
    n = int_arg(args[1], "receive_bytes") if len(args) == 2 else 65536
    return bytearray(_handle(args[0], "socket", "receive_bytes").recv(n))


def b_read_line(args):
    _need(args, 1, "read_line")
    h = args[0]
    if isinstance(h, Handle) and h.kind in ("file", "socket", "process"):
        line = h.obj.read_line()
        if line is None:
            return None
        return line.decode("utf-8", "replace")
    raise VantaError("read_line needs a file, socket or process")


def b_read_all(args):
    _need(args, 1, "read_all")
    h = args[0]
    if isinstance(h, Handle) and h.kind in ("file", "socket", "process"):
        return h.obj.read_all().decode("utf-8", "replace")
    raise VantaError("read_all needs a file, socket or process")


def b_write_to(args):
    _need(args, 2, "write_to")
    h = args[0]
    if isinstance(h, Handle) and h.kind in ("file", "socket", "process"):
        h.obj.write(_to_bytes(args[1]))
        return None
    raise VantaError("write_to needs a file, socket or process")


def b_close(args):
    _need(args, 1, "close")
    h = args[0]
    if isinstance(h, Handle) and h.kind in ("file", "socket", "channel", "process", "server", "database", "websocket"):
        h.obj.close()
        return None
    raise VantaError("close needs a file, socket, channel, process, server or database")


# ---- networking: TCP / UDP sockets, DNS ------------------------------------

class _Sock:
    """A socket plus a read buffer (so read_line and receive can be mixed)."""

    def __init__(self, s):
        self.s = s
        self.buf = b""

    def _fill(self, n):
        import socket
        try:
            return self.s.recv(n)
        except socket.timeout:
            raise VantaError("the connection timed out")
        except OSError as e:
            raise VantaError(f"the connection failed: {e.strerror or e}")

    def recv(self, n):
        if n <= 0:
            raise VantaError("receive needs a size above zero")
        if self.buf:
            out, self.buf = self.buf[:n], self.buf[n:]
            return out
        return self._fill(n)

    def read_line(self):
        while b"\n" not in self.buf:
            more = self._fill(65536)
            if not more:
                if not self.buf:
                    return None
                out, self.buf = self.buf, b""
                return out.rstrip(b"\r")
            self.buf += more
        line, _, self.buf = self.buf.partition(b"\n")
        return line[:-1] if line.endswith(b"\r") else line

    def read_all(self):
        parts = [self.buf]
        self.buf = b""
        while True:
            more = self._fill(65536)
            if not more:
                return b"".join(parts)
            parts.append(more)

    def send(self, data):
        import socket
        try:
            self.s.sendall(data)
        except socket.timeout:
            raise VantaError("the connection timed out")
        except OSError as e:
            raise VantaError(f"the connection failed: {e.strerror or e}")

    write = send

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def b_tcp_connect(args):
    _arity(args, 2, 3, "tcp_connect expects a host, a port and an optional timeout in seconds")
    import socket
    host, port = display(args[0]), int_arg(args[1], "tcp_connect")
    timeout = num_arg(args[2], "tcp_connect") if len(args) == 3 and args[2] is not None else None
    try:
        s = socket.create_connection((host, port), timeout)
    except socket.timeout:
        raise VantaError(f"could not connect to {host}:{port}: timed out")
    except socket.gaierror:
        raise VantaError(f"could not connect to {host}:{port}: unknown host")
    except OSError as e:
        raise VantaError(f"could not connect to {host}:{port}: {e.strerror or e}")
    s.settimeout(None)
    return Handle("socket", _Sock(s))


def b_tcp_listen(args):
    _arity(args, 1, 2, "tcp_listen expects a port and an optional host")
    import socket
    port = int_arg(args[0], "tcp_listen")
    host = display(args[1]) if len(args) == 2 else ""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
        s.listen(128)
    except OSError as e:
        s.close()
        raise VantaError(f"could not listen on port {port}: {e.strerror or e}")
    return Handle("socket", _Sock(s))


def b_accept(args):
    _arity(args, 1, 2, "accept expects a listening socket and an optional timeout")
    import socket
    srv = _handle(args[0], "socket", "accept")
    timeout = num_arg(args[1], "accept") if len(args) == 2 and args[1] is not None else None
    srv.s.settimeout(timeout)
    try:
        conn, _ = srv.s.accept()
    except socket.timeout:
        return None
    except OSError as e:
        raise VantaError(f"accept failed: {e.strerror or e}")
    finally:
        try:
            srv.s.settimeout(None)
        except OSError:
            pass
    conn.settimeout(None)
    return Handle("socket", _Sock(conn))


def b_set_timeout(args):
    _need(args, 2, "set_timeout")
    sk = _handle(args[0], "socket", "set_timeout")
    sk.s.settimeout(None if args[1] is None else num_arg(args[1], "set_timeout"))
    return None


def b_socket_info(args):
    _need(args, 1, "socket_info")
    sk = _handle(args[0], "socket", "socket_info")
    info = {"local_host": None, "local_port": None, "remote_host": None, "remote_port": None}
    try:
        h, p = sk.s.getsockname()[:2]
        info["local_host"], info["local_port"] = h, p
    except OSError:
        pass
    try:
        h, p = sk.s.getpeername()[:2]
        info["remote_host"], info["remote_port"] = h, p
    except OSError:
        pass
    return info


def b_udp_open(args):
    _arity(args, 0, 2, "udp_open expects an optional port and host")
    import socket
    port = int_arg(args[0], "udp_open") if args else 0
    host = display(args[1]) if len(args) == 2 else ""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind((host, port))
    except OSError as e:
        s.close()
        raise VantaError(f"could not open UDP port {port}: {e.strerror or e}")
    return Handle("socket", _Sock(s))


def b_udp_send(args):
    _need(args, 4, "udp_send")
    import socket
    sk = _handle(args[0], "socket", "udp_send")
    host, port = display(args[1]), int_arg(args[2], "udp_send")
    try:
        sk.s.sendto(_to_bytes(args[3]), (host, port))
    except socket.gaierror:
        raise VantaError(f"could not send to {host}:{port}: unknown host")
    except OSError as e:
        raise VantaError(f"could not send to {host}:{port}: {e.strerror or e}")
    return None


def b_udp_receive(args):
    _arity(args, 1, 3, "udp_receive expects a socket, an optional size and an optional timeout")
    import socket
    sk = _handle(args[0], "socket", "udp_receive")
    n = int_arg(args[1], "udp_receive") if len(args) >= 2 and args[1] is not None else 65536
    timeout = num_arg(args[2], "udp_receive") if len(args) == 3 and args[2] is not None else None
    sk.s.settimeout(timeout)
    try:
        data, addr = sk.s.recvfrom(n)
    except socket.timeout:
        return None
    except OSError as e:
        raise VantaError(f"udp_receive failed: {e.strerror or e}")
    finally:
        sk.s.settimeout(None)
    return {"data": data.decode("utf-8", "replace"), "host": addr[0], "port": addr[1]}


def b_dns_lookup(args):
    _need(args, 1, "dns_lookup")
    import socket
    host = display(args[0])
    try:
        infos = socket.getaddrinfo(host, None, 0, socket.SOCK_STREAM)
    except socket.gaierror:
        raise VantaError(f"could not look up {host}")
    out = []
    for info in infos:
        addr = info[4][0]
        if addr not in out:
            out.append(addr)
    return out


# ---- HTTP server: routes, request/response model ---------------------------

def _route_match(pattern, path):
    """'/users/:id' matches '/users/7' -> {'id': '7'}; a final '*' matches the rest -> {'*': 'a/b.css'}."""
    pp = [p for p in pattern.split("/") if p]
    xs = [p for p in path.split("/") if p]
    params = {}
    for i, seg in enumerate(pp):
        if seg == "*":
            params["*"] = "/".join(xs[i:])
            return params
        if i >= len(xs):
            return None
        if seg.startswith(":"):
            params[seg[1:]] = xs[i]
        elif seg != xs[i]:
            return None
    return params if len(xs) == len(pp) else None


_MIME = {".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".css": "text/css",
         ".js": "text/javascript", ".json": "application/json", ".txt": "text/plain; charset=utf-8",
         ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
         ".svg": "image/svg+xml", ".ico": "image/x-icon", ".pdf": "application/pdf", ".wasm": "application/wasm",
         ".mp3": "audio/mpeg", ".mp4": "video/mp4", ".webp": "image/webp", ".xml": "application/xml",
         ".csv": "text/csv", ".woff2": "font/woff2"}


def _mime(path):
    return _MIME.get(os.path.splitext(path)[1].lower(), "application/octet-stream")


def _static_reply(folder, rest):
    parts = [p for p in rest.split("/") if p]
    if any(p == ".." for p in parts):
        return 404, {}, b"not found", "text/plain; charset=utf-8"
    fp = os.path.join(os.path.expanduser(folder), *parts) if parts else os.path.expanduser(folder)
    if os.path.isdir(fp):
        fp = os.path.join(fp, "index.html")
    try:
        with open(fp, "rb") as f:
            return 200, {}, f.read(), _mime(fp)
    except OSError:
        return 404, {}, b"not found", "text/plain; charset=utf-8"


def _http_respond(result):
    """A handler's value -> (status, headers, body bytes, content type)."""
    status, ctype, extra = 200, "text/html; charset=utf-8", {}
    if isinstance(result, dict):
        status = int(result.get("status", 200))
        hh = result.get("headers")
        if isinstance(hh, dict):
            extra = {display(k): display(v) for k, v in hh.items()}
        if "file" in result:
            fp = os.path.expanduser(display(result["file"]))
            ctype = display(result.get("type", result.get("content_type", _mime(fp))))
            if result.get("download"):
                extra.setdefault("Content-Disposition", 'attachment; filename="%s"' % os.path.basename(fp))
            try:
                with open(fp, "rb") as f:
                    return status, extra, f.read(), ctype
            except OSError:
                return 404, {}, ("not found: " + fp).encode("utf-8"), "text/plain; charset=utf-8"
        if isinstance(result.get("bytes"), list):
            data = bytes(int(x) & 0xFF for x in result["bytes"])
            return status, extra, data, display(result.get("type", result.get("content_type", "application/octet-stream")))
        raw = result.get("body", "")
        if isinstance(raw, (dict, list)):
            data = json.dumps(raw).encode("utf-8")
            ctype = "application/json"
        elif isinstance(raw, bytearray):
            data = bytes(raw)
            ctype = "application/octet-stream"
        else:
            data = display(raw).encode("utf-8")
        if "type" in result or "content_type" in result:
            ctype = display(result.get("type", result.get("content_type")))
        return status, extra, data, ctype
    if isinstance(result, bytearray):
        return status, extra, bytes(result), "application/octet-stream"
    return status, extra, display(result).encode("utf-8"), ctype


def _http_dispatch(handler, request):
    """Run the handler (a function, or a routes map) for one request."""
    if isinstance(handler, dict):
        method, path = request["method"], request["path"]
        for key, target in handler.items():
            key = display(key).strip()
            want, _, pattern = key.partition(" ") if " " in key else ("", "", key)
            if want and want.upper() != method and not (want.upper() == "GET" and method == "HEAD"):
                continue
            params = _route_match(pattern.strip(), path)
            if params is None:
                continue
            if isinstance(target, str):                      # a folder of static files
                return _static_reply(target, params.get("*", path.lstrip("/") if "*" not in pattern else ""))
            request["params"] = params
            return _http_respond(apply_callable(target, [request]))
        return 404, {}, b"not found", "text/plain; charset=utf-8"
    return _http_respond(apply_callable(handler, [request]))


class _Server:
    def __init__(self, httpd, thread):
        self.httpd = httpd
        self.thread = thread

    def close(self):
        try:
            self.httpd.shutdown()
            self.httpd.server_close()
        except OSError:
            pass


def _make_http_server(port, handler, host=""):
    import urllib.parse
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    if not (_is_callable(handler) or isinstance(handler, dict)):
        raise VantaError("a server's handler must be a function (request -> page) or a map of routes")
    # Slow clients get their own thread, but handlers take turns (one at a time), so a
    # handler never races another — use spawn/channels inside if you need more.
    handler_lock = _threading.Lock()

    class VantaHandler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _handle(self, method):
            parsed = urllib.parse.urlparse(self.path)
            query = {k: (v[0] if len(v) == 1 else v)
                     for k, v in urllib.parse.parse_qs(parsed.query).items()}
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            headers = {k: v for k, v in self.headers.items()}
            ctype = (self.headers.get("Content-Type") or "").lower()
            parsed_json, form = None, {}
            if "json" in ctype and body:
                try:
                    parsed_json = json.loads(body)
                except ValueError:
                    parsed_json = None
            if "application/x-www-form-urlencoded" in ctype:
                form = {k: (v[0] if len(v) == 1 else v) for k, v in urllib.parse.parse_qs(body).items()}
            request = {"method": method, "path": urllib.parse.unquote(parsed.path), "query": query,
                       "headers": headers, "body": body, "params": {}, "json": parsed_json, "form": form,
                       "client": self.client_address[0]}
            if (method == "GET" and isinstance(handler, dict)
                    and (self.headers.get("Upgrade") or "").lower() == "websocket"):
                if _ws_serve(self, handler, request):
                    return
            try:
                with handler_lock:
                    status, extra, data, ctype = _http_dispatch(handler, request)
            except VantaError as e:
                status, extra, data, ctype = 500, {}, f"Vanta error: {e}".encode("utf-8"), "text/plain; charset=utf-8"
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in extra.items():
                self.send_header(k, v)
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(data)

        def do_GET(self):     self._handle("GET")
        def do_POST(self):    self._handle("POST")
        def do_PUT(self):     self._handle("PUT")
        def do_DELETE(self):  self._handle("DELETE")
        def do_PATCH(self):   self._handle("PATCH")
        def do_HEAD(self):    self._handle("HEAD")
        def do_OPTIONS(self): self._handle("OPTIONS")

    try:
        httpd = ThreadingHTTPServer((host, port), VantaHandler)
    except OSError as e:
        raise VantaError(f"could not listen on port {port}: {e.strerror or e}")
    httpd.daemon_threads = True
    return httpd


def b_serve2(args):
    if len(args) not in (1, 2):
        raise VantaError("serve expects a port and a handler function or routes map "
                         "(or just a handler — port defaults to 8080)")
    port, handler = (8080, args[0]) if len(args) == 1 else (int_arg(args[0], "serve"), args[1])
    httpd = _make_http_server(port, handler)
    print(f"Vanta server running on http://localhost:{httpd.server_address[1]}  "
          f"(press Stop / Ctrl-C to quit)")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        print("Server stopped.")
    return None


def b_start_server(args):
    _need(args, 2, "start_server")
    httpd = _make_http_server(int_arg(args[0], "start_server"), args[1])

    def run():
        _LIVE[0] += 1
        try:
            httpd.serve_forever()
        finally:
            _LIVE[0] -= 1
    th = _new_thread(run)
    return Handle("server", _Server(httpd, th))


def b_server_port(args):
    _need(args, 1, "server_port")
    return _handle(args[0], "server", "server_port").httpd.server_address[1]


def b_stop_server(args):
    _need(args, 1, "stop_server")
    _handle(args[0], "server", "stop_server").close()
    return None


def b_json_response(args):
    _arity(args, 1, 2, "json_response expects a value and an optional status")
    try:
        body = json.dumps(args[0])
    except TypeError:
        raise VantaError("that value can't be turned into JSON")
    return {"status": int_arg(args[1], "json_response") if len(args) == 2 else 200,
            "body": body, "type": "application/json"}


# ---- WebSockets (ws://): a client, and "WS /path" routes in the HTTP server ----

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + _WS_GUID).encode("ascii")).digest()).decode("ascii")


class _WS:
    """One WebSocket connection over a _Sock. Clients mask what they send; servers don't."""

    def __init__(self, sk, mask):
        self.sk = sk
        self.mask = mask
        self.closed = False

    def _exact(self, n):
        out = b""
        while len(out) < n:
            more = self.sk.recv(n - len(out))
            if not more:
                raise EOFError
            out += more
        return out

    def send_frame(self, op, data):
        if self.closed:
            raise VantaError("that websocket is closed")
        head = bytes([0x80 | op])
        n = len(data)
        mbit = 0x80 if self.mask else 0
        if n < 126:
            head += bytes([mbit | n])
        elif n < 65536:
            head += bytes([mbit | 126]) + n.to_bytes(2, "big")
        else:
            head += bytes([mbit | 127]) + n.to_bytes(8, "big")
        if self.mask:
            key = os.urandom(4)
            data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
            head += key
        self.sk.send(head + data)

    def send(self, v):
        if isinstance(v, bytearray):
            self.send_frame(2, bytes(v))
        else:
            self.send_frame(1, display(v).encode("utf-8"))

    def receive(self, timeout):
        import socket
        if self.closed:
            return None
        self.sk.s.settimeout(timeout)
        try:
            parts, kind = [], None
            while True:
                b0, b1 = self._exact(2)
                op, n = b0 & 0x0F, b1 & 0x7F
                if n == 126:
                    n = int.from_bytes(self._exact(2), "big")
                elif n == 127:
                    n = int.from_bytes(self._exact(8), "big")
                key = self._exact(4) if b1 & 0x80 else None
                data = self._exact(n) if n else b""
                if key:
                    data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
                if op == 8:                                 # close: answer it and stop
                    try:
                        self.send_frame(8, data[:2])
                    except VantaError:
                        pass
                    self.closed = True
                    self.sk.close()
                    return None
                if op == 9:                                 # ping -> pong
                    self.send_frame(10, data)
                    continue
                if op == 10:
                    continue
                if op in (1, 2):
                    kind = op
                parts.append(data)
                if b0 & 0x80:
                    blob = b"".join(parts)
                    return blob.decode("utf-8", "replace") if kind == 1 else bytearray(blob)
        except VantaError as e:
            if "timed out" in str(e):
                return None
            raise
        except socket.timeout:
            return None
        except EOFError:
            self.closed = True
            return None
        finally:
            try:
                self.sk.s.settimeout(None)
            except OSError:
                pass

    def close(self):
        if not self.closed:
            try:
                self.send_frame(8, (1000).to_bytes(2, "big"))
            except VantaError:
                pass
            self.closed = True
        self.sk.close()


def _ws_serve(req_handler, handler, request):
    """Upgrade a server request to a WebSocket if a "WS /path" route matches; runs the route's function."""
    for key, target in handler.items():
        key = display(key).strip()
        want, _, pattern = key.partition(" ")
        if want.upper() != "WS" or isinstance(target, str):
            continue
        params = _route_match(pattern.strip(), request["path"])
        if params is None:
            continue
        accept = _ws_accept(req_handler.headers.get("Sec-WebSocket-Key", ""))
        req_handler.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                 f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode("ascii"))
        req_handler.wfile.flush()
        req_handler.close_connection = True
        request["params"] = params
        ws = _WS(_Sock(req_handler.connection), False)
        try:
            apply_callable(target, [Handle("websocket", ws), request])
        except VantaError:
            pass
        finally:
            ws.close()
        return True
    return False


def b_ws_connect(args):
    _arity(args, 1, 2, "ws_connect expects a ws:// url and an optional headers map")
    import urllib.parse
    url = display(args[0])
    u = urllib.parse.urlparse(url)
    if u.scheme != "ws" or not u.hostname:
        raise VantaError("ws_connect needs a ws:// url")
    port = u.port or 80
    sock = _handle(b_tcp_connect([u.hostname, port, 10]), "socket", "ws_connect")
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    path = (u.path or "/") + (("?" + u.query) if u.query else "")
    lines = [f"GET {path} HTTP/1.1", f"Host: {u.hostname}:{port}", "Upgrade: websocket", "Connection: Upgrade",
             f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
    for k, v in _headers_map(_opt(args, 1), "ws_connect").items():
        lines.append(f"{k}: {v}")
    sock.send(("\r\n".join(lines) + "\r\n\r\n").encode("utf-8"))
    status = sock.read_line()
    ok_accept = False
    while True:
        line = sock.read_line()
        if line is None or line == b"":
            break
        name, _, value = line.decode("latin-1").partition(":")
        if name.strip().lower() == "sec-websocket-accept" and value.strip() == _ws_accept(key):
            ok_accept = True
    if status is None or b" 101" not in status or not ok_accept:
        sock.close()
        raise VantaError("websocket handshake failed: " + (status or b"no reply").decode("latin-1"))
    return Handle("websocket", _WS(sock, True))


def b_redirect(args):
    _arity(args, 1, 2, "redirect expects a url and an optional status")
    return {"status": int_arg(args[1], "redirect") if len(args) == 2 else 302,
            "headers": {"Location": display(args[0])}, "body": ""}


# ---- processes -------------------------------------------------------------

def _proc_options(opts, name):
    if opts is None:
        return {}
    if not isinstance(opts, dict):
        raise VantaError(f"{name}'s options must be a map")
    return opts


def _proc_args(cmd, opts):
    kw = {}
    if isinstance(cmd, list):
        kw["args"] = [display(x) for x in cmd]
        kw["shell"] = False
    else:
        kw["args"] = display(cmd)
        kw["shell"] = True
    if opts.get("dir") is not None:
        kw["cwd"] = os.path.expanduser(display(opts["dir"]))
    if isinstance(opts.get("env"), dict):
        env = dict(os.environ)
        for k, v in opts["env"].items():
            env[display(k)] = display(v)
        kw["env"] = env
    return kw


def b_run_process(args):
    _arity(args, 1, 2, "run_process expects a command (text or list) and an optional options map")
    opts = _proc_options(_opt(args, 1), "run_process")
    kw = _proc_args(args[0], opts)
    data = _to_bytes(opts["input"]) if opts.get("input") is not None else None
    timeout = num_arg(opts["timeout"], "run_process") if opts.get("timeout") is not None else None
    try:
        r = subprocess.run(input=data, capture_output=True, timeout=timeout,
                           stdin=None if data is not None else subprocess.DEVNULL, **kw)
    except subprocess.TimeoutExpired:
        raise VantaError("the command timed out")
    except OSError as e:
        raise VantaError(f"could not run {display(args[0])}: {e.strerror or e}")
    return {"output": r.stdout.decode("utf-8", "replace"), "error": r.stderr.decode("utf-8", "replace"),
            "code": r.returncode}


class _Proc:
    def __init__(self, p):
        self.p = p

    def read_line(self):
        line = self.p.stdout.readline()
        if not line:
            return None
        line = line[:-1] if line.endswith(b"\n") else line
        return line[:-1] if line.endswith(b"\r") else line

    def read_all(self):
        return self.p.stdout.read()

    def write(self, data):
        try:
            self.p.stdin.write(data)
            self.p.stdin.flush()
        except (OSError, ValueError):
            raise VantaError("the process isn't reading its input any more")

    def close(self):
        for f in (self.p.stdin, self.p.stdout, self.p.stderr):
            try:
                if f:
                    f.close()
            except OSError:
                pass
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait()


def b_open_process(args):
    _arity(args, 1, 2, "open_process expects a command (text or list) and an optional options map")
    opts = _proc_options(_opt(args, 1), "open_process")
    kw = _proc_args(args[0], opts)
    merge = truthy(opts.get("merge_errors"))
    try:
        p = subprocess.Popen(stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT if merge else subprocess.PIPE, **kw)
    except OSError as e:
        raise VantaError(f"could not run {display(args[0])}: {e.strerror or e}")
    return Handle("process", _Proc(p))


def b_close_input(args):
    _need(args, 1, "close_input")
    p = _handle(args[0], "process", "close_input")
    try:
        p.p.stdin.close()
    except OSError:
        pass
    return None


def b_process_errors(args):
    _need(args, 1, "process_errors")
    p = _handle(args[0], "process", "process_errors")
    if p.p.stderr is None:
        return ""
    return p.p.stderr.read().decode("utf-8", "replace")


def b_kill_process(args):
    _need(args, 1, "kill_process")
    p = _handle(args[0], "process", "kill_process")
    if p.p.poll() is None:
        p.p.kill()
    return None


def b_process_id(args):
    _need(args, 1, "process_id")
    return _handle(args[0], "process", "process_id").p.pid


# ---- environment, signals, exit --------------------------------------------

def b_env2(args):
    _arity(args, 1, 2, "env expects a name and an optional fallback")
    v = os.environ.get(display(args[0]))
    if v is None:
        return args[1] if len(args) == 2 else ""
    return v


def b_set_env(args):
    _need(args, 2, "set_env")
    name = display(args[0])
    if args[1] is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = display(args[1])
    return None


def b_env_vars(args):
    _need(args, 0, "env_vars")
    return {k: os.environ[k] for k in sorted(os.environ)}


_SIGNALS = ("INT", "TERM", "HUP", "USR1", "USR2", "QUIT", "ALRM")


def _signum(name, fname):
    import signal
    n = display(name).upper()
    n = n[3:] if n.startswith("SIG") else n
    if n not in _SIGNALS or not hasattr(signal, "SIG" + n):
        raise VantaError(f"{fname}: unknown signal '{display(name)}' (use one of {', '.join(_SIGNALS)})")
    return getattr(signal, "SIG" + n), n


def b_on_signal(args):
    _need(args, 2, "on_signal")
    import signal
    num, n = _signum(args[0], "on_signal")
    fn = args[1]
    if fn is None:
        signal.signal(num, signal.SIG_DFL)
        return None
    if not _is_callable(fn):
        raise VantaError("on_signal needs a function to call (or nothing to reset)")

    def handler(_s, _f):
        apply_callable(fn, [n])
    try:
        signal.signal(num, handler)
    except ValueError:
        raise VantaError("on_signal only works on the main thread")
    return None


def b_send_signal(args):
    _need(args, 2, "send_signal")
    num, _ = _signum(args[1], "send_signal")
    target = args[0]
    pid = target.obj.p.pid if isinstance(target, Handle) and target.kind == "process" else int_arg(target, "send_signal")
    try:
        os.kill(pid, num)
    except OSError as e:
        raise VantaError(f"could not signal process {pid}: {e.strerror or e}")
    return None


def b_exit(args):
    _arity(args, 0, 1, "exit expects an optional exit code")
    code = int_arg(args[0], "exit") if args else 0
    sys.stdout.flush()
    os._exit(code)


# ---- files: handles, walking, glob, temp files, paths ----------------------

class _File:
    def __init__(self, f):
        self.f = f

    def _io(self, what, fn):
        if self.f.closed:
            raise VantaError("that file is closed")
        try:
            return fn()
        except (OSError, ValueError):
            raise VantaError(f"could not {what} that file")

    def read_line(self):
        line = self._io("read from", self.f.readline)
        if not line:
            return None
        line = line[:-1] if line.endswith(b"\n") else line
        return line[:-1] if line.endswith(b"\r") else line

    def read_all(self):
        return self._io("read from", self.f.read)

    def write(self, data):
        self._io("write to", lambda: self.f.write(data))

    def close(self):
        self.f.close()


_FILE_MODES = {"read": "rb", "r": "rb", "write": "wb", "w": "wb", "append": "ab", "a": "ab",
               "update": "r+b", "r+": "r+b"}


def _file_of(v, name):
    f = _handle(v, "file", name)
    if f.f.closed:
        raise VantaError(f"{name}: that file is closed")
    return f


def b_open_file(args):
    _arity(args, 1, 2, "open_file expects a path and an optional mode (read, write, append, update)")
    path = os.path.expanduser(display(args[0]))
    mode = display(args[1]).lower() if len(args) == 2 else "read"
    if mode not in _FILE_MODES:
        raise VantaError(f"open_file: unknown mode '{mode}' (use read, write, append or update)")
    try:
        return Handle("file", _File(open(path, _FILE_MODES[mode])))
    except OSError as e:
        raise VantaError(f"could not open {path}: {e.strerror or e}")


def b_read_chunk(args):
    _need(args, 2, "read_chunk")
    return _file_of(args[0], "read_chunk").f.read(int_arg(args[1], "read_chunk")).decode("utf-8", "replace")


def b_read_chunk_bytes(args):
    _need(args, 2, "read_chunk_bytes")
    return bytearray(_file_of(args[0], "read_chunk_bytes").f.read(int_arg(args[1], "read_chunk_bytes")))


def b_seek(args):
    _arity(args, 2, 3, "seek expects a file, a position and an optional \"start\", \"current\" or \"end\"")
    f = _file_of(args[0], "seek")
    whence = {"start": 0, "current": 1, "end": 2}.get(display(args[2]) if len(args) == 3 else "start")
    if whence is None:
        raise VantaError('seek counts from "start", "current" or "end"')
    try:
        f.f.seek(int_arg(args[1], "seek"), whence)
    except (OSError, ValueError) as e:
        raise VantaError(f"seek failed: {e}")
    return None


def b_tell(args):
    _need(args, 1, "tell")
    return _file_of(args[0], "tell").f.tell()


def b_walk_dir(args):
    _need(args, 1, "walk_dir")
    top = display(args[0])
    if not os.path.isdir(top):
        raise VantaError(f"could not walk {top}: not a folder")
    out = []
    for root, _dirs, files in os.walk(top):
        for f in files:
            out.append(os.path.join(root, f))
    return sorted(out)


def _fnmatch(name, pat):
    """Shell-style matching (* ? [abc] [!abc] [a-z]), case-sensitive — the same rules in native builds."""
    def match(i, j):
        while j < len(pat):
            c = pat[j]
            if c == "*":
                while j < len(pat) and pat[j] == "*":
                    j += 1
                if j == len(pat):
                    return True
                return any(match(k, j) for k in range(i, len(name) + 1))
            if i >= len(name):
                return False
            if c == "?":
                i += 1
                j += 1
                continue
            if c == "[":
                k = j + 1
                neg = k < len(pat) and pat[k] == "!"
                if neg:
                    k += 1
                start, hit = k, False
                while k < len(pat) and (pat[k] != "]" or k == start):
                    if k + 2 < len(pat) and pat[k + 1] == "-" and pat[k + 2] != "]":
                        if pat[k] <= name[i] <= pat[k + 2]:
                            hit = True
                        k += 3
                    else:
                        if pat[k] == name[i]:
                            hit = True
                        k += 1
                if k >= len(pat):                 # no closing ]: a literal [
                    if name[i] != "[":
                        return False
                    i += 1
                    j += 1
                    continue
                if hit == neg:
                    return False
                i += 1
                j = k + 1
                continue
            if c != name[i]:
                return False
            i += 1
            j += 1
        return i == len(name)
    return match(0, 0)


def _glob(pattern):
    parts = [p for p in pattern.split("/") if p]
    results = []

    def join(base, name):
        if base == "":
            return name
        return base + name if base.endswith("/") else base + "/" + name

    def names(d):
        try:
            return sorted(os.listdir(d or "."))
        except OSError:
            return []

    def walk(base, i):
        if i == len(parts):
            if base and base not in results:
                results.append(base)
            return
        part = parts[i]
        if part == "**":
            walk(base, i + 1)
            for n in names(base):
                p = join(base, n)
                if not n.startswith(".") and os.path.isdir(p) and not os.path.islink(p):
                    walk(p, i)
        elif any(ch in part for ch in "*?["):
            for n in names(base):
                if n.startswith(".") and not part.startswith("."):
                    continue
                if _fnmatch(n, part):
                    p = join(base, n)
                    if i + 1 == len(parts) or os.path.isdir(p):
                        walk(p, i + 1)
        else:
            p = join(base, part)
            if os.path.lexists(p) and (i + 1 == len(parts) or os.path.isdir(p)):
                walk(p, i + 1)

    walk("/" if pattern.startswith("/") else "", 0)
    return sorted(results)


def b_glob(args):
    _need(args, 1, "glob")
    return _glob(os.path.expanduser(display(args[0])))


def b_matches_pattern(args):
    _need(args, 2, "matches_pattern")
    return _fnmatch(display(args[0]), display(args[1]))


def b_temp_file(args):
    _arity(args, 0, 1, "temp_file expects an optional ending like \".txt\"")
    import tempfile
    fd, path = tempfile.mkstemp(suffix=display(args[0]) if args else "", prefix="vanta")
    os.close(fd)
    return path


def b_temp_dir(args):
    _need(args, 0, "temp_dir")
    import tempfile
    return tempfile.mkdtemp(prefix="vanta")


def b_absolute_path(args):
    _need(args, 1, "absolute_path")
    return os.path.abspath(os.path.expanduser(display(args[0])))


def b_current_dir(args):
    _need(args, 0, "current_dir")
    return os.getcwd()


def b_change_dir(args):
    _need(args, 1, "change_dir")
    path = os.path.expanduser(display(args[0]))
    try:
        os.chdir(path)
    except OSError as e:
        raise VantaError(f"could not change to {path}: {e.strerror or e}")
    return None


# ---- CSV ---------------------------------------------------------------------
# A small RFC-4180 reader/writer (quoted fields, "" for a quote, newlines inside
# quotes). Values stay text. Native builds use the very same rules.

def _delim(args, i, name):
    d = display(args[i]) if len(args) > i and args[i] is not None else ","
    if len(d) != 1:
        raise VantaError(f"{name}'s delimiter must be one character")
    return d


def _csv_parse(text, d):
    rows, row, field = [], [], []
    quoted = in_q = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if in_q:
            if c == '"':
                if i + 1 < n and text[i + 1] == '"':
                    field.append('"')
                    i += 2
                    continue
                in_q = False
            else:
                field.append(c)
            i += 1
            continue
        if c == '"' and not field:
            in_q = quoted = True
        elif c == d:
            row.append("".join(field))
            field, quoted = [], False
        elif c == "\n" or c == "\r":
            row.append("".join(field))
            if not (len(row) == 1 and row[0] == "" and not quoted):
                rows.append(row)
            row, field, quoted = [], [], False
            if c == "\r" and i + 1 < n and text[i + 1] == "\n":
                i += 1
        else:
            field.append(c)
        i += 1
    if field or row or quoted:
        row.append("".join(field))
        rows.append(row)
    return rows


def _csv_format(rows, d):
    if not isinstance(rows, list):
        raise VantaError("csv needs a list of rows")
    out = []
    for row in rows:
        if not isinstance(row, list):
            raise VantaError("each csv row must be a list")
        cells = []
        for v in row:
            s = display(v)
            if d in s or '"' in s or "\n" in s or "\r" in s:
                s = '"' + s.replace('"', '""') + '"'
            cells.append(s)
        out.append(d.join(cells) + "\n")
    return "".join(out)


def _read_text(path, name):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError as e:
        raise VantaError(f"could not read {path}: {e.strerror or e}")


def _write_text(path, text):
    try:
        with open(path, "wb") as f:
            f.write(text.encode("utf-8"))
    except OSError as e:
        raise VantaError(f"could not write {path}: {e.strerror or e}")


def b_csv_parse(args):
    _arity(args, 1, 2, "csv_parse expects text and an optional delimiter")
    return _csv_parse(display(args[0]), _delim(args, 1, "csv_parse"))


def b_csv_format(args):
    _arity(args, 1, 2, "csv_format expects a list of rows and an optional delimiter")
    return _csv_format(args[0], _delim(args, 1, "csv_format"))


def b_csv_read(args):
    _arity(args, 1, 2, "csv_read expects a path and an optional delimiter")
    return _csv_parse(_read_text(display(args[0]), "csv_read"), _delim(args, 1, "csv_read"))


def b_csv_write(args):
    _arity(args, 2, 3, "csv_write expects a path, a list of rows and an optional delimiter")
    _write_text(display(args[0]), _csv_format(args[1], _delim(args, 2, "csv_write")))
    return None


def b_csv_read_maps(args):
    _arity(args, 1, 2, "csv_read_maps expects a path and an optional delimiter")
    rows = _csv_parse(_read_text(display(args[0]), "csv_read_maps"), _delim(args, 1, "csv_read_maps"))
    if not rows:
        return []
    head = rows[0]
    return [{h: (r[i] if i < len(r) else "") for i, h in enumerate(head)} for r in rows[1:]]


def b_csv_write_maps(args):
    _arity(args, 2, 3, "csv_write_maps expects a path, a list of maps and an optional list of columns")
    maps = args[1]
    if not isinstance(maps, list) or not all(isinstance(m, dict) for m in maps):
        raise VantaError("csv_write_maps needs a list of maps")
    if len(args) == 3 and args[2] is not None:
        if not isinstance(args[2], list):
            raise VantaError("csv_write_maps's columns must be a list")
        cols = list(args[2])
    else:
        cols = list(maps[0].keys()) if maps else []
    rows = [cols] + [[m.get(c, "") for c in cols] for m in maps]
    _write_text(display(args[0]), _csv_format(rows, ","))
    return None


# ---- JSON (pretty printing) --------------------------------------------------

def b_to_json2(args):
    _arity(args, 1, 2, "to_json expects a value and an optional indent")
    indent = int_arg(args[1], "to_json") if len(args) == 2 and args[1] is not None else None
    try:
        return json.dumps(args[0], indent=indent)
    except (TypeError, ValueError):
        raise VantaError("that value can't be turned into JSON")


# ---- dates & times -----------------------------------------------------------
# Timestamps are seconds since 1970 (UTC), as now() gives. Time zones are IANA
# names ("Europe/Paris", "America/New_York", "UTC") looked up by the OS.

_TZ_LOCK = _threading.RLock()


def _tz_check(tz):
    tz = display(tz)
    if tz in ("UTC", "GMT") or (re.fullmatch(r"[A-Za-z0-9_+\-]+(/[A-Za-z0-9_+\-]+)*", tz)
                                and os.path.isfile(os.path.join("/usr/share/zoneinfo", tz))):
        return tz
    raise VantaError(f"unknown time zone '{tz}'")


def _in_tz(tz, fn):
    if tz is None or not hasattr(time, "tzset"):
        return fn()
    tz = _tz_check(tz)
    with _TZ_LOCK:
        old = os.environ.get("TZ")
        os.environ["TZ"] = tz
        time.tzset()
        try:
            return fn()
        finally:
            if old is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old
            time.tzset()


def b_format_date2(args):
    _arity(args, 1, 3, "format_date expects a timestamp, an optional pattern and an optional time zone")
    stamp = num_arg(args[0], "format_date")
    pattern = display(args[1]) if len(args) >= 2 and args[1] is not None else "%Y-%m-%d %H:%M:%S"
    try:
        return _in_tz(_opt(args, 2), lambda: time.strftime(pattern, time.localtime(stamp)))
    except (ValueError, OverflowError, OSError):
        raise VantaError("format_date couldn't format that timestamp")


def b_parse_date2(args):
    _arity(args, 1, 3, "parse_date expects a date text, an optional pattern and an optional time zone")
    text_val = display(args[0])
    pattern = display(args[1]) if len(args) >= 2 and args[1] is not None else "%Y-%m-%d"
    try:
        return _in_tz(_opt(args, 2), lambda: int(time.mktime(time.strptime(text_val, pattern))))
    except (ValueError, OverflowError):
        raise VantaError(f"parse_date couldn't read '{text_val}' with pattern '{pattern}'")


def b_date_parts(args):
    _arity(args, 1, 2, "date_parts expects a timestamp and an optional time zone")
    stamp = num_arg(args[0], "date_parts")

    def parts():
        t = time.localtime(stamp)
        return {"year": t.tm_year, "month": t.tm_mon, "day": t.tm_mday, "hour": t.tm_hour,
                "minute": t.tm_min, "second": t.tm_sec, "weekday": t.tm_wday + 1,
                "day_name": time.strftime("%A", t), "month_name": time.strftime("%B", t),
                "yearday": t.tm_yday, "zone": time.strftime("%Z", t), "offset": t.tm_gmtoff}
    try:
        return _in_tz(_opt(args, 1), parts)
    except (ValueError, OverflowError, OSError):
        raise VantaError("date_parts couldn't read that timestamp")


def b_make_date(args):
    _arity(args, 3, 7, "make_date expects year, month, day, and optional hour, minute, second and time zone")
    nums = [int_arg(a, "make_date") for a in args[:6]]
    while len(nums) < 6:
        nums.append(0)
    y, mo, d, h, mi, s = nums
    try:
        return _in_tz(_opt(args, 6), lambda: int(time.mktime((y, mo, d, h, mi, s, 0, 0, -1))))
    except (ValueError, OverflowError):
        raise VantaError("make_date couldn't make that date")


def b_days(args):
    _need(args, 1, "days")
    return tidy_number(num_arg(args[0], "days") * 86400)


def b_hours(args):
    _need(args, 1, "hours")
    return tidy_number(num_arg(args[0], "hours") * 3600)


def b_minutes(args):
    _need(args, 1, "minutes")
    return tidy_number(num_arg(args[0], "minutes") * 60)


def b_format_duration(args):
    _need(args, 1, "format_duration")
    secs = num_arg(args[0], "format_duration")
    sign = "-" if secs < 0 else ""
    s = int(abs(secs))
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    parts = [f"{v}{u}" for v, u in ((d, "d"), (h, "h"), (m, "m")) if v]
    if s or not parts:
        parts.append(f"{s}s")
    return sign + " ".join(parts)


def b_timezone(args):
    _need(args, 0, "timezone")
    tz = os.environ.get("TZ")
    if tz:
        return tz.lstrip(":")
    try:
        link = os.readlink("/etc/localtime")
        if "zoneinfo/" in link:
            return link.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return time.strftime("%Z")


# ---- regular expressions (extras) --------------------------------------------

def b_regex_search(args):
    _need(args, 2, "regex_search")
    try:
        m = re.search(display(args[1]), display(args[0]))
    except re.error as e:
        raise VantaError(f"that pattern is not valid: {e}")
    if m is None:
        return None
    return {"match": m.group(0), "start": m.start(), "end": m.end(), "groups": list(m.groups())}


def b_regex_split(args):
    _need(args, 2, "regex_split")
    try:
        return re.split(display(args[1]), display(args[0]))
    except re.error as e:
        raise VantaError(f"that pattern is not valid: {e}")


def b_regex_escape(args):
    _need(args, 1, "regex_escape")
    return re.escape(display(args[0]))


# ---- compression, hashing, ids, text <-> bytes -------------------------------

def b_compress(args):
    _need(args, 1, "compress")
    import zlib
    return bytearray(zlib.compress(_to_bytes(args[0])))


def b_decompress(args):
    _need(args, 1, "decompress")
    import zlib
    try:
        return bytearray(zlib.decompress(_to_bytes(args[0])))
    except zlib.error:
        raise VantaError("that isn't zlib-compressed data")


def b_gzip(args):
    _need(args, 1, "gzip")
    import gzip as _gz
    return bytearray(_gz.compress(_to_bytes(args[0]), 9, mtime=0))


def b_gunzip(args):
    _need(args, 1, "gunzip")
    import gzip as _gz
    import zlib
    try:
        return bytearray(_gz.decompress(_to_bytes(args[0])))
    except (OSError, EOFError, zlib.error):
        raise VantaError("that isn't gzip data")


def b_bytes_to_text(args):
    _need(args, 1, "bytes_to_text")
    if not isinstance(args[0], bytearray):
        raise VantaError("bytes_to_text needs bytes")
    return bytes(args[0]).decode("utf-8", "replace")


def b_md5_2(args):
    _need(args, 1, "md5")
    return hashlib.md5(_to_bytes(args[0])).hexdigest()


def b_sha1(args):
    _need(args, 1, "sha1")
    return hashlib.sha1(_to_bytes(args[0])).hexdigest()


def b_sha256_2(args):
    _need(args, 1, "sha256")
    return hashlib.sha256(_to_bytes(args[0])).hexdigest()


def b_hmac(args):
    _arity(args, 2, 3, "hmac expects a key, a message and an optional algorithm (sha256, sha1, md5)")
    import hmac as _hmac
    algo = display(args[2]).lower() if len(args) == 3 else "sha256"
    if algo not in ("sha256", "sha1", "md5"):
        raise VantaError("hmac's algorithm must be sha256, sha1 or md5")
    return _hmac.new(_to_bytes(args[0]), _to_bytes(args[1]), algo).hexdigest()


def b_uuid(args):
    _need(args, 0, "uuid")
    import uuid as _uuid
    return str(_uuid.uuid4())


# ---- random numbers you can seed (the same generator as native builds) --------
# xorshift64: random_seed(42) gives the same numbers in the interpreter and in a
# compiled program.

_M64 = (1 << 64) - 1
_RNG = [0]


def _rng():
    s = _RNG[0]
    if not s:
        s = (int(time.time()) ^ (os.getpid() << 32) ^ 0x9E3779B97F4A7C15) & _M64
    s ^= (s << 13) & _M64
    s ^= s >> 7
    s ^= (s << 17) & _M64
    _RNG[0] = s
    return s


def b_random_seed(args):
    _need(args, 1, "random_seed")
    s = (int_arg(args[0], "random_seed") ^ 0x9E3779B97F4A7C15) & _M64
    _RNG[0] = s or 0x9E3779B97F4A7C15
    return None


def b_random2(args):
    _need(args, 2, "random")
    low, high = int_arg(args[0], "random"), int_arg(args[1], "random")
    if low > high:
        raise VantaError("random needs the low number first")
    return low + _rng() % (high - low + 1)


def b_random_float2(args):
    _need(args, 0, "random_float")
    return (_rng() >> 11) / 9007199254740992.0


def b_shuffle2(args):
    _need(args, 1, "shuffle")
    if not isinstance(args[0], list):
        raise VantaError("shuffle needs a list")
    out = list(args[0])
    for i in range(len(out) - 1, 0, -1):
        j = _rng() % (i + 1)
        out[i], out[j] = out[j], out[i]
    return out


def b_pick2(args):
    _need(args, 1, "pick")
    if not isinstance(args[0], list) or not args[0]:
        raise VantaError("pick needs a non-empty list")
    return args[0][_rng() % len(args[0])]


# ---- math extras and statistics ----------------------------------------------

def _ints(args, name):
    vals = args[0] if len(args) == 1 and isinstance(args[0], list) else args
    if not vals:
        raise VantaError(f"{name} needs at least one number")
    return [int_arg(v, name) for v in vals]


def b_gcd(args):
    r = 0
    for v in _ints(args, "gcd"):
        r = math.gcd(r, v)
    return r


def b_lcm(args):
    r = 1
    for v in _ints(args, "lcm"):
        r = abs(r * v) // math.gcd(r, v) if r and v else 0
    return r


def b_factorial(args):
    _need(args, 1, "factorial")
    n = int_arg(args[0], "factorial")
    if n < 0:
        raise VantaError("factorial needs a whole number of 0 or more")
    return math.factorial(n)


def b_isqrt(args):
    _need(args, 1, "isqrt")
    n = int_arg(args[0], "isqrt")
    if n < 0:
        raise VantaError("isqrt needs a whole number of 0 or more")
    return math.isqrt(n)


def _nums(args, name, least=1):
    _need(args, 1, name)
    if not isinstance(args[0], list):
        raise VantaError(f"{name} needs a list of numbers")
    vals = [num_arg(v, name) for v in args[0]]
    if len(vals) < least:
        raise VantaError(f"{name} needs at least {'one value' if least == 1 else 'two values'}")
    return vals


def _mean(vals):
    t = 0.0
    for v in vals:              # a plain left-to-right sum: the same digits as native builds
        t += v
    return t / len(vals)


def b_mean(args):
    return tidy_number(_mean(_nums(args, "mean")))


def b_median(args):
    vals = sorted(_nums(args, "median"))
    n = len(vals)
    if n % 2:
        return vals[n // 2]
    return tidy_number((vals[n // 2 - 1] + vals[n // 2]) / 2)


def _variance(vals):
    m = _mean(vals)
    t = 0.0
    for v in vals:
        t += (v - m) * (v - m)
    return t / (len(vals) - 1)


def b_variance(args):
    return tidy_number(_variance(_nums(args, "variance", 2)))


def b_stdev(args):
    return tidy_number(math.sqrt(_variance(_nums(args, "stdev", 2))))


def b_mode(args):
    _need(args, 1, "mode")
    if not isinstance(args[0], list) or not args[0]:
        raise VantaError("mode needs a non-empty list")
    best, best_n = None, 0
    for i, v in enumerate(args[0]):
        n = sum(1 for x in args[0] if x == v)
        if n > best_n:
            best, best_n = v, n
    return best


# ---- SQLite -----------------------------------------------------------------

class _DB:
    def __init__(self, conn):
        self.conn = conn

    def close(self):
        self.conn.close()


def _db_params(p):
    def conv(v):
        if v is None or isinstance(v, (str, float)) or (isinstance(v, int) and not isinstance(v, bool)):
            return v
        if isinstance(v, bool):
            return int(v)
        if isinstance(v, bytearray):
            return bytes(v)
        raise VantaError("database values must be numbers, text, bytes, yes/no or nothing")
    if p is None:
        return ()
    if isinstance(p, list):
        return tuple(conv(v) for v in p)
    if isinstance(p, dict):
        return {display(k): conv(v) for k, v in p.items()}
    raise VantaError("database parameters must be a list (for ?) or a map (for :name)")


def _db_value(v):
    if isinstance(v, bytes):
        return bytearray(v)
    return v


def b_db_open(args):
    _need(args, 1, "db_open")
    import sqlite3
    path = display(args[0])
    try:
        conn = sqlite3.connect(path if path == ":memory:" else os.path.expanduser(path),
                               isolation_level=None, check_same_thread=False)
    except sqlite3.Error as e:
        raise VantaError(f"database error: {e}")
    return Handle("database", _DB(conn))


def b_db_query(args):
    _arity(args, 2, 3, "db_query expects a database, SQL and optional parameters")
    import sqlite3
    db = _handle(args[0], "database", "db_query")
    try:
        cur = db.conn.execute(display(args[1]), _db_params(_opt(args, 2)))
        if cur.description is None:
            return []
        cols = [d[0] for d in cur.description]
        return [{c: _db_value(v) for c, v in zip(cols, row)} for row in cur.fetchall()]
    except sqlite3.Error as e:
        raise VantaError(f"database error: {e}")


def b_db_execute(args):
    _arity(args, 2, 3, "db_execute expects a database, SQL and optional parameters")
    import sqlite3
    db = _handle(args[0], "database", "db_execute")
    try:
        before = db.conn.total_changes
        if len(args) == 3 and args[2] is not None:
            db.conn.execute(display(args[1]), _db_params(args[2]))
        else:
            db.conn.executescript(display(args[1]))
        return db.conn.total_changes - before
    except sqlite3.Error as e:
        raise VantaError(f"database error: {e}")


def b_db_last_id(args):
    _need(args, 1, "db_last_id")
    import sqlite3
    db = _handle(args[0], "database", "db_last_id")
    try:
        return db.conn.execute("select last_insert_rowid()").fetchone()[0]
    except sqlite3.Error as e:
        raise VantaError(f"database error: {e}")


# ---- type names for handles --------------------------------------------------

def b_type_of2(args):
    _need(args, 1, "type_of")
    if isinstance(args[0], Handle):
        return args[0].kind
    return type_name(args[0])


_typeof_before = BUILTINS["typeof"]


def b_typeof2(args):
    if len(args) == 1 and isinstance(args[0], Handle):
        return args[0].kind
    return _typeof_before(args)


BUILTINS.update({
    # concurrency
    "spawn": b_spawn, "wait": b_wait, "is_done": b_is_done, "channel": b_channel, "new_lock": b_new_lock,
    "run_parallel": b_run_parallel,
    # polymorphic I/O
    "send": b_send, "receive": b_receive, "receive_bytes": b_receive_bytes, "read_line": b_read_line,
    "read_all": b_read_all, "write_to": b_write_to, "close": b_close,
    # networking
    "tcp_connect": b_tcp_connect, "tcp_listen": b_tcp_listen, "accept": b_accept, "set_timeout": b_set_timeout,
    "socket_info": b_socket_info, "udp_open": b_udp_open, "udp_send": b_udp_send, "udp_receive": b_udp_receive,
    "dns_lookup": b_dns_lookup, "ws_connect": b_ws_connect,
    # HTTP server
    "serve": b_serve2, "start_server": b_start_server, "server_port": b_server_port, "stop_server": b_stop_server,
    "json_response": b_json_response, "redirect": b_redirect,
    # processes, environment, signals
    "run_process": b_run_process, "open_process": b_open_process, "close_input": b_close_input,
    "process_errors": b_process_errors, "kill_process": b_kill_process, "process_id": b_process_id,
    "env": b_env2, "set_env": b_set_env, "env_vars": b_env_vars, "on_signal": b_on_signal,
    "send_signal": b_send_signal, "exit": b_exit,
    # files
    "open_file": b_open_file, "read_chunk": b_read_chunk, "read_chunk_bytes": b_read_chunk_bytes,
    "seek": b_seek, "tell": b_tell, "walk_dir": b_walk_dir, "glob": b_glob, "matches_pattern": b_matches_pattern,
    "temp_file": b_temp_file, "temp_dir": b_temp_dir, "absolute_path": b_absolute_path,
    "current_dir": b_current_dir, "change_dir": b_change_dir,
    # data
    "csv_parse": b_csv_parse, "csv_format": b_csv_format, "csv_read": b_csv_read, "csv_write": b_csv_write,
    "csv_read_maps": b_csv_read_maps, "csv_write_maps": b_csv_write_maps, "to_json": b_to_json2,
    "format_date": b_format_date2, "parse_date": b_parse_date2, "date_parts": b_date_parts,
    "make_date": b_make_date, "days": b_days, "hours": b_hours, "minutes": b_minutes,
    "format_duration": b_format_duration, "timezone": b_timezone,
    "regex_search": b_regex_search, "regex_split": b_regex_split, "regex_escape": b_regex_escape,
    "compress": b_compress, "decompress": b_decompress, "gzip": b_gzip, "gunzip": b_gunzip,
    "bytes_to_text": b_bytes_to_text, "md5": b_md5_2, "sha1": b_sha1, "sha256": b_sha256_2, "hmac": b_hmac,
    "uuid": b_uuid, "random_seed": b_random_seed, "random": b_random2, "random_float": b_random_float2,
    "shuffle": b_shuffle2, "pick": b_pick2,
    "gcd": b_gcd, "lcm": b_lcm, "factorial": b_factorial, "isqrt": b_isqrt, "mean": b_mean,
    "median": b_median, "variance": b_variance, "stdev": b_stdev, "mode": b_mode,
    "db_open": b_db_open, "db_query": b_db_query, "db_execute": b_db_execute, "db_last_id": b_db_last_id,
    "type_of": b_type_of2, "typeof": b_typeof2,
})


def b_say(args):
    """say(x) as a function, for lambdas: make p give say(p)"""
    print(" ".join(display(a) for a in args))
    return None


BUILTINS["say"] = b_say


def _sets_as_lists(fn):
    """Builtins that work on lists accept sets too (as a list, in the order the items were added)."""
    def wrapped(args):
        return fn([a.values() if type(a) is VantaSet else a for a in args])
    return wrapped


for _name in ("sum", "product", "min", "max", "sort", "sort_by", "join", "map", "keep", "reduce", "each",
              "count_where", "find_where", "any_where", "all_where", "first", "last", "unique", "reverse",
              "zip", "flatten", "chunk", "shuffle", "pick", "index_of", "last_index_of"):
    if _name in BUILTINS:
        BUILTINS[_name] = _sets_as_lists(BUILTINS[_name])

# A first-class value for every builtin, so they can be passed to map/keep/etc.
BUILTINS["__vanta_expect"] = b_vanta_expect     # what `expect ...` lines call (testing)
BUILTIN_VALUES = {name: Builtin(name, fn) for name, fn in BUILTINS.items()}


# ===========================================================================
# SHARED HELPERS
# ===========================================================================

def type_name(value):
    if value is None:
        return "nothing"
    if isinstance(value, bool):
        return "yes-no"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "text"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "map"
    if isinstance(value, bytearray):
        return "bytes"
    if isinstance(value, (Function, Builtin, BoundMethod)):
        return "function"
    if isinstance(value, VantaType):
        return "type"
    if isinstance(value, VantaInstance):
        return value.vtype.name
    if isinstance(value, VantaSet):
        return "set"
    if isinstance(value, EnumMember):
        return value.kind.name
    if isinstance(value, VantaEnum):
        return "kind"
    if isinstance(value, VantaGenerator):
        return "generator"
    if isinstance(value, VantaModule):
        return "module"
    return "value"


def truthy(value):
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, (str, list, dict, bytearray, VantaSet)):
        return len(value) > 0
    return True


def display(value):
    if value is None:
        return "nothing"
    if value is True:
        return "yes"
    if value is False:
        return "no"
    if isinstance(value, float) and value == int(value):
        return str(int(value))
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "[" + ", ".join(display_item(x) for x in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(display_item(_unkey(k)) + ": " + display_item(v)
                               for k, v in value.items()) + "}"
    if isinstance(value, bytearray):          # bytes[34 12 ff], long ones shortened
        shown = " ".join(f"{x:02x}" for x in value[:32])
        return f"bytes[{shown}{' …' if len(value) > 32 else ''}]"
    if isinstance(value, Function):
        return f"<function {value.name}>"
    if isinstance(value, Builtin):
        return f"<builtin {value.name}>"
    if isinstance(value, BoundMethod):
        return f"<method {value.fn.name}>"
    if isinstance(value, VantaType):
        return f"<type {value.name}>"
    if isinstance(value, EnumMember):
        return value.name
    if isinstance(value, VantaSet):
        return "set([" + ", ".join(display_item(x) for x in value.values()) + "])"
    if isinstance(value, VantaEnum):
        return f"<kind {value.name}>"
    if isinstance(value, VantaGenerator):
        return f"<generator {value.name}>"
    if isinstance(value, VantaModule):
        return f"<module {value.name}>"
    if isinstance(value, VantaInstance):
        vt = value.vtype
        method = vt.methods.get("text")             # a text() (or show()) method decides how it prints
        if method is None or method.shared or len(method.params) != 0:
            method = vt.methods.get("show")
        if method is not None and not method.shared and len(method.params) == 0:
            return display(call_method(value, method, []))
        inner = ", ".join(f"{f}=" + display_item(value.attrs.get(f)) for f in vt.fields)
        return f"{vt.name}({inner})"
    return str(value)


def display_item(value):
    if isinstance(value, str):
        return '"' + value + '"'
    return display(value)


def smart_value(text):
    try:
        return int(text)
    except ValueError:
        try:
            return float(text)
        except ValueError:
            return text


RESERVED = {"if", "end", "otherwise", "repeat", "while", "for", "each", "in",
            "to", "give", "back", "say", "let", "change", "ask", "stop",
            "skip", "import", "is", "be", "and", "or", "not", "yes", "no",
            "nothing", "times", "at", "type", "has", "attempt", "rescue", "new",
            "from", "super", "match", "when", "increase", "decrease", "by",
            "make", "fix",
            # word operators and the yes/no words read as values, so they can't be names either
            "plus", "minus", "xor", "true", "false", "Yes", "No", "True", "False", "Nothing"}


def check_name(name, lineno):
    if not name or not (name[0].isalpha() or name[0] == "_"):
        raise VantaError(f"line {lineno}: '{name}' is not a valid name")
    if not all(c.isalnum() or c == "_" for c in name):
        raise VantaError(f"line {lineno}: '{name}' is not a valid name")
    if name in RESERVED:
        raise VantaError(f"line {lineno}: '{name}' is a reserved word, "
                         f"pick another name")


def _escape_for_single_line(s):
    """Make raw triple-quoted text survive the single-line string tokenizer AND the
    {expr} interpolation pass verbatim: double backslashes, escape quotes, turn braces
    literal ({{/}}), and fold newlines/tabs into \\n / \\t."""
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("{", "{{").replace("}", "}}")
    s = s.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n").replace("\t", "\\t")
    return s


def expand_triple_strings(source):
    """Collapse \"\"\"...\"\"\" blocks (multi-line, RAW - braces are literal, no escapes
    needed) into a single-line \"...\" literal so the rest of the line-based pipeline is
    unchanged. Newlines consumed inside a block are re-emitted at the end of its line so
    error line numbers stay aligned. # comments and normal \"strings\" are left alone."""
    if '"""' not in source:
        return source
    out = []
    i, n = 0, len(source)
    pending = 0                               # blank lines owed to keep numbering aligned
    while i < n:
        c = source[i]
        if c == "\n":
            out.append("\n" * (1 + pending)); pending = 0; i += 1; continue
        if c == "#":                          # comment to end of line - copy verbatim
            j = source.find("\n", i)
            if j == -1: out.append(source[i:]); break
            out.append(source[i:j]); i = j; continue
        if c == '"':
            if source[i + 1:i + 3] == '""':   # triple-quoted block
                j = source.find('"""', i + 3)
                if j == -1:
                    raise VantaError('a triple-quoted (""") text value is missing its closing """')
                content = source[i + 3:j]
                pending += content.count("\n")
                out.append('"' + _escape_for_single_line(content) + '"')
                i = j + 3; continue
            j = i + 1                          # ordinary single-line string - copy verbatim
            while j < n and source[j] != '"':
                j += 2 if (source[j] == "\\" and j + 1 < n) else 1
            out.append(source[i:j + 1]); i = j + 1; continue
        out.append(c); i += 1
    if pending: out.append("\n" * pending)
    return "".join(out)


def load_lines(source):
    """Keep real line numbers; drop blank lines and # / note comments."""
    source = expand_triple_strings(source)    # multi-line """raw""" strings -> single line
    lines = []
    joining = False                           # the previous line goes on (open bracket / trailing operator)
    for i, raw in enumerate(source.splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#") or (first_word(text) == "note" and not joining):
            continue
        code, depth = _code_and_depth(text)
        if joining:
            prev_no, prev = lines[-1]
            text = prev + " " + code
            lines[-1] = (prev_no, text)
            code, depth = _code_and_depth(text)
        else:
            lines.append((i, text))
        joining = depth > 0 or _continues(code)
        if joining:
            lines[-1] = (lines[-1][0], code)  # drop a trailing comment so the next line can join
    return lines


_CONTINUE_WORDS = ("and", "or", "plus", "minus", "xor", "mod")


def _code_and_depth(text):
    """A line without its trailing # comment, and how many brackets are still open at its end."""
    depth, in_str, i = 0, False, 0
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
            return text[:i].rstrip(), depth
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return text, depth


def _continues(code):
    """Does a line end in something that needs more (an operator, a comma, an open bracket)?"""
    if not code:
        return False
    if code[-1] in "+-*/%^&|,([{" and not code.endswith('"'):
        return True
    last = code.rsplit(None, 1)[-1]
    return last in _CONTINUE_WORDS and len(code.split()) > 1


IMPORTED = set()
CURRENT_FILE = None     # the .va file being parsed/compiled (error traces, debugger)
DEBUG_HOOK = None       # set by `vanta debug`: called as hook(line, env, file) before each statement


def resolve_import(name, from_dir=None):
    """Find a module by name. Search order: the path as given (so existing
    relative imports keep working), then the bundled standard library in
    lib/, then installed packages in ~/.vanta/packages/, then next to the
    file doing the importing."""
    with_ext = name if name.endswith(".va") else name + ".va"
    here = os.path.dirname(os.path.abspath(__file__))
    packages = os.path.join(os.path.expanduser("~"), ".vanta", "packages")
    candidates = [
        name,
        with_ext,
        os.path.join(here, "lib", with_ext),
        os.path.join(packages, with_ext),
        os.path.join(packages, name, "main.va"),
    ] + ([os.path.join(from_dir, with_ext)] if from_dir else []) + package_candidates(name, from_dir)
    for path in candidates:
        if os.path.isfile(path):
            return path
    raise VantaError(f"could not find a module named '{name}'")


def package_candidates(name, from_dir=None):
    """Where `vanta get` installs packages: a project's ./packages folder (next to the
    running program or the current folder), then ~/.vanta/packages. A package folder's
    entry file is the "entry" in its vanta.json, else main.va, else NAME.va."""
    if name.endswith(".va") or "/" in name or "\\" in name:
        return []
    roots = []
    for base in (from_dir, os.path.dirname(CURRENT_FILE) if CURRENT_FILE else None, os.getcwd()):
        if base:
            d = os.path.join(base, "packages")
            if d not in roots:
                roots.append(d)
    roots.append(os.path.join(os.path.expanduser("~"), ".vanta", "packages"))
    out = []
    for root in roots:
        folder = os.path.join(root, name)
        manifest = os.path.join(folder, "vanta.json")
        if os.path.isfile(manifest):
            try:
                with open(manifest) as f:
                    entry = json.load(f).get("entry")
                if entry:
                    out.append(os.path.join(folder, entry))
            except (OSError, ValueError, AttributeError):
                pass
        out += [os.path.join(folder, "main.va"), os.path.join(folder, name + ".va"),
                os.path.join(root, name + ".va")]
    return out


def import_file(name, from_dir=None):
    path = os.path.abspath(resolve_import(name, from_dir))
    if path in IMPORTED:          # each module loads at most once
        return
    IMPORTED.add(path)
    try:
        with open(path, "r") as f:
            source = f.read()
    except OSError as e:
        raise VantaError(f"could not import {name}: {e}")
    global CURRENT_FILE
    saved, CURRENT_FILE = CURRENT_FILE, path
    try:
        code = compile_block(parse_program(load_lines(source)))
    finally:
        CURRENT_FILE = saved
    try:
        top_level_signal(code(GLOBAL_ENV))
    except VantaError as e:         # name the module in the error's call stack
        tb = getattr(e, "vtrace", None)
        if tb and tb[-1][1] is None:
            tb[-1][1], tb[-1][2] = "<module>", path
        e.vpending = True
        raise


MODULES = {}            # absolute path -> VantaModule (namespaced imports load once)


def module_env_of(env):
    """The top-level scope of the file that `env` belongs to (a module's, or the program's)."""
    e = env
    while e is not None:
        if e.is_module:
            return e
        e = e.parent
    return GLOBAL_ENV


def private_names(stmts):
    names = set()
    for st in stmts:
        if st[0] == "private":
            inner = st[2]
            if inner[0] in ("let", "fix", "func", "type", "enum"):
                names.add(inner[2])
    return names


def import_module(name, from_dir=None):
    """import "geometry" as geo: run the file in its own scope (once) and give back a module value.
    Its own plain `import`s still go to the shared global scope, which it can also see."""
    path = os.path.abspath(resolve_import(name, from_dir))
    mod = MODULES.get(path)
    if mod is not None:
        return mod
    try:
        with open(path, "r") as f:
            source = f.read()
    except OSError as e:
        raise VantaError(f"could not import {name}: {e}")
    global CURRENT_FILE
    saved, CURRENT_FILE = CURRENT_FILE, path
    try:
        stmts = parse_program(load_lines(source))
        code = compile_block(stmts)
    finally:
        CURRENT_FILE = saved
    env = Environment(GLOBAL_ENV)
    env.is_module = True
    mod = MODULES[path] = VantaModule(os.path.splitext(os.path.basename(path))[0], env, private_names(stmts))
    top_level_signal(code(env))
    return mod


def use_names(mod, names, env):
    """from "geometry" use area, Circle"""
    for nm in names:
        if nm in mod.private:
            raise VantaError(f"'{nm}' is private to the module '{mod.name}'")
        value = mod.env.vars.get(nm, _MISSING)
        if value is _MISSING:
            raise VantaError(f"the module '{mod.name}' has no '{nm}'")
        env.define(nm, value)


def add_to(value, target):
    """add VALUE to LIST / SET"""
    if isinstance(target, list):
        target.append(value)
    elif isinstance(target, VantaSet):
        target.add(value)
    else:
        raise VantaError("you can only 'add ... to' a list or a set")


def remove_from(value, target):
    """remove VALUE from SET / LIST (the first one) / MAP (that key)"""
    if isinstance(target, VantaSet):
        if not is_member(value, target):
            raise VantaError(f"{display_item(value)} is not in the set")
        del target.items[_key(value)]
    elif isinstance(target, list):
        for i, item in enumerate(target):
            if item == value:
                del target[i]
                return
        raise VantaError(f"{display_item(value)} is not in the list")
    elif isinstance(target, dict):
        if isinstance(value, (list, dict)) or _key(value) not in target:
            raise VantaError(f"this map has no key {display_item(value)}")
        del target[_key(value)]
    else:
        raise VantaError("you can only 'remove ... from' a set, list, or map")


def close_resource(value):
    """End of a `using` block: value.close() for an object, or the close builtin for a handle."""
    if value is None:
        return
    fn = object_method(value, "close")
    if fn is not None:
        call_method(value, fn, [])
        return
    closer = BUILTIN_VALUES.get("close")
    if closer is not None and not isinstance(value, (int, float, str, list, dict, bool)):
        apply_callable(closer, [value])
        return
    raise VantaError(f"'using' needs something that can be closed (an object with a close() method), "
                     f"not a {type_name(value)}")


def negate(value):
    fn = object_method(value, "negate")
    if fn is not None:                          # -obj -> obj.negate()
        return call_method(value, fn, [])
    raise VantaError("only numbers can be negative")


# words a `when a ...` pattern understands for the built-in kinds of value (checked with type_of)
TYPE_WORDS = {"number", "text", "list", "map", "set", "function", "nothing", "generator", "bytes",
              "module", "kind"}


def pattern_type_test(value, tname, tval):
    if isinstance(tval, VantaType):
        return is_instance_of(value, tval)
    if isinstance(tval, VantaEnum):
        return isinstance(value, EnumMember) and value.kind is tval
    if tname in TYPE_WORDS:
        return type_name(value) == tname
    raise VantaError(f"'{tname}' is not a type")


def compile_pattern(pat):
    """A when-pattern as f(value, env, binds) -> matched?  (binds collects the names it takes apart)"""
    tag = pat[0]
    if tag == "pat_value":
        c = compile_expr(pat[1])
        return lambda v, env, b: v == c(env)
    if tag == "pat_any":
        return lambda v, env, b: True
    if tag == "pat_bind":
        name = pat[1]
        def f(v, env, b):
            b[name] = v
            return True
        return f
    if tag == "pat_list":
        subs = [compile_pattern(p) for p in pat[1]]
        rest = pat[2]
        n = len(subs)
        def f(v, env, b):
            if not isinstance(v, list) or (len(v) != n if rest is None else len(v) < n):
                return False
            for sub, item in zip(subs, v):
                if not sub(item, env, b):
                    return False
            if rest is not None:
                b[rest] = v[n:]
            return True
        return f
    if tag == "pat_map":
        subs = [(compile_expr(k), compile_pattern(p)) for k, p in pat[1]]
        def f(v, env, b):
            if not isinstance(v, dict):
                return False
            for kc, sub in subs:
                key = _key(kc(env))
                if isinstance(key, (list, dict)) or key not in v or not sub(v[key], env, b):
                    return False
            return True
        return f
    if tag == "pat_type":
        tnode, fields = pat[1], pat[2]
        tname = tnode[1] if tnode[0] == "name" else None
        tget = compile_expr(tnode) if tnode[0] != "name" else None
        def f(v, env, b):
            if tget is not None:
                tval = tget(env)
            else:
                tval = env.get(tname)
                if tval is _MISSING:
                    tval = None
            if not pattern_type_test(v, tname, tval):
                return False
            for fld in fields:
                b[fld] = get_attr(v, fld)
            return True
        return f
    raise VantaError(f"internal error: unknown pattern {tag}")


def compile_when_test(vn):
    """One 'when' line as test(subject, env) -> bool (binding any names a pattern takes apart)."""
    if vn[0] == "anyof":
        parts = [compile_expr(v) for v in vn[1]]
        return lambda s, env: any(s == p(env) for p in parts)
    if vn[0] == "pattern":
        alts = [compile_pattern(p) for p in vn[1]]
        guard = compile_expr(vn[2]) if vn[2] is not None else None
        def test(s, env):
            for alt in alts:
                binds = {}
                if alt(s, env, binds):
                    env.vars.update(binds)
                    if guard is None or truthy(guard(env)):
                        return True
            return False
        return test
    one = compile_expr(vn)
    return lambda s, env: s == one(env)


# ===========================================================================
# COMPILER  (turn the AST into nested Python closures, once, so we never
# re-walk the tree at run time)
#
# The tree-walker above re-decides what every node means on every visit — that
# dispatch is the dominant cost. Here we compile each node ONCE into a small
# Python function `f(env)` that does exactly its job: the operator, the variable,
# the call are all resolved at compile time. The closures reuse every semantic
# helper above (arithmetic, compare, get_index, apply_callable, ...), so the
# behaviour is identical to the tree-walker — only the dispatch disappears.
# A Function caches its compiled body (see call_function); the tree-walker stays
# as the engine for the few rare statements we don't specialise (e.g. 'type').
# ===========================================================================

# Control flow inside compiled code travels as a returned *signal* instead of a
# raised exception (raising on every function return / loop break is slow). A
# compiled statement returns None to mean "carry on", a _Return to unwind a
# function, or the _BREAK / _CONTINUE singletons inside a loop. Blocks and loops
# below check for these and propagate them. (The tree-walker still uses the
# ReturnSignal/BreakLoop/ContinueLoop exceptions, but it's now the cold path.)
class _Return:
    __slots__ = ("value", "line")

    def __init__(self, value, line=0):
        self.value = value
        self.line = line


_BREAK = object()
_CONTINUE = object()


def lookup_name(env, name):
    e = env
    while e is not None:
        v = e.vars
        if name in v:
            return v[name]
        e = e.parent
    b = BUILTIN_VALUES.get(name, _MISSING)
    if b is not _MISSING:
        return b
    raise VantaError(f"I don't know what '{name}' is yet")


def compile_expr(node):
    tag = node[0]

    if tag == "lit":
        value = node[1]
        return lambda env: value

    if tag == "name":
        name = node[1]
        # the env-chain walk is inlined here (no helper call) — name lookup is
        # the single most frequent operation in almost any program
        def ev(env):
            e = env
            while e is not None:
                v = e.vars
                if name in v:
                    return v[name]
                e = e.parent
            b = BUILTIN_VALUES.get(name, _MISSING)
            if b is not _MISSING:
                return b
            raise VantaError(f"I don't know what '{name}' is yet")
        return ev

    if tag == "arith":
        op = node[1]
        a = compile_expr(node[2])
        b = compile_expr(node[3])
        if op == "+":
            def ev(env):
                x = a(env); y = b(env)
                if type(x) is int and type(y) is int:
                    return x + y
                return arithmetic("+", x, y)
            return ev
        if op == "-":
            def ev(env):
                x = a(env); y = b(env)
                if type(x) is int and type(y) is int:
                    return x - y
                return arithmetic("-", x, y)
            return ev
        if op == "*":
            def ev(env):
                x = a(env); y = b(env)
                if type(x) is int and type(y) is int:
                    return x * y
                return arithmetic("*", x, y)
            return ev
        if op in BIT_OPS:
            fast = {"&": lambda x, y: x & y, "|": lambda x, y: x | y, "xor": lambda x, y: x ^ y,
                    "<<": lambda x, y: x << y if y >= 0 else bit_op("<<", x, y),
                    ">>": lambda x, y: x >> y if y >= 0 else bit_op(">>", x, y)}[op]
            def ev(env):
                x = a(env); y = b(env)
                if type(x) is int and type(y) is int:
                    return fast(x, y)
                return bit_op(op, x, y)
            return ev
        return lambda env: arithmetic(op, a(env), b(env))

    if tag == "cmp":
        op = node[1]
        a = compile_expr(node[2])
        b = compile_expr(node[3])
        if op == "==":
            return lambda env: a(env) == b(env)
        if op == "!=":
            return lambda env: a(env) != b(env)
        if op == "<":
            def ev(env):
                x = a(env); y = b(env)
                tx = type(x); ty = type(y)
                if (tx is int or tx is float) and (ty is int or ty is float):
                    return x < y
                return compare("<", x, y)
            return ev
        if op == ">":
            def ev(env):
                x = a(env); y = b(env)
                tx = type(x); ty = type(y)
                if (tx is int or tx is float) and (ty is int or ty is float):
                    return x > y
                return compare(">", x, y)
            return ev
        if op == "<=":
            def ev(env):
                x = a(env); y = b(env)
                tx = type(x); ty = type(y)
                if (tx is int or tx is float) and (ty is int or ty is float):
                    return x <= y
                return compare("<=", x, y)
            return ev
        if op == ">=":
            def ev(env):
                x = a(env); y = b(env)
                tx = type(x); ty = type(y)
                if (tx is int or tx is float) and (ty is int or ty is float):
                    return x >= y
                return compare(">=", x, y)
            return ev
        return lambda env: compare(op, a(env), b(env))

    if tag == "call":
        callee_node = node[1]
        cargs = [compile_expr(a) for a in node[2]]
        if callee_node[0] == "name":
            name = callee_node[1]
            def ev(env):
                e = env
                while e is not None:
                    v = e.vars
                    if name in v:
                        return apply_callable(v[name], [a(env) for a in cargs])
                    e = e.parent
                callee = BUILTIN_VALUES.get(name, _MISSING)
                if callee is _MISSING:
                    raise VantaError(f"I don't know a function called '{name}'")
                return apply_callable(callee, [a(env) for a in cargs])
            return ev
        cf = compile_expr(callee_node)
        return lambda env: apply_callable(cf(env), [a(env) for a in cargs])

    if tag == "callkw":
        cf = compile_expr(node[1]) if node[1][0] != "name" else None
        cname = node[1][1] if cf is None else None
        cargs = [compile_expr(a) for a in node[2]]
        ckw = [(k, compile_expr(v)) for k, v in node[3]]
        def ev(env):
            callee = cf(env) if cf is not None else resolve_callee(("name", cname), env)
            return apply_callable(callee, [a(env) for a in cargs], [(k, v(env)) for k, v in ckw])
        return ev

    if tag == "fmtspec":
        a = compile_expr(node[1])
        spec = node[2]
        return lambda env: format_value(a(env), spec)

    if tag == "index":
        a = compile_expr(node[1])
        b = compile_expr(node[2])
        return lambda env: get_index(a(env), b(env))

    if tag == "getattr":
        a = compile_expr(node[1])
        attr = node[2]
        return lambda env: get_attr(a(env), attr)

    if tag == "format":
        parts = [compile_expr(p) for p in node[1]]
        return lambda env: "".join(display(p(env)) for p in parts)

    if tag == "list":
        items = [compile_expr(i) for i in node[1]]
        return lambda env: [i(env) for i in items]

    if tag == "map":
        pairs = [(compile_expr(k), compile_expr(v)) for k, v in node[1]]
        def ev(env):
            result = {}
            for k, v in pairs:
                result[_key(k(env))] = v(env)
            return result
        return ev

    if tag == "and":
        a = compile_expr(node[1]); b = compile_expr(node[2])
        def ev(env):
            if not truthy(a(env)):
                return False
            return truthy(b(env))
        return ev

    if tag == "or":
        a = compile_expr(node[1]); b = compile_expr(node[2])
        def ev(env):
            if truthy(a(env)):
                return True
            return truthy(b(env))
        return ev

    if tag == "not":
        a = compile_expr(node[1])
        return lambda env: not truthy(a(env))

    if tag == "bitnot":
        a = compile_expr(node[1])
        return lambda env: bit_not(a(env))

    if tag == "neg":
        a = compile_expr(node[1])
        def ev(env):
            value = a(env)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                return negate(value)
            return -value
        return ev

    if tag == "ternary":
        c = compile_expr(node[1]); t = compile_expr(node[2]); f = compile_expr(node[3])
        return lambda env: t(env) if truthy(c(env)) else f(env)

    if tag == "in":
        a = compile_expr(node[1]); b = compile_expr(node[2])
        return lambda env: is_member(a(env), b(env))

    if tag == "notin":
        a = compile_expr(node[1]); b = compile_expr(node[2])
        return lambda env: not is_member(a(env), b(env))

    if tag == "isa":
        val = compile_expr(node[1]); target = compile_expr(node[2])
        def ev(env):
            t = target(env)
            if not isinstance(t, (VantaType, VantaEnum)):
                raise VantaError("the right side of 'is a' must be a type")
            return is_instance_of(val(env), t)
        return ev

    if tag == "lambda":
        params = [(name, None) for name in node[1]]
        body_ast = [("return", 0, node[2])]
        compiled_body = compile_block(body_ast)
        src_file = CURRENT_FILE
        def ev(env):
            fn = Function("<anonymous>", params, body_ast)
            fn.compiled = compiled_body
            fn.defining_env = env
            fn.file = src_file
            return fn
        return ev

    if tag == "listcomp":
        _, out_expr, var, iter_expr, cond = node
        out = compile_expr(out_expr)
        itr = compile_expr(iter_expr)
        cnd = compile_expr(cond) if cond is not None else None
        if isinstance(var, list):              # [i for each i, x in xs]
            v1, v2 = var
            def ev(env):
                loop_env = Environment(env)
                lv = loop_env.vars
                result = []
                for a, b in iterate_pairs(itr(env)):
                    lv[v1] = a
                    lv[v2] = b
                    if cnd is None or truthy(cnd(loop_env)):
                        result.append(out(loop_env))
                return result
            return ev
        def ev(env):
            loop_env = Environment(env)
            lv = loop_env.vars
            result = []
            for item in iterate(itr(env)):
                lv[var] = item
                if cnd is None or truthy(cnd(loop_env)):
                    result.append(out(loop_env))
            return result
        return ev

    if tag == "mapcomp":
        _, key_expr, val_expr, var, iter_expr, cond = node
        kc = compile_expr(key_expr)
        vc = compile_expr(val_expr)
        itr = compile_expr(iter_expr)
        cnd = compile_expr(cond) if cond is not None else None
        def ev(env):
            loop_env = Environment(env)
            lv = loop_env.vars
            result = {}
            if isinstance(var, list):          # {k: v for each k, v in m}
                for a, b in iterate_pairs(itr(env)):
                    lv[var[0]] = a
                    lv[var[1]] = b
                    if cnd is None or truthy(cnd(loop_env)):
                        result[_key(kc(loop_env))] = vc(loop_env)
                return result
            for item in iterate(itr(env)):
                lv[var] = item
                if cnd is None or truthy(cnd(loop_env)):
                    result[_key(kc(loop_env))] = vc(loop_env)
            return result
        return ev

    if tag == "sliceop":
        target = compile_expr(node[1])
        s = compile_expr(node[2]) if node[2] is not None else None
        e = compile_expr(node[3]) if node[3] is not None else None
        def ev(env):
            t = target(env)
            if not isinstance(t, (list, str, bytearray)):
                raise VantaError("you can only slice a list, text, or bytes")
            start = s(env) if s is not None else None
            end = e(env) if e is not None else None
            for bound in (start, end):
                if bound is not None and (isinstance(bound, bool) or not isinstance(bound, int)):
                    raise VantaError("slice positions must be whole numbers")
            return t[start:end]
        return ev

    # anything we didn't specialise: fall back to the tree-walker (correct, rare)
    return lambda env: eval_expr(node, env)


def compile_stmt(stmt):
    tag = stmt[0]

    if tag == "expr":
        n = compile_expr(stmt[2])
        def ex(env):
            n(env)
        return ex

    if tag == "let":
        name = stmt[2]; v = compile_expr(stmt[3])
        def ex(env):
            if name in env.consts:             # `fix X` then `let X` would quietly undo the fix
                raise VantaError(f"'{name}' is fixed and can't be changed")
            env.vars[name] = v(env)
        return ex

    if tag == "assign":
        target = stmt[2]; v = compile_expr(stmt[3])
        ttag = target[0]
        if ttag == "name":
            name = target[1]
            def ex(env):
                result = env.assign(name, v(env))
                if result == "const":
                    raise VantaError(f"'{name}' is fixed and can't be changed")
                if not result:
                    raise VantaError(f"'{name}' doesn't exist yet "
                                     f"(use: let {name} be ...)")
            return ex
        if ttag == "index":
            coll = compile_expr(target[1]); idx = compile_expr(target[2])
            def ex(env):
                set_index(coll(env), idx(env), v(env))
            return ex
        if ttag == "getattr":
            obj = compile_expr(target[1]); attr = target[2]
            def ex(env):
                set_attr(obj(env), attr, v(env))
            return ex
        return lambda env: do_assign(target, v(env), env)

    if tag == "if":
        branches = [(compile_expr(c), compile_block(body)) for c, body in stmt[2]]
        else_body = compile_block(stmt[3])
        def ex(env):
            for cond, body in branches:
                if truthy(cond(env)):
                    return body(env)
            return else_body(env)
        return ex

    if tag == "return":
        v = compile_expr(stmt[2])
        line = stmt[1]
        def ex(env):
            return _Return(v(env), line)
        return ex

    if tag == "say":
        node = stmt[2]
        if node is None:
            return lambda env: print("")
        n = compile_expr(node)
        return lambda env: print(display(n(env)))

    if tag == "mutate":
        _, _, target_node, sign, amount_node = stmt
        tget = compile_expr(target_node)
        amt = compile_expr(amount_node)
        def ex(env):
            new_value = mutate_value(sign, tget(env), amt(env))
            do_assign(target_node, new_value, env)
        return ex

    if tag == "while":
        cond = compile_expr(stmt[2]); body = compile_block(stmt[3])
        def ex(env):
            while truthy(cond(env)):
                sig = body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig            # a _Return — unwind the function
            return None
        return ex

    if tag == "foreach":
        _, _, name, iter_node, body_ast = stmt
        itr = compile_expr(iter_node); body = compile_block(body_ast)
        def ex(env):
            lv = env.vars
            for item in iterate(itr(env)):
                lv[name] = item
                sig = body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "foreach2":
        _, _, name1, name2, iter_node, body_ast = stmt
        itr = compile_expr(iter_node); body = compile_block(body_ast)
        def ex(env):
            lv = env.vars
            for first, second in iterate_pairs(itr(env)):
                lv[name1] = first
                lv[name2] = second
                sig = body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "repeat":
        cnt = compile_expr(stmt[2]); body = compile_block(stmt[3])
        def ex(env):
            count = cnt(env)
            if not isinstance(count, int) or isinstance(count, bool):
                raise VantaError("repeat needs a whole number of times")
            for _ in range(count):
                sig = body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "func":
        _, _, name, params, body_ast = stmt
        compiled_body = compile_function_body(name, body_ast)
        src_file = CURRENT_FILE
        def ex(env):
            fn = Function(name, params, body_ast)
            fn.compiled = compiled_body
            fn.defining_env = env
            fn.file = src_file
            env.vars[name] = fn
        return ex

    if tag == "fix":
        name = stmt[2]; v = compile_expr(stmt[3])
        def ex(env):
            env.fix(name, v(env))
        return ex

    if tag == "append":
        v = compile_expr(stmt[2]); t = compile_expr(stmt[3])
        def ex(env):
            value = v(env); target = t(env)
            if type(target) is list:
                target.append(value)
            else:
                add_to(value, target)
        return ex

    if tag == "using":
        _, _, name, value_node, body_ast = stmt
        v = compile_expr(value_node); body = compile_block(body_ast)
        def ex(env):
            resource = v(env)
            env.vars[name] = resource
            try:
                sig = body(env)
            except BaseException:
                close_resource(resource)
                raise
            close_resource(resource)
            return sig
        return ex

    if tag == "private":
        return compile_stmt(stmt[2])

    if tag == "match":
        subj = compile_expr(stmt[2])
        branches = [(compile_when_test(vn), compile_block(b)) for vn, b in stmt[3]]
        else_body = compile_block(stmt[4])
        def ex(env):
            s = subj(env)
            for test, body in branches:
                if test(s, env):
                    return body(env)
            return else_body(env)
        return ex

    if tag == "attempt":
        _, _, body_ast, errname, rescue_ast = stmt
        body = compile_block(body_ast); rescue = compile_block(rescue_ast)
        def ex(env):
            try:
                return body(env)
            except VantaError as e:
                env.vars[errname] = clean_message(str(e))
                return rescue(env)
        return ex

    if tag == "stop":
        return lambda env: _BREAK

    if tag == "skip":
        return lambda env: _CONTINUE

    if tag == "import":
        imp = compile_expr(stmt[2])
        src_dir = os.path.dirname(CURRENT_FILE) if CURRENT_FILE else None
        return lambda env: import_file(display(imp(env)), src_dir)

    if tag == "import_as":
        imp = compile_expr(stmt[2]); alias = stmt[3]
        src_dir = os.path.dirname(CURRENT_FILE) if CURRENT_FILE else None
        def ex(env):
            env.vars[alias] = import_module(display(imp(env)), src_dir)
        return ex

    if tag == "use":
        imp = compile_expr(stmt[2]); names = stmt[3]
        src_dir = os.path.dirname(CURRENT_FILE) if CURRENT_FILE else None
        return lambda env: use_names(import_module(display(imp(env)), src_dir), names, env)

    if tag == "lock":                  # lock [LOCK] ... end — released even on errors and 'give back'
        target = compile_expr(stmt[2]) if stmt[2] is not None else None
        body = compile_block(stmt[3])
        def ex(env):
            lk = _lock_of(target(env) if target is not None else None)
            lk.acquire()
            try:
                return body(env)
            finally:
                lk.release()
        return ex

    # rare statements (type definitions, multi-assign, ask): reuse the proven
    # tree-walker — these run once or seldom and aren't on any hot path.
    return lambda env: _run_stmt(stmt, env)


def compile_block(stmts):
    compiled = [(compile_stmt(s), s[1]) for s in stmts]

    hook = DEBUG_HOOK
    if hook is not None:
        # `vanta debug`: call the debugger before every statement. Chosen when the
        # block is compiled, so normal runs pay nothing for it.
        src_file = CURRENT_FILE
        def run_dbg(env):
            for ex, lineno in compiled:
                hook(lineno, env, src_file)
                try:
                    sig = ex(env)
                except VantaError as e:
                    raise _at_line(e, lineno)
                if sig is not None:
                    return sig
            return None
        return run_dbg

    if len(compiled) == 1:
        # the common case (an if-branch, a one-line loop body) — skip the loop
        only, ln = compiled[0]
        def run_one(env):
            try:
                return only(env)
            except VantaError as e:
                if str(e).startswith("line ") and not getattr(e, "vpending", False):
                    raise
                raise _at_line(e, ln)
        return run_one

    def run(env):
        for ex, lineno in compiled:
            try:
                sig = ex(env)
            except VantaError as e:
                if str(e).startswith("line ") and not getattr(e, "vpending", False):
                    raise
                raise _at_line(e, lineno)
            if sig is not None:
                return sig          # _Return / _BREAK / _CONTINUE — propagate up
        return None
    return run


# ---------------------------------------------------------------------------
# Generators: a function whose body uses `yield` is compiled a second way, into
# Python generator functions. Each compiled statement is then a generator that
# yields the Vanta values handed out and *returns* the usual control signal.
# Statements that can't yield reuse the ordinary compiled closure.
# ---------------------------------------------------------------------------

def compile_block_gen(stmts):
    compiled = []
    for st in stmts:
        if body_yields([st]):
            compiled.append((True, compile_stmt_gen(st), st[1]))
        else:
            compiled.append((False, compile_stmt(st), st[1]))

    def run(env):
        for is_gen, ex, lineno in compiled:
            try:
                sig = (yield from ex(env)) if is_gen else ex(env)
            except VantaError as e:
                raise _at_line(e, lineno)
            if sig is not None:
                return sig
        return None
    return run


def compile_stmt_gen(stmt):
    tag = stmt[0]

    if tag == "yield":
        v = compile_expr(stmt[2])
        def ex(env):
            yield v(env)
            return None
        return ex

    if tag == "if":
        branches = [(compile_expr(c), compile_block_gen(b)) for c, b in stmt[2]]
        else_body = compile_block_gen(stmt[3])
        def ex(env):
            for cond, body in branches:
                if truthy(cond(env)):
                    return (yield from body(env))
            return (yield from else_body(env))
        return ex

    if tag == "while":
        cond = compile_expr(stmt[2]); body = compile_block_gen(stmt[3])
        def ex(env):
            while truthy(cond(env)):
                sig = yield from body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "repeat":
        cnt = compile_expr(stmt[2]); body = compile_block_gen(stmt[3])
        def ex(env):
            count = cnt(env)
            if not isinstance(count, int) or isinstance(count, bool):
                raise VantaError("repeat needs a whole number of times")
            for _ in range(count):
                sig = yield from body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "foreach":
        _, _, name, iter_node, body_ast = stmt
        itr = compile_expr(iter_node); body = compile_block_gen(body_ast)
        def ex(env):
            for item in iterate(itr(env)):
                env.vars[name] = item
                sig = yield from body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "foreach2":
        _, _, name1, name2, iter_node, body_ast = stmt
        itr = compile_expr(iter_node); body = compile_block_gen(body_ast)
        def ex(env):
            for first, second in iterate_pairs(itr(env)):
                env.vars[name1] = first
                env.vars[name2] = second
                sig = yield from body(env)
                if sig is not None:
                    if sig is _CONTINUE:
                        continue
                    if sig is _BREAK:
                        break
                    return sig
            return None
        return ex

    if tag == "match":
        subj = compile_expr(stmt[2])
        branches = [(compile_when_test(vn), compile_block_gen(b)) for vn, b in stmt[3]]
        else_body = compile_block_gen(stmt[4])
        def ex(env):
            s = subj(env)
            for test, body in branches:
                if test(s, env):
                    return (yield from body(env))
            return (yield from else_body(env))
        return ex

    if tag == "attempt":
        _, _, body_ast, errname, rescue_ast = stmt
        body = compile_block_gen(body_ast); rescue = compile_block_gen(rescue_ast)
        def ex(env):
            try:
                return (yield from body(env))
            except VantaError as e:
                env.vars[errname] = clean_message(str(e))
            return (yield from rescue(env))
        return ex

    if tag == "using":
        _, _, name, value_node, body_ast = stmt
        v = compile_expr(value_node); body = compile_block_gen(body_ast)
        def ex(env):
            resource = v(env)
            env.vars[name] = resource
            try:
                sig = yield from body(env)
            except VantaError:                  # (a generator left unfinished never closes: same as native)
                close_resource(resource)
                raise
            close_resource(resource)
            return sig
        return ex

    raise VantaError(f"internal error: can't yield inside {tag}")


# ===========================================================================
# ENTRY POINT
# ===========================================================================

GLOBAL_ENV = Environment()
GLOBAL_ENV.define("pi", math.pi)
GLOBAL_ENV.define("e", math.e)


def reset_runtime():
    """Clear all program state so a host (REPL, IDE, playground) can run a
    fresh program without restarting the interpreter."""
    GLOBAL_ENV.vars.clear()
    if type(GLOBAL_ENV.consts) is not frozenset:
        GLOBAL_ENV.consts.clear()
    GLOBAL_ENV.define("pi", math.pi)
    GLOBAL_ENV.define("e", math.e)
    IMPORTED.clear()
    MODULES.clear()


def call_vanta(name, args):
    """Call a Vanta function (or builtin) by name from host code (used by the
    browser playground to drive the emulator). Returns the function's value."""
    fn = GLOBAL_ENV.get(name)
    if fn is _MISSING:
        fn = BUILTIN_VALUES.get(name, _MISSING)
    if fn is _MISSING:
        raise VantaError(f"no function named '{name}'")
    return apply_callable(fn, list(args))


_CANVAS_NAMES = None


def _canvas_names():
    """Builtins of the native canvas runtime (native/runtime/vcanvas.c) that the interpreter doesn't have."""
    global _CANVAS_NAMES
    if _CANVAS_NAMES is None:
        names = {"window", "canvas", "run_game", "next_frame"}
        try:
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "runtime", "vcanvas.c")) as f:
                src = f.read()
            tab = re.search(r"static const Entry canvas_table\[\] = \{(.*?)\n\};", src, re.S)
            if tab:
                names |= set(re.findall(r'\{"(\w+)",', tab.group(1)))
        except OSError:
            pass
        _CANVAS_NAMES = names - set(BUILTINS)
    return _CANVAS_NAMES


def is_canvas_program(source):
    """Does this program draw on a canvas (window, rect, draw_image, ... or the gui library)?"""
    if re.search(r'^\s*import\s+"(gui|game)(\.va)?"', source, re.M) and re.search(r"(?<![\w.])(window|canvas)\s*\(", source):
        return True
    defined = set(re.findall(r"^\s*to\s+(\w+)", source, re.M))
    for name in set(re.findall(r"(?<![\w.])([a-z_][a-z_0-9]*)\s*\(", source)):
        if name in _canvas_names() and name not in defined:
            return True
    return False


def run_canvas_natively(path, args):
    """Canvas programs need the native graphics runtime: build the program with native/vantac.py and run it."""
    import hashlib
    here = os.path.dirname(os.path.abspath(__file__))
    compiler = os.path.join(here, "native", "vantac.py")
    if not os.path.isfile(compiler):
        print("Oops! this program draws on a canvas, which needs the native compiler (native/vantac.py)")
        return 1
    cache = os.environ.get("VANTA_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "vanta")
    out_dir = os.path.join(cache, "run")
    os.makedirs(out_dir, exist_ok=True)
    full = os.path.abspath(path)
    exe = os.path.join(out_dir, os.path.splitext(os.path.basename(full))[0] + "-" + hashlib.sha1(full.encode()).hexdigest()[:8])
    sys.stderr.write(f"(canvas program: building {os.path.basename(path)} natively with native/vantac.py, then running it)\n")
    sys.stderr.flush()
    r = subprocess.run([sys.executable, compiler, path, "-o", exe])
    if r.returncode != 0:
        return r.returncode
    return subprocess.run([exe] + list(args)).returncode


def run_source(source, path=None):
    """Run a program (on a big-stack thread, so deep recursion works; see run_deep)."""
    if getattr(_DEEP, "active", False):
        return _run_source(source, path)
    return run_deep(_run_source, source, path)


def _run_source(source, path=None):
    global CURRENT_FILE
    if path is not None:
        CURRENT_FILE = os.path.abspath(path)
        if not os.environ.get("VANTA_INTERPRET") and is_canvas_program(source):
            sys.stdout.flush()
            sys.exit(run_canvas_natively(path, PROGRAM_ARGS))
    top_level_signal(compile_block(parse_program(load_lines(source)))(GLOBAL_ENV))


def top_level_signal(sig):
    """What a file's top level handed back: `give back` outside any function is an error."""
    if type(sig) is _Return:
        raise VantaError(f"line {sig.line}: 'give back' only works inside a function")


def repl():
    print(f"Vanta {VERSION} - type Vanta code, or 'bye' to quit.")
    buffer, depth = [], 0
    while True:
        try:
            line = input("...   " if buffer else "vanta> ")
        except EOFError:
            print()
            break
        text = line.strip()
        if not buffer and text in ("bye", "exit", "quit"):
            break
        if not buffer and (text == "" or text.startswith("#")):
            continue
        head = first_word(text)
        if head in BLOCK_OPENERS:
            depth += 1
        elif head == "end" and depth > 0:
            depth -= 1
        buffer.append(text)
        if depth == 0:
            program = "\n".join(buffer)
            buffer = []
            try:
                run_source(program)
            except VantaError as e:
                print(f"Oops! {e}")
            except (BreakLoop, ContinueLoop):
                print("Oops! 'stop'/'skip' only work inside a loop")
            except ReturnSignal:
                print("Oops! 'give back' only works inside a function")


USAGE = """\
Vanta - a plain-English programming language.

  vanta program.va [args]   run a program
  vanta run program.va      run a program (explicit form)
  vanta build program.va    compile to a native executable (add --run to run it)
  vanta repl                start the interactive REPL
  vanta version             print the version
  vanta help                show this message
"""


def main():
    """The `vanta` command. The commands themselves (run, repl, build, test, fmt, doc,
    new, get, check, debug, lsp, version, help) live in vanta_tools/cli.py.
    `vanta check` calls cmd_check(args) from this module if it is defined, otherwise
    vanta_tools/checker.py's main(V, args) if present, otherwise a syntax check."""
    global PROGRAM_ARGS
    args = sys.argv[1:]
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        if here not in sys.path:
            sys.path.insert(0, here)
        from vanta_tools import cli
    except ImportError:
        cli = None
    if cli is not None:
        sys.exit(cli.main(sys.modules[__name__], args))

    # Fallback when vanta.py is used on its own (without the vanta_tools folder).
    if not args or args[0] == "repl":
        repl()
        return
    command = args[0]
    if command in ("help", "--help", "-h"):
        print(USAGE)
        return
    if command in ("version", "--version", "-v"):
        print(f"Vanta {VERSION}")
        return
    if command == "run":
        if len(args) < 2:
            print("Usage: vanta run program.va")
            sys.exit(1)
        path, PROGRAM_ARGS = args[1], args[2:]
    else:
        path, PROGRAM_ARGS = args[0], args[1:]
    try:
        with open(path, "r") as f:
            source = f.read()
    except OSError as e:
        print(f"Oops! could not open {path}: {e}")
        sys.exit(1)
    try:
        run_source(source, path)
    except VantaError as e:
        print(f"Oops! {e}")
        sys.exit(1)


_DEEP = _threading.local()                    # .active: already on the big-stack thread
_DEEP.active = False


def run_deep(fn, *args):
    """Run fn on a thread with a big stack and a high recursion limit, so Vanta programs can recurse
    ~10,000+ levels deep; going deeper still is a normal (catchable) Vanta error, not a crash."""
    outcome = {}

    def target():
        _DEEP.active = True
        try:
            fn(*args)
        except BaseException as e:            # hand errors / sys.exit back to the main thread
            outcome["error"] = e
    old_limit = sys.getrecursionlimit()
    try:
        _threading.stack_size(512 * 1024 * 1024)
        worker = _threading.Thread(target=target, daemon=True)
        sys.setrecursionlimit(max(old_limit, 120000))
        worker.start()
    except (ValueError, RuntimeError):        # a platform without threads (the browser): just run here
        _DEEP.active = True
        try:
            return fn(*args)
        finally:
            _DEEP.active = False
    finally:
        try:
            _threading.stack_size(0)          # later threads (tasks, hotkeys) get the normal size
        except (ValueError, RuntimeError):
            pass
    try:
        while worker.is_alive():
            worker.join(0.25)
    except KeyboardInterrupt:
        sys.stdout.flush()
        os._exit(130)
    if "error" in outcome:
        raise outcome["error"]


if __name__ == "__main__":
    main()
