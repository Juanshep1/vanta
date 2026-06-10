#!/usr/bin/env python3
"""
Vanta - a real, plain-English programming language.

Vanta reads like English but is a genuine general-purpose language:
functions, recursion, lists, maps, loops, logic, file access, the ability to
run system commands, modules, and a standard library of built-in functions.

The whole language is this one file, built in the three classic stages:

  1. TOKENIZE  - chop text into little pieces (words, numbers, symbols)
  2. PARSE     - turn those pieces into a structure (an "abstract syntax tree")
  3. RUN       - walk that structure and actually do what it says

Run a file:   python3 vanta.py program.va
Start REPL:   python3 vanta.py
"""

import sys
import os
import shutil
import json
import time
import math
import subprocess
import random

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
    ("is", "not"): "!=",
    ("is", "over"): ">",
    ("is", "above"): ">",
    ("is", "under"): "<",
    ("is", "below"): "<",
    ("divided", "by"): "/",
    ("is",): "==",
    ("plus",): "+",
    ("minus",): "-",
    ("times",): "*",
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

        if c == '"':
            j = i + 1
            chars = []
            escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    chars.append(escapes.get(text[j + 1], text[j + 1]))
                    j += 2
                else:
                    chars.append(text[j])
                    j += 1
            if j >= n:
                raise VantaError('a text value is missing its closing quote (")')
            tokens.append(("STR", "".join(chars)))
            i = j + 1
            continue

        if c.isdigit():
            j, dot = i, False
            while j < n and (text[j].isdigit() or (text[j] == "." and not dot)):
                dot = dot or text[j] == "."
                j += 1
            chunk = text[i:j]
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
        if two in (">=", "<=", "==", "!="):
            tokens.append(("OP", two))
            i += 2
            continue
        if c in "+-*/%><":
            tokens.append(("OP", c))
            i += 1
            continue
        if c == "=":
            tokens.append(("OP", "=="))
            i += 1
            continue
        simple = {"(": "LP", ")": "RP", "[": "LB", "]": "RB",
                  "{": "LC", "}": "RC", ",": "COMMA", ":": "COLON"}
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
#   or  ->  and  ->  not  ->  comparison  ->  + -  ->  * / %  ->  unary -
#   ->  call()/index[]  ->  primary (number, text, name, list, map, group)

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
        return self.parse_or()

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
        left = self.parse_add_sub()
        k, v = self.peek()
        if k == "OP" and v in COMPARE_OPS:
            self.take()
            return ("cmp", v, left, self.parse_add_sub())
        return left

    def parse_add_sub(self):
        node = self.parse_mul_div()
        while self.peek()[0] == "OP" and self.peek()[1] in ("+", "-"):
            op = self.take()[1]
            node = ("arith", op, node, self.parse_mul_div())
        return node

    def parse_mul_div(self):
        node = self.parse_unary()
        while self.peek()[0] == "OP" and self.peek()[1] in ("*", "/", "%"):
            op = self.take()[1]
            node = ("arith", op, node, self.parse_unary())
        return node

    def parse_unary(self):
        if self.peek() == ("OP", "-"):
            self.take()
            return ("neg", self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            if self.peek()[0] == "LP":
                self.take()
                args = self.parse_list_until("RP")
                node = ("call", node, args)
            elif self.peek()[0] == "LB":
                self.take()
                index = self.parse_expression()
                self.expect("RB", "a closing ] is missing")
                node = ("index", node, index)
            else:
                return node

    def parse_primary(self):
        k, v = self.take()
        if k == "NUM" or k == "STR":
            return ("lit", v)
        if k == "NAME":
            low = v.lower()
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
            return ("list", self.parse_list_until("RB"))
        if k == "LC":
            return ("map", self.parse_map())
        raise VantaError("that line is missing a value somewhere")

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

    def parse_map(self):
        pairs = []
        if self.peek()[0] == "RC":
            self.take()
            return pairs
        while True:
            key = self.parse_expression()
            self.expect("COLON", "a map needs a : between key and value")
            value = self.parse_expression()
            pairs.append((key, value))
            k = self.take()[0]
            if k == "RC":
                return pairs
            if k != "COMMA":
                raise VantaError("expected a comma between map entries")

    def expect(self, kind, message):
        if self.take()[0] != kind:
            raise VantaError(message)


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

BLOCK_TERMINATORS = ("end", "otherwise")
BLOCK_OPENERS = ("if", "repeat", "while", "for", "to")


def first_word(line):
    return line.split(" ", 1)[0] if line else ""


def parse_program(lines):
    stmts, pos = parse_block(lines, 0)
    if pos != len(lines):
        raise VantaError(f"line {lines[pos][0]}: an extra "
                         f"'{first_word(lines[pos][1])}' has no matching block")
    return stmts


def parse_block(lines, pos):
    stmts = []
    while pos < len(lines):
        if first_word(lines[pos][1]) in BLOCK_TERMINATORS:
            return stmts, pos
        stmt, pos = parse_one(lines, pos)
        stmts.append(stmt)
    return stmts, pos


def parse_one(lines, pos):
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
        name, _, iter_text = after.partition(" in ")
        check_name(name.strip(), lineno)
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "for")
        return ("foreach", lineno, name.strip(),
                parse_expr_text(iter_text, lineno), body), pos

    if head == "to":
        name, params = parse_signature(rest, lineno)
        body, pos = parse_block(lines, pos + 1)
        pos = expect_end(lines, pos, "to")
        return ("func", lineno, name, params, body), pos

    if head == "give":
        if not rest.startswith("back"):
            raise VantaError(f"line {lineno}: did you mean 'give back ...'?")
        value_text = rest[len("back"):].strip()
        node = parse_expr_text(value_text, lineno) if value_text else ("lit", None)
        return ("return", lineno, node), pos + 1

    if head == "let":
        name, sep, expr_text = rest.partition(" be ")
        if not sep:
            raise VantaError(f"line {lineno}: use: let NAME be VALUE")
        check_name(name.strip(), lineno)
        return ("let", lineno, name.strip(), parse_expr_text(expr_text, lineno)), pos + 1

    if head == "change":
        if " to " not in rest:
            raise VantaError(f"line {lineno}: use: change NAME to VALUE")
        target, _, value_text = rest.partition(" to ")
        value = parse_expr_text(value_text, lineno)
        if " at " in target:
            name, _, index_text = target.partition(" at ")
            return ("setindex", lineno, name.strip(),
                    parse_expr_text(index_text, lineno), value), pos + 1
        return ("change", lineno, target.strip(), value), pos + 1

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
        return ("import", lineno, parse_expr_text(rest, lineno)), pos + 1

    if head == "say":
        node = parse_expr_text(rest, lineno) if rest else None
        return ("say", lineno, node), pos + 1

    if head == "stop":
        return ("stop", lineno), pos + 1

    if head == "skip":
        return ("skip", lineno), pos + 1

    # Anything else is a bare expression (typically a function call).
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


