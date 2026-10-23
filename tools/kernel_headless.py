#!/usr/bin/env python3
"""Headless test of Vanta's bare-metal target: builds examples/os/hello_kernel.va and examples/os/vantaos.va with
`vantac.py --kernel`, boots each in QEMU with no window (-display none), types into it through the QEMU monitor's
`sendkey` (the real PS/2 keyboard path), and checks what the kernel writes to the serial port.

    python3 tools/kernel_headless.py            run the checks (skips cleanly if qemu / ld.lld / clang are missing)
    python3 tools/kernel_headless.py --shots D  also save screenshots (PNG) of the VGA screen into folder D

Also usable as a library: boot(), type_text(), screenshot().
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "native"))

KEYNAMES = {" ": "spc", "\n": "ret", "-": "minus", "=": "equal", ".": "dot", ",": "comma", "/": "slash",
            ";": "semicolon", "'": "apostrophe", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
            "`": "grave_accent", "*": "shift-8", "+": "shift-equal", "(": "shift-9", ")": "shift-0",
            "\"": "shift-apostrophe", ":": "shift-semicolon", "!": "shift-1", "?": "shift-slash", "_": "shift-minus",
            "<": "shift-comma", ">": "shift-dot", "%": "shift-5", "^": "shift-6", "&": "shift-7", "#": "shift-3",
            "@": "shift-2", "$": "shift-4", "{": "shift-bracket_left", "}": "shift-bracket_right", "|": "shift-backslash"}


def missing_tools():
    import kernel_build
    need = {"qemu-system-x86_64": shutil.which("qemu-system-x86_64"),
            "ld.lld": kernel_build.find_tool(["ld.lld"], kernel_build.LLVM_DIRS),
            "clang": kernel_build.find_tool(["clang"], kernel_build.LLVM_DIRS),
            "llvm-objcopy": kernel_build.find_tool(["llvm-objcopy"], kernel_build.LLVM_DIRS)}
    return [n for n, p in need.items() if not p]


def build(src, out, arch="x86"):
    r = subprocess.run([sys.executable, os.path.join(ROOT, "native", "vantac.py"), src, "--kernel", "-o", out,
                        "--arch", arch], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"building {src} failed:\n{r.stdout}{r.stderr}")
    return out


class Machine:
    """One QEMU running a kernel: serial output goes to a file, the monitor listens on a unix socket."""
    def __init__(self, elf, workdir, extra=()):
        self.serial = os.path.join(workdir, "serial.txt")
        self.sock_dir = tempfile.mkdtemp(prefix="vk")    # unix socket paths must be short
        self.sock_path = os.path.join(self.sock_dir, "monitor.sock")
        for p in (self.serial, self.sock_path):
            if os.path.exists(p):
                os.remove(p)
        self.proc = subprocess.Popen(
            ["qemu-system-x86_64", "-kernel", elf, "-display", "none", "-serial", f"file:{self.serial}",
             "-monitor", f"unix:{self.sock_path},server,nowait", "-no-reboot", "-m", "128M", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.mon = None
        for _ in range(100):
            if os.path.exists(self.sock_path):
                try:
                    self.mon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self.mon.connect(self.sock_path)
                    break
                except OSError:
                    self.mon = None
            time.sleep(0.05)
        if not self.mon:
            self.stop()
            raise RuntimeError("QEMU's monitor didn't start")
        self.mon.settimeout(0.2)
        self._drain()

    def _drain(self):
        try:
            while self.mon.recv(65536):
                pass
        except (socket.timeout, BlockingIOError, OSError):
            pass

    def command(self, cmd):
        self.mon.sendall((cmd + "\n").encode())
        time.sleep(0.03)
        self._drain()

    def output(self):
        try:
            with open(self.serial, "rb") as f:
                return f.read().decode("utf-8", "replace").replace("\r\n", "\n")
        except FileNotFoundError:
            return ""

    def wait_for(self, text, timeout=15, start=0):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.output()[start:]:
                return True
            if self.proc.poll() is not None:
                break
            time.sleep(0.05)
        return text in self.output()[start:]

    def type_text(self, text, delay=0.02):
        for ch in text:
            if ch in KEYNAMES:
                key = KEYNAMES[ch]
            elif ch.isupper():
                key = "shift-" + ch.lower()
            else:
                key = ch
            self.command(f"sendkey {key}")
            time.sleep(delay)

    def key(self, name):
        self.command(f"sendkey {name}")

    def screenshot(self, png_path):
        ppm = png_path[:-4] + ".ppm"
        self.command(f"screendump {ppm}")
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
                break
            time.sleep(0.05)
        time.sleep(0.2)
        ppm_to_png(ppm, png_path)
        os.remove(ppm)
        return png_path

    def stop(self):
        try:
            if self.mon:
                self.mon.sendall(b"quit\n")
        except OSError:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        shutil.rmtree(self.sock_dir, ignore_errors=True)


def ppm_to_png(ppm, png):
    """Convert QEMU's screendump (binary PPM) to PNG without extra dependencies."""
    import struct, zlib
    data = open(ppm, "rb").read()
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        parts.append(data[start:pos])
    pos += 1
    w, h = int(parts[1]), int(parts[2])
    pix = data[pos:pos + w * h * 3]
    raw = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(png, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def main():
    shots = None
    if "--shots" in sys.argv:
        shots = os.path.abspath(sys.argv[sys.argv.index("--shots") + 1])
        os.makedirs(shots, exist_ok=True)
    miss = missing_tools()
    if miss:
        print("SKIP kernel_headless: missing " + ", ".join(miss))
        return 0
    failures = []
    def check(cond, what):
        print(("  ok    " if cond else "  FAIL  ") + what)
        if not cond:
            failures.append(what)

    with tempfile.TemporaryDirectory(prefix="vanta-kernel-") as tmp:
        hello = build(os.path.join(ROOT, "examples", "os", "hello_kernel.va"), os.path.join(tmp, "hello.elf"))
        m = Machine(hello, tmp)
        try:
            check(m.wait_for("Hello from Vanta!", 15), "hello_kernel prints 'Hello from Vanta!' on the serial port")
            check(m.wait_for("System halted.", 5), "hello_kernel halts")
            if shots:
                m.screenshot(os.path.join(shots, "hello_kernel.png"))
        finally:
            m.stop()

        os_elf = build(os.path.join(ROOT, "examples", "os", "vantaos.va"), os.path.join(tmp, "vantaos.elf"))
        m = Machine(os_elf, tmp)
        try:
            check(m.wait_for("vanta> ", 20), "vantaos boots to its shell prompt")
            if shots:
                m.screenshot(os.path.join(shots, "vantaos_boot.png"))
            n = len(m.output())
            m.type_text("help\n")
            check(m.wait_for("echo", 10, n) and m.wait_for("vanta> ", 10, n), "typing 'help' lists the commands")
            n = len(m.output())
            m.type_text("echo hi\n")
            check(m.wait_for("\nhi\n", 10, n), "typing 'echo hi' prints hi")
            n = len(m.output())
            m.type_text("write notes.txt Vanta rocks\n")
            m.wait_for("vanta> ", 10, n)
            n = len(m.output())
            m.type_text("cat notes.txt\n")
            check(m.wait_for("Vanta rocks", 10, n), "ram file system: write then cat")
            n = len(m.output())
            m.type_text("calc (2 + 3) * 7\n")
            check(m.wait_for("35", 10, n), "calc evaluates (2 + 3) * 7 = 35")
            n = len(m.output())
            m.type_text("mem\n")
            check(m.wait_for("free", 10, n), "mem shows memory information")
            if shots:
                m.screenshot(os.path.join(shots, "vantaos_shell.png"))
        finally:
            m.stop()
        if shutil.which("qemu-system-aarch64"):
            arm = build(os.path.join(ROOT, "examples", "os", "hello_kernel.va"), os.path.join(tmp, "hello-arm64.elf"), "arm64")
            serial = os.path.join(tmp, "serial-arm64.txt")
            p = subprocess.Popen(["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72", "-kernel", arm,
                                  "-display", "none", "-serial", f"file:{serial}", "-monitor", "none"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            text = ""
            for _ in range(200):
                time.sleep(0.05)
                text = open(serial, errors="replace").read() if os.path.exists(serial) else ""
                if "System halted." in text:
                    break
            p.kill(); p.wait()
            check("Hello from Vanta!" in text and "System halted." in text, "hello_kernel boots on arm64 (QEMU virt)")
    print("kernel_headless: " + ("all good" if not failures else f"{len(failures)} failed"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
