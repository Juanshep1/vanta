#!/usr/bin/env python3
"""Differential test: every tests/*.va and examples/*.va program must print the same thing (and exit the same way)
compiled natively as it does under the interpreter. Programs that use builtins native builds don't have yet are
listed as skipped."""
import glob, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
files = sorted(glob.glob("tests/*.va")) + sorted(glob.glob("examples/*.va"))
if len(sys.argv) > 1:
    files = [f for f in files if any(a in f for a in sys.argv[1:])]
ok = fail = skip = 0
tmp = tempfile.mkdtemp()
for f in files:
    exe = os.path.join(tmp, os.path.basename(f)[:-3])
    c = subprocess.run([sys.executable, "native/vantac.py", f, "-o", exe], capture_output=True, text=True)
    if c.returncode != 0:
        if "native builds don't have" in c.stdout:
            skip += 1
            print(f"  skip  {f}: {c.stdout.strip().split('these yet: ')[1].split(' (')[0]}")
        else:
            fail += 1
            print(f"  FAIL  {f}: compile\n{c.stdout[-2000:]}{c.stderr[-2000:]}")
        continue
    try:
        want = subprocess.run([sys.executable, "vanta.py", f], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        got = subprocess.run([exe], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        fail += 1
        print(f"  FAIL  {f}: timeout")
        continue
    if want.stdout == got.stdout and want.returncode == got.returncode:
        ok += 1
    else:
        fail += 1
        wl, gl = want.stdout.splitlines(), got.stdout.splitlines()
        first = next((i for i in range(max(len(wl), len(gl))) if (wl[i] if i < len(wl) else None) != (gl[i] if i < len(gl) else None)), 0)
        print(f"  FAIL  {f}: line {first + 1}\n    interpreter: {wl[first] if first < len(wl) else '<end>'!r}\n    native:      {gl[first] if first < len(gl) else '<end>'!r}"
              + (f"\n    exit {want.returncode} vs {got.returncode}" if want.returncode != got.returncode else ""))
print(f"\n{ok} same, {fail} different, {skip} skipped")
sys.exit(1 if fail else 0)