def parse_signature(sig, lineno):
    if "(" in sig and sig.endswith(")"):
        name = sig[:sig.index("(")].strip()
        inside = sig[sig.index("(") + 1:-1].strip()
        params = [p.strip() for p in inside.split(",") if p.strip()]
    elif " with " in sig:
        name, _, rest = sig.partition(" with ")
        params = [p.strip() for p in rest.split(",") if p.strip()]
    else:
        name, params = sig.strip(), []
    check_name(name, lineno)
    for p in params:
        check_name(p, lineno)
    return name, params


def expect_end(lines, pos, what):
    if pos >= len(lines) or first_word(lines[pos][1]) != "end":
        raise VantaError(f"your '{what}' is missing its 'end'")
    return pos + 1


# ===========================================================================
# STAGE 3 - RUNTIME
# ===========================================================================

class Function:
    def __init__(self, name, params, body):
        self.name = name
        self.params = params
        self.body = body


_MISSING = object()


class Environment:
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

    def assign(self, name, value):
        env = self
        while env is not None:
            if name in env.vars:
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


def run_block(stmts, env):
    for stmt in stmts:
        run_stmt(stmt, env)


def run_stmt(stmt, env):
    lineno = stmt[1]
    try:
        _run_stmt(stmt, env)
    except VantaError as e:
        if str(e).startswith("line "):
            raise
        raise VantaError(f"line {lineno}: {e}")


