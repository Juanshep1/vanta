#!/usr/bin/env python3
"""Run Vanta's test suite.

Each file in tests/ uses assert(...) to check the language. A failing assert
raises an error, which makes the interpreter exit non-zero, which we report
here. The example programs in examples/ are also run to make sure they don't
crash.

Usage:  python3 run_tests.py
"""

import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VANTA = os.path.join(HERE, "vanta.py")

# Example programs that need typed input, so we feed them something harmless.
INPUTS = {
    "greet.va": "Sam\n30\n",
    "guess.va": "5\n3\n1\n2\n4\n6\n7\n8\n9\n10\n",
}


def run(path, stdin=""):
    return subprocess.run([sys.executable, VANTA, path],
                          input=stdin, capture_output=True, text=True)


def main():
    passed = failed = 0

    print("test suite")
    for path in sorted(glob.glob(os.path.join(HERE, "tests", "*.va"))):
        result = run(path)
        name = os.path.basename(path)
        if result.returncode == 0:
            print(f"  PASS  {name}")
            passed += 1
        else:
            print(f"  FAIL  {name}")
            print("        " + (result.stdout + result.stderr).strip())
            failed += 1

    print("\nexamples (should run without crashing)")
    for path in sorted(glob.glob(os.path.join(HERE, "examples", "*.va"))):
        name = os.path.basename(path)
        result = run(path, INPUTS.get(name, ""))
        if result.returncode == 0:
            print(f"  OK    {name}")
            passed += 1
        else:
            print(f"  CRASH {name}")
            print("        " + (result.stdout + result.stderr).strip())
            failed += 1

    print("\nheadless harnesses")
    for harness in ["tools/chip8_headless.py", "tools/ide_headless.py"]:
        result = subprocess.run([sys.executable, os.path.join(HERE, harness)],
                                capture_output=True, text=True)
        name = os.path.basename(harness)
        if result.returncode == 0:
            print(f"  PASS  {name}")
            passed += 1
        else:
            print(f"  FAIL  {name}")
            print("        " + (result.stdout + result.stderr).strip())
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
