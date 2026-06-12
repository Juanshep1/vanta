#!/usr/bin/env python3
"""Headless test for the Vanta Studio IDE templates.

The IDE injects canvas/game builtins (rect, circle, key_down, ...) before
running a project — exactly like this harness does. Each template in
ide/templates/ is run with recording stubs; templates that define on_frame()
get ticked 15 frames. Any Vanta error fails the test.
"""

import builtins
import glob
import io
import os
import sys
import contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
VANTA_DIR = os.path.dirname(HERE)
sys.path.insert(0, VANTA_DIR)

import vanta  # noqa: E402

DRAWS = []


def stub(name, result=None, record=True):
    def fn(args):
        if record:
            DRAWS.append((name, list(args)))
        return result
    return fn


# The same builtin names the IDE provides (here as no-op recorders).
CANVAS_BUILTINS = {
    "canvas": stub("canvas"),
    "clear": stub("clear"),
    "color": stub("color"),
    "rect": stub("rect"),
    "circle": stub("circle"),
    "line": stub("line"),
    "text_at": stub("text_at"),
    "key_down": stub("key_down", result=False, record=False),
    "mouse_x": stub("mouse_x", result=100, record=False),
    "mouse_y": stub("mouse_y", result=100, record=False),
    "mouse_down": stub("mouse_down", result=False, record=False),
    "stop_game": stub("stop_game", record=False),
}

# Templates that draw at least once even with no input.
MUST_DRAW = {"snake.va", "balls.va", "art.va", "paint.va"}


def main():
    for name, fn in CANVAS_BUILTINS.items():
        vanta.BUILTINS[name] = fn
    vanta.BUILTIN_VALUES.update(
        {n: vanta.Builtin(n, f) for n, f in CANVAS_BUILTINS.items()})

    builtins.input = lambda prompt="": "2"   # quiz answers itself

    failed = 0
    for path in sorted(glob.glob(os.path.join(VANTA_DIR, "ide", "templates", "*.va"))):
        name = os.path.basename(path)
        DRAWS.clear()
        vanta.reset_runtime()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                with open(path) as f:
                    vanta.run_source(f.read())
                if vanta.GLOBAL_ENV.get("on_frame") is not vanta._MISSING:
                    for _ in range(15):
                        vanta.call_vanta("on_frame", [])
            if name in MUST_DRAW and not DRAWS:
                raise vanta.VantaError("template drew nothing")
            print(f"  ok    {name} ({len(DRAWS)} draw calls)")
        except vanta.VantaError as e:
            print(f"  FAIL  {name}: {e}")
            failed += 1

    if failed:
        print(f"{failed} template(s) failed")
        sys.exit(1)
    print("IDE template tests passed")


if __name__ == "__main__":
    main()