def _run_stmt(stmt, env):
    tag = stmt[0]

    if tag == "say":
        node = stmt[2]
        print("" if node is None else display(eval_expr(node, env)))

    elif tag == "let":
        env.define(stmt[2], eval_expr(stmt[3], env))

    elif tag == "change":
        name, value = stmt[2], eval_expr(stmt[3], env)
        if not env.assign(name, value):
            raise VantaError(f"'{name}' doesn't exist yet (use: let {name} be ...)")

    elif tag == "setindex":
        _, _, name, index_node, value_node = stmt
        collection = lookup(env, name)
        index = eval_expr(index_node, env)
        value = eval_expr(value_node, env)
        set_index(collection, index, value)

    elif tag == "append":
        value = eval_expr(stmt[2], env)
        target = eval_expr(stmt[3], env)
        if not isinstance(target, list):
            raise VantaError("you can only 'add ... to' a list")
        target.append(value)

    elif tag == "ask":
        prompt = "" if stmt[2] is None else display(eval_expr(stmt[2], env))
        answer = input(prompt + " " if prompt else "")
        env.define(stmt[3], smart_value(answer))

    elif tag == "if":
        _, _, branches, else_body = stmt
        for cond, body in branches:
            if truthy(eval_expr(cond, env)):
                run_block(body, env)
                return
        run_block(else_body, env)

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

    elif tag == "func":
        _, _, name, params, body = stmt
        env.define(name, Function(name, params, body))

    elif tag == "return":
        raise ReturnSignal(eval_expr(stmt[2], env))

    elif tag == "stop":
        raise BreakLoop()

    elif tag == "skip":
        raise ContinueLoop()

    elif tag == "expr":
        eval_expr(stmt[2], env)

    elif tag == "import":
        import_file(display(eval_expr(stmt[2], env)))

    else:
        raise VantaError(f"internal error: unknown statement {tag}")


# --------------------------------------------------------------------------
# Expression evaluation
# --------------------------------------------------------------------------

def eval_expr(node, env):
    tag = node[0]

    if tag == "lit":
        return node[1]

    if tag == "name":
        value = env.get(node[1])
        if value is _MISSING:
            raise VantaError(f"I don't know what '{node[1]}' is yet")
        return value

    if tag == "list":
        return [eval_expr(item, env) for item in node[1]]

    if tag == "map":
        result = {}
        for key_node, val_node in node[1]:
            result[eval_expr(key_node, env)] = eval_expr(val_node, env)
        return result

    if tag == "neg":
        value = eval_expr(node[1], env)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise VantaError("only numbers can be negative")
        return -value

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

    if tag == "cmp":
        return compare(node[1], eval_expr(node[2], env), eval_expr(node[3], env))

    if tag == "arith":
        return arithmetic(node[1], eval_expr(node[2], env), eval_expr(node[3], env))

    if tag == "index":
        return get_index(eval_expr(node[1], env), eval_expr(node[2], env))

    if tag == "call":
        return eval_call(node, env)

    raise VantaError(f"internal error: unknown expression {tag}")


def eval_call(node, env):
    target, arg_nodes = node[1], node[2]
    args = [eval_expr(a, env) for a in arg_nodes]

    if target[0] == "name":
        name = target[1]
        value = env.get(name)
        if isinstance(value, Function):
            return call_function(value, args)
        if name in BUILTINS:
            return BUILTINS[name](args)
        if value is not _MISSING:
            raise VantaError(f"'{name}' is not something you can call")
        raise VantaError(f"I don't know a function called '{name}'")

    value = eval_expr(target, env)
    if isinstance(value, Function):
        return call_function(value, args)
    raise VantaError("that value is not a function you can call")


def call_function(fn, args):
    if len(args) != len(fn.params):
        raise VantaError(f"'{fn.name}' expects {len(fn.params)} value(s), "
                         f"but got {len(args)}")
    local = Environment(GLOBAL_ENV)
    for param, value in zip(fn.params, args):
        local.define(param, value)
    try:
        run_block(fn.body, local)
    except ReturnSignal as r:
        return r.value
    return None


def lookup(env, name):
    value = env.get(name)
    if value is _MISSING:
        raise VantaError(f"I don't know what '{name}' is yet")
    return value


# --------------------------------------------------------------------------
# Operators and indexing
# --------------------------------------------------------------------------

def arithmetic(op, a, b):
    if op == "+":
        if isinstance(a, list) and isinstance(b, list):
            return a + b
        if isinstance(a, str) or isinstance(b, str):
            return display(a) + display(b)
        check_numbers(a, b, "+")
        return a + b
    check_numbers(a, b, op)
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "%":
        if b == 0:
            raise VantaError("you can't take the remainder with zero")
        return a % b
    if op == "/":
        if b == 0:
            raise VantaError("you can't divide by zero")
        result = a / b
        return int(result) if result == int(result) else result


