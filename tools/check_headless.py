#!/usr/bin/env python3
"""Checks `vanta check`: tests/check/bad.va must give exactly tests/check/expected.txt (and exit 1),
and tests/check/good.va must have no problems (exit 0)."""
import os, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
V = [sys.executable, "vanta.py", "check"]
bad = subprocess.run(V + ["tests/check/bad.va"], capture_output=True, text=True)
want = open("tests/check/expected.txt").read()
good = subprocess.run(V + ["tests/check/good.va"], capture_output=True, text=True)
ok = bad.stdout == want and bad.returncode == 1 and good.returncode == 0
if not ok:
    print("bad.va gave:\n" + bad.stdout + bad.stderr + "\ngood.va gave:\n" + good.stdout + good.stderr)
sys.exit(0 if ok else 1)
