#!/usr/bin/env python3
"""Headless test for the CHIP-8 emulator (emulator/chip8.va).

No browser needed: we load the Vanta emulator, run a tiny hand-assembled
program through it, and check the framebuffer pixel-for-pixel.

The program draws the built-in "0" glyph at (0, 0):

    6200   V2 = 0          (which font character to draw)
    F229   I  = addr of font glyph V2   (the "0" glyph, 5 bytes)
    6000   V0 = 0          (x)
    6100   V1 = 0          (y)
    D015   draw 5-row sprite at (V0, V1)
    120A   jump to self    (halt)

The "0" glyph bytes are F0 90 90 90 F0, so the lit pixels are exactly:
    row 0: x 0..3      row 1: x 0,3      row 2: x 0,3
    row 3: x 0,3       row 4: x 0..3                 = 14 pixels total.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VANTA_DIR = os.path.dirname(HERE)
sys.path.insert(0, VANTA_DIR)

import vanta  # noqa: E402

WIDTH = 64


def lit_pixels(framebuffer):
    return {i for i, p in enumerate(framebuffer) if p}


def main():
    with open(os.path.join(VANTA_DIR, "emulator", "chip8.va")) as f:
        vanta.run_source(f.read())

    program = [0x62, 0x00, 0xF2, 0x29, 0x60, 0x00,
               0x61, 0x00, 0xD0, 0x15, 0x12, 0x0A]

    vanta.call_vanta("chip8_init", [])
    vanta.call_vanta("chip8_load", [program])
    vanta.call_vanta("chip8_step", [20])
    framebuffer = list(vanta.call_vanta("chip8_display", []))

    expected = set()
    glyph = [0xF0, 0x90, 0x90, 0x90, 0xF0]
    for row, byte in enumerate(glyph):
        for col in range(8):
            if byte & (0x80 >> col):
                expected.add(row * WIDTH + col)

    got = lit_pixels(framebuffer)

    # Render for eyeballing on failure.
    def render():
        lines = []
        for y in range(6):
            lines.append("".join("#" if (y * WIDTH + x) in got else "."
                                 for x in range(8)))
        return "\n".join(lines)

    if got != expected:
        print("CHIP-8 headless test FAILED")
        print(f"expected {len(expected)} lit pixels, got {len(got)}")
        print(render())
        sys.exit(1)

    print(f"glyph test passed ({len(got)} pixels lit, the '0' glyph)")
    print(render())

    # Second check: run the real IBM-logo ROM and confirm its known output.
    ibm = os.path.join(VANTA_DIR, "roms", "ibm-logo.ch8")
    if os.path.exists(ibm):
        rom = list(open(ibm, "rb").read())
        vanta.call_vanta("chip8_init", [])
        vanta.call_vanta("chip8_load", [rom])
        vanta.call_vanta("chip8_step", [25])
        fb = list(vanta.call_vanta("chip8_display", []))
        lit = sum(1 for p in fb if p)
        if lit != 230:
            print(f"IBM-logo ROM test FAILED: expected 230 lit pixels, got {lit}")
            sys.exit(1)
        print(f"IBM-logo ROM test passed ({lit} pixels lit)")

    print("CHIP-8 headless tests passed")
    sys.exit(0)


if __name__ == "__main__":
    main()