def check_numbers(a, b, op):
    for value in (a, b):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise VantaError(f"I can only do math ({op}) with numbers")


def compare(op, a, b):
    if op == "==":
        return a == b
    if op == "!=":
        return a != b
    both_numbers = (isinstance(a, (int, float)) and isinstance(b, (int, float))
                    and not isinstance(a, bool) and not isinstance(b, bool))
    both_text = isinstance(a, str) and isinstance(b, str)
    if not (both_numbers or both_text):
        raise VantaError("I can only compare numbers with numbers, or text with text")
    if op == ">":
        return a > b
    if op == "<":
        return a < b
    if op == ">=":
        return a >= b
    if op == "<=":
        return a <= b


def get_index(collection, index):
    if isinstance(collection, (list, str)):
        return collection[whole_index(index, len(collection))]
    if isinstance(collection, dict):
        if index not in collection:
            raise VantaError(f"this map has no key {display_item(index)}")
        return collection[index]
    raise VantaError("you can only look inside a list, text, or map")


def set_index(collection, index, value):
    if isinstance(collection, list):
        collection[whole_index(index, len(collection))] = value
    elif isinstance(collection, dict):
        collection[index] = value
    else:
        raise VantaError("you can only change a position inside a list or map")


def whole_index(index, length):
    if isinstance(index, bool) or not isinstance(index, int):
        raise VantaError("a position must be a whole number")
    if index < 0 or index >= length:
        raise VantaError(f"position {index} is outside the range 0..{length - 1}")
    return index


def iterate(value):
    if isinstance(value, list):
        return list(value)
    if isinstance(value, str):
        return list(value)
    if isinstance(value, dict):
        return list(value.keys())
    raise VantaError("you can only loop over a list, text, or map")


# ===========================================================================
# STANDARD LIBRARY  (built-in functions)
# ===========================================================================

def _need(args, count, name):
    if len(args) != count:
        raise VantaError(f"{name} expects {count} value(s), got {len(args)}")


def b_length(args):
    _need(args, 1, "length")
    if isinstance(args[0], (str, list, dict)):
        return len(args[0])
    raise VantaError("length works on text, lists, or maps")


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


def b_upper(args):
    _need(args, 1, "uppercase")
    return display(args[0]).upper()


def b_lower(args):
    _need(args, 1, "lowercase")
    return display(args[0]).lower()


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
    raise VantaError("range expects 1 or 2 numbers")


def b_random(args):
    _need(args, 2, "random")
    low, high = int_arg(args[0], "random"), int_arg(args[1], "random")
    if low > high:
        raise VantaError("random needs the low number first")
    return random.randint(low, high)


def b_contains(args):
    _need(args, 2, "contains")
    coll, item = args
    if isinstance(coll, (list, str, dict)):
        return item in coll
    raise VantaError("contains works on lists, text, or maps")


def b_join(args):
    _need(args, 2, "join")
    seq, sep = args
    if not isinstance(seq, list):
        raise VantaError("join needs a list as its first value")
    return display(sep).join(display(x) for x in seq)


def b_split(args):
    _need(args, 2, "split")
    return display(args[0]).split(display(args[1]))


def b_keys(args):
    _need(args, 1, "keys")
    if not isinstance(args[0], dict):
        raise VantaError("keys needs a map")
    return list(args[0].keys())


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
    """Like run, but returns a map with output AND exit code.
    Optional 2nd arg is a working directory; optional 3rd is a map of
    environment variables to set for the command."""
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


def b_interpreter(args):
    _need(args, 0, "interpreter")
    return os.path.abspath(sys.argv[0])


def int_arg(value, name):
    if isinstance(value, bool) or not isinstance(value, int):
        raise VantaError(f"{name} needs whole numbers")
    return value


