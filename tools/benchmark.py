#!/usr/bin/env python3
"""A small, reproducible speed benchmark for the Vanta interpreter.

Runs a recursion-heavy and a loop-heavy program and reports the best wall-clock
time over a few runs. Useful for checking that interpreter changes don't slow
things down (and that optimizations actually help).

Usage:  python3 tools/benchmark.py
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VANTA = os.path.join(HERE, "vanta.py")

PROGRAM = """
to fib(n)
    if n is under 2
        give back n
    end
    give back fib(n - 1) + fib(n - 2)
end
say fib(27)

let total be 0
let i be 0
while i is under 300000
    change total to total + i
    change i to i + 1
end
say total
"""


def main():
    path = os.path.join(HERE, "_bench.va")
    with open(path, "w") as f:
        f.write(PROGRAM)
    try:
        times = []
        for _ in range(3):
            start = time.time()
            result = subprocess.run([sys.executable, VANTA, path],
                                    capture_output=True, text=True)
            times.append(time.time() - start)
        assert result.returncode == 0, result.stderr
        out = result.stdout.split()
        assert out[0] == "196418", f"fib wrong: {out}"
        assert out[1] == "44999850000", f"loop sum wrong: {out}"
        print(f"fib(27) + 300k-loop  —  best {min(times):.2f}s "
              f"(runs: {', '.join('%.2f' % t for t in times)})")
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
