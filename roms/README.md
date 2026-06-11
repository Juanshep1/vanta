# ROMs

CHIP-8 ROMs bundled for testing and the playground demo. Each is included with
its license noted below; none are of unknown provenance.

## Test ROMs — from the CHIP-8 test suite by Timendus (MIT License)
Source: https://github.com/Timendus/chip8-test-suite

- `chip8-logo.ch8` — draws the CHIP-8 logo
- `ibm-logo.ch8` — draws the IBM logo (the classic "does it work at all" ROM;
  used by the headless golden test in `tools/chip8_headless.py`)
- `corax-opcode-test.ch8` — a thorough opcode test that draws a pass/fail grid

## Games — from the chip8Archive (public domain / CC0)
Source: https://github.com/JohnEarnest/chip8Archive — submissions are released
into the public domain.

- `breakout.ch8` — "br8kout", a Breakout clone
- `glitchghost.ch8` — "Glitch Ghost", a small platformer

## Using your own ROMs
The playground also has a file picker, so you can drop in any `.ch8` ROM you own.
Keypad mapping (the original CHIP-8 hex pad → your keyboard):

```
CHIP-8        Keyboard
1 2 3 C       1 2 3 4
4 5 6 D       Q W E R
7 8 9 E       A S D F
A 0 B F       Z X C V
```