def num_arg(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise VantaError(f"{name} needs a number")
    return value


# ---- text helpers --------------------------------------------------------

def b_replace(args):
    _need(args, 3, "replace")
    return display(args[0]).replace(display(args[1]), display(args[2]))


def b_trim(args):
    _need(args, 1, "trim")
    return display(args[0]).strip()


def b_starts_with(args):
    _need(args, 2, "starts_with")
    return display(args[0]).startswith(display(args[1]))


def b_ends_with(args):
    _need(args, 2, "ends_with")
    return display(args[0]).endswith(display(args[1]))


def b_find(args):
    _need(args, 2, "find")
    return display(args[0]).find(display(args[1]))


def b_lines(args):
    _need(args, 1, "lines")
    return display(args[0]).split("\n")


# ---- number helpers ------------------------------------------------------

def b_abs(args):
    _need(args, 1, "abs")
    return abs(num_arg(args[0], "abs"))


def b_round(args):
    _need(args, 1, "round")
    return round(num_arg(args[0], "round"))


def b_floor(args):
    _need(args, 1, "floor")
    return math.floor(num_arg(args[0], "floor"))


def b_ceil(args):
    _need(args, 1, "ceil")
    return math.ceil(num_arg(args[0], "ceil"))


def _less(a, b):
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


# ---- list helpers --------------------------------------------------------

def b_sort(args):
    _need(args, 1, "sort")
    if not isinstance(args[0], list):
        raise VantaError("sort needs a list")
    try:
        return sorted(args[0])
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


def b_remove_at(args):
    _need(args, 2, "remove_at")
    if not isinstance(args[0], list):
        raise VantaError("remove_at needs a list")
    idx = whole_index(args[1], len(args[0]))
    return args[0].pop(idx)


def b_now(args):
    _need(args, 0, "now")
    return int(time.time())


BUILTINS = {
    "length": b_length,
    "text": b_text,
    "number": b_number,
    "uppercase": b_upper,
    "lowercase": b_lower,
    "first": b_first,
    "last": b_last,
    "range": b_range,
    "random": b_random,
    "contains": b_contains,
    "join": b_join,
    "split": b_split,
    "keys": b_keys,
    "read_file": b_read_file,
    "write_file": b_write_file,
    "run": b_run,
    "shell": b_shell,
    "arguments": b_arguments,
    "env": b_env,
    "make_dir": b_make_dir,
    "remove_path": b_remove_path,
    "list_dir": b_list_dir,
    "path_exists": b_path_exists,
    "copy_path": b_copy_path,
    "to_json": b_to_json,
    "from_json": b_from_json,
    "interpreter": b_interpreter,
    "replace": b_replace,
    "trim": b_trim,
    "starts_with": b_starts_with,
    "ends_with": b_ends_with,
    "find": b_find,
    "lines": b_lines,
    "abs": b_abs,
    "round": b_round,
    "floor": b_floor,
    "ceil": b_ceil,
    "min": b_min,
    "max": b_max,
    "sort": b_sort,
    "reverse": b_reverse,
    "slice": b_slice,
    "remove_at": b_remove_at,
    "now": b_now,
}


# ===========================================================================
# SHARED HELPERS
# ===========================================================================

def truthy(value):
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, (str, list, dict)):
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
        return "{" + ", ".join(display_item(k) + ": " + display_item(v)
                               for k, v in value.items()) + "}"
    if isinstance(value, Function):
        return f"<function {value.name}>"
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
            "nothing", "times", "at"}


def check_name(name, lineno):
    if not name or not (name[0].isalpha() or name[0] == "_"):
        raise VantaError(f"line {lineno}: '{name}' is not a valid name")
    if not all(c.isalnum() or c == "_" for c in name):
        raise VantaError(f"line {lineno}: '{name}' is not a valid name")
    if name in RESERVED:
        raise VantaError(f"line {lineno}: '{name}' is a reserved word, "
                         f"pick another name")


def load_lines(source):
    """Keep real line numbers; drop blank lines and # / note comments."""
    lines = []
    for i, raw in enumerate(source.splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#") or first_word(text) == "note":
            continue
        lines.append((i, text))
    return lines


def import_file(path):
    try:
        with open(path, "r") as f:
            source = f.read()
    except OSError as e:
        raise VantaError(f"could not import {path}: {e}")
    run_block(parse_program(load_lines(source)), GLOBAL_ENV)


# ===========================================================================
# ENTRY POINT
# ===========================================================================

GLOBAL_ENV = Environment()


def run_source(source):
    run_block(parse_program(load_lines(source)), GLOBAL_ENV)


def repl():
    print("Vanta 2.0 - type Vanta code, or 'bye' to quit.")
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


def main():
    global PROGRAM_ARGS
    if len(sys.argv) == 1:
        repl()
        return
    PROGRAM_ARGS = sys.argv[2:]
    with open(sys.argv[1], "r") as f:
        source = f.read()
    try:
        run_source(source)
    except VantaError as e:
        print(f"Oops! {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
