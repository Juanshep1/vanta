#!/usr/bin/env python3
"""Headless checks for the canvas runtime (native/runtime/vcanvas.c) and the GBA video chip (vgame.c).

Builds tests/canvas/api_check.va and every examples/games program natively with VANTA_HEADLESS=1 (so no window ever
opens), drives the games with scripted input (VANTA_INPUT), and checks that each exits cleanly and leaves a screenshot
that isn't blank. Also checks that `vanta.py` hands canvas programs to the native compiler, and that the GBA-style
example (native/examples/ppu_test.va) still draws. Skips (passing) when SDL2 or a C compiler isn't installed.

    python3 tools/canvas_headless.py [--keep DIR]     # --keep saves the screenshots in DIR
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VANTAC = os.path.join(HERE, "native", "vantac.py")

# program -> (frames, scripted input)
GAMES = {
    "pong.va": (120, "10 press space; 20 down w; 60 up w"),
    "snake.va": (200, "30 press down; 70 press right"),
    "platformer.va": (220, "5 down right; 120 down space; 140 up space"),
    "breakout.va": (150, "5 move 240 500; 20 click 240 500"),
    "paint.va": (60, "5 mousedown 200 200; 10 move 260 240; 20 move 330 200; 30 mouseup"),
    "calculator.va": (40, "5 click 49 234; 10 click 271 234; 15 click 197 298; 20 click 271 426"),
    "todo.va": (40, "5 click 100 80; 8 type Buy milk; 12 press enter"),
    "showcase.va": (90, ""),
}


def bmp_colours(path):
    """How many distinct colours a 24/32-bit BMP has."""
    data = open(path, "rb").read()
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (w * bpp + 3) & ~3
    seen = set()
    for y in range(0, abs(h), 4):
        base = off + y * row
        for x in range(0, w, 4):
            seen.add(data[base + x * bpp: base + x * bpp + 3])
    return len(seen)


def main():
    keep = None
    if "--keep" in sys.argv:
        keep = sys.argv[sys.argv.index("--keep") + 1]
        os.makedirs(keep, exist_ok=True)
    if shutil.which("sdl2-config") is None or shutil.which(os.environ.get("CC", "cc")) is None:
        print("canvas: skipped (needs SDL2 and a C compiler)")
        return 0
    env = dict(os.environ, VANTA_HEADLESS="1")
    work = tempfile.mkdtemp(prefix="vanta-canvas-")
    failures = []

    def build(src, exe):
        r = subprocess.run([sys.executable, VANTAC, src, "-o", exe], capture_output=True, text=True, env=env)
        if r.returncode != 0:
            failures.append(f"{os.path.basename(src)}: build failed: {(r.stdout + r.stderr)[-800:]}")
            return False
        return True

    # 1. the API, checked pixel by pixel
    exe = os.path.join(work, "api_check")
    if build(os.path.join(HERE, "tests", "canvas", "api_check.va"), exe):
        r = subprocess.run([exe], capture_output=True, text=True, env=env, timeout=60)
        if r.returncode != 0 or "canvas api ok" not in r.stdout:
            failures.append("api_check: " + (r.stdout + r.stderr)[-800:])

    # 2. vanta.py runs canvas programs through the native compiler
    r = subprocess.run([sys.executable, os.path.join(HERE, "vanta.py"), os.path.join(HERE, "tests", "canvas", "api_check.va")],
                       capture_output=True, text=True, env=dict(env, VANTA_CACHE=os.path.join(work, "cache")), timeout=300)
    if r.returncode != 0 or "canvas api ok" not in r.stdout:
        failures.append("vanta.py -> native: " + (r.stdout + r.stderr)[-800:])

    # 3. every example game/app, with scripted input and a screenshot at the end
    for name, (frames, script) in GAMES.items():
        src = os.path.join(HERE, "examples", "games", name)
        if not os.path.exists(src):
            failures.append(f"{name}: missing")
            continue
        exe = os.path.join(work, name[:-3])
        if not build(src, exe):
            continue
        shot = os.path.join(work, name[:-3] + ".bmp")
        r = subprocess.run([exe], capture_output=True, text=True, cwd=work, timeout=120,
                           env=dict(env, VANTA_FRAMES=str(frames), VANTA_SHOT=shot, VANTA_INPUT=script))
        if r.returncode != 0:
            failures.append(f"{name}: exit {r.returncode}: {(r.stdout + r.stderr)[-800:]}")
        elif not os.path.exists(shot):
            failures.append(f"{name}: no screenshot")
        elif bmp_colours(shot) < 4:
            failures.append(f"{name}: the screenshot is blank")
        if keep and os.path.exists(shot):
            shutil.copy(shot, keep)

    # 4. the GBA video chip still draws
    exe = os.path.join(work, "ppu_test")
    if build(os.path.join(HERE, "native", "examples", "ppu_test.va"), exe):
        r = subprocess.run([exe], capture_output=True, text=True, cwd=work, env=env, timeout=60)
        shot = os.path.join(work, "ppu_test.bmp")
        if r.returncode != 0 or not os.path.exists(shot) or bmp_colours(shot) < 3:
            failures.append("ppu_test (GBA mode): " + (r.stdout + r.stderr)[-400:])

    shutil.rmtree(work, ignore_errors=True)
    if failures:
        print("canvas: FAILED\n  " + "\n  ".join(failures))
        return 1
    print(f"canvas: api, vanta.py hand-off, {len(GAMES)} examples and GBA mode ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
