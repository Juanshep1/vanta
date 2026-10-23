"""Bare-metal builds for vantac: `python3 native/vantac.py kernel.va --kernel -o out/kernel.elf [--arch x86|arm64]
[--iso out/vanta.iso]`.

The program is compiled to C exactly like a normal native build, then linked with the freestanding runtime in
native/runtime/kernel/ instead of the operating system's C library:

    vrt.c + vrt_builtins.c   the normal Vanta runtime (values, GC, text, lists, maps, errors, builtins), compiled
                             -ffreestanding against the kernel's own small libc headers
    kernel/libc.c kmath.c    the C library subset that runtime needs (printf, strtod, math, ...)
    kernel/kmem.c            physical page allocator + malloc/free
    kernel/kernel.c          console, keyboard, timers, interrupts-for-Vanta, ram file system, kernel builtins
    kernel/pc.c              x86 PC hardware (VGA, PIC, PIT, PS/2, COM1, RTC, Bochs graphics) ...
    kernel/boot_x86_64.S     ... Multiboot header, 32-bit entry, switch to 64-bit mode, interrupt stubs, setjmp
    kernel/virt_arm64.c      ... or QEMU's arm64 'virt' board (PL011 UART, generic timer) + boot_arm64.S

x86 output is a Multiboot (v1) ELF that `qemu-system-x86_64 -kernel` boots directly; `--iso` also makes a bootable
CD/USB image with the Limine boot loader. See docs/KERNEL.md.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.join(HERE, "runtime")
KDIR = os.path.join(RUNTIME, "kernel")

# Desktop builtins that need a real operating system underneath. A kernel program that uses one gets a clear
# compile-time error naming it (the ram file system has its own builtins: write_to_file, read_from_file, ...).
OS_ONLY = {
    "read_file": "files", "write_file": "files", "append_file": "files", "path_exists": "files",
    "list_dir": "files", "make_dir": "files", "remove_path": "files", "is_file": "files", "is_dir": "files",
    "file_size": "files", "read_binary": "files", "read_bytes": "files", "write_binary": "files",
    "write_bytes": "files", "arguments": "command-line arguments", "env": "environment variables",
}

ARCHES = {
    "x86": {"target": "x86_64-unknown-none-elf", "boot": "boot_x86_64.S", "plat": "pc.c", "ld": "link_x86_64.ld",
            "cflags": ["-mno-red-zone", "-mno-mmx"]},
    "arm64": {"target": "aarch64-unknown-none-elf", "boot": "boot_arm64.S", "plat": "virt_arm64.c", "ld": "link_arm64.ld",
              "cflags": ["-mstrict-align"]},
}
ARCHES["x86_64"] = ARCHES["x86"]
ARCHES["aarch64"] = ARCHES["arm64"]


def table_names(path, pattern=r"static const Entry \w*table\w*\[\] = \{(.*?)\n\};"):
    src = open(path).read()
    names = set()
    for tab in re.findall(pattern, src, re.S):
        names.update(re.findall(r'\{"(\w+)",', tab))
    return names


def kernel_builtins():
    return table_names(os.path.join(KDIR, "kernel.c"))


SDL_FILES = {"vgame.c", "vcanvas.c", "vstb.c"}     # the desktop game/canvas runtimes (SDL2)


def core_runtime():
    """The runtime files every native program links (vrt.c, vrt_builtins.c, vrt_core.c, ...): every .c file in
    native/runtime except the SDL ones and the optional ones (marked `/* vantac: optional ... */`, e.g. networking,
    threads, databases), which need an operating system."""
    files = []
    for f in sorted(os.listdir(RUNTIME)):
        if not f.endswith(".c") or f in SDL_FILES:
            continue
        head = open(os.path.join(RUNTIME, f)).read(2000)
        if re.search(r"vantac:\s*optional", head):
            continue
        files.append(os.path.join(RUNTIME, f))
    return files


def allowed_builtins():
    """Builtins a kernel program can use: the core runtime's (minus the OS-only ones) plus the kernel's own."""
    base = set()
    for f in core_runtime():
        base |= table_names(f)
    return (base - set(OS_ONLY)) | kernel_builtins()


def find_tool(names, extra_dirs=()):
    for d in list(extra_dirs) + [None]:
        for n in names:
            p = os.path.join(d, n) if d else shutil.which(n)
            if p and os.path.isfile(p) and os.access(p, os.X_OK):
                return p
    return None


LLVM_DIRS = ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin", "/usr/lib/llvm-18/bin", "/usr/lib/llvm-17/bin"]


def tools():
    """clang (any clang can cross-compile; Homebrew's is preferred), ld.lld and llvm-objcopy."""
    cc = os.environ.get("VANTA_KERNEL_CC") or find_tool(["clang"], LLVM_DIRS)
    ld = find_tool(["ld.lld"], LLVM_DIRS)
    objcopy = find_tool(["llvm-objcopy"], LLVM_DIRS)
    missing = [n for n, p in (("clang", cc), ("ld.lld", ld), ("llvm-objcopy", objcopy)) if not p]
    if missing:
        fail("kernel builds need " + ", ".join(missing) + " (macOS: brew install llvm lld; Linux: apt install clang lld llvm)")
    return cc, ld, objcopy


def fail(msg):
    print("Oops! " + msg)
    sys.exit(1)


OPTIONAL_REASON = {"vrt_net.c": "networking", "vrt_http.c": "networking", "vrt_regex.c": "the regex engine", "vrt_thread.c": "threads and processes", "vrt_sys.c": "processes and the system",
                   "vrt_io.c": "files and sockets", "vrt_sqlite.c": "databases", "vrt_zlib.c": "the zlib library",
                   "vrt_data.c": "the desktop runtime", "vgame.c": "SDL2 windows", "vcanvas.c": "SDL2 windows"}


def why_missing(name):
    """Why a builtin isn't in kernel builds: the runtime file that has it tells what it needs."""
    for f in sorted(os.listdir(RUNTIME)):
        if f.endswith(".c") and name in table_names(os.path.join(RUNTIME, f)):
            return "needs " + OPTIONAL_REASON.get(f, "the desktop runtime")
    return "interpreter only"


def compile_program(vc, path, debug=False):
    """Compile the Vanta program to C with the kernel's builtin set. Returns the C source."""
    saved = vc.NATIVE
    vc.NATIVE = allowed_builtins()
    comp = vc.Compiler(path, debug=debug)
    try:
        src = comp.compile_program()
    except vc.CompileError as e:
        if comp.missing:
            src_lines = open(path).read().split("\n")
            for n, ln in list(comp.missing.items()):
                if not ln:   # the compiler didn't know the line: find the first use in the program
                    hit = next((i + 1 for i, l in enumerate(src_lines) if re.search(r"\b" + n + r"\s*\(", l.split("#")[0])), 0)
                    comp.missing[n] = hit or "?"
            os_only = sorted(n for n in comp.missing if n in OS_ONLY)
            other = sorted(n for n in comp.missing if n not in OS_ONLY)
            parts = []
            if os_only:
                parts.append("kernel builds can't use these, because there is no operating system underneath: " +
                             ", ".join(f"{n} ({OS_ONLY[n]}, line {comp.missing[n]})" for n in os_only) +
                             ". For files, use the ram file system: write_to_file, read_from_file, list_files, "
                             "file_exists, delete_file")
            if other:
                parts.append("these aren't available in kernel builds: " +
                             ", ".join(f"{n} ({why_missing(n)}, line {comp.missing[n]})" for n in other))
            fail("; ".join(parts))
        fail(str(e))
    finally:
        vc.NATIVE = saved
    return src


def build_kernel(vc, path, out=None, arch="x86", iso=None, debug=False, keep_c=False):
    if arch not in ARCHES:
        fail(f"unknown --arch '{arch}' (use x86 or arm64)")
    a = ARCHES[arch]
    arch = "arm64" if a is ARCHES["arm64"] else "x86"
    if not os.path.exists(os.path.join(KDIR, a["plat"])):
        fail(f"the {arch} kernel runtime isn't here yet ({a['plat']})")
    src = compile_program(vc, path, debug)
    out = os.path.abspath(out or os.path.splitext(os.path.abspath(path))[0] + ".elf")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cc, ld, objcopy = tools()
    work = os.path.join(os.path.dirname(out), ".vanta-kernel-build", arch)
    os.makedirs(work, exist_ok=True)
    prog_c = os.path.join(work, "program.c")
    with open(prog_c, "w") as f:
        f.write(src)
    if keep_c:
        shutil.copy(prog_c, os.path.splitext(out)[0] + ".c")

    opt = ["-O0", "-g"] if debug else ["-O2"]
    cflags = [f"--target={a['target']}", "-ffreestanding", "-nostdlibinc", "-fno-builtin", "-fno-stack-protector",
              "-fno-pic", "-fno-pie", "-fno-math-errno", "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
              "-fno-exceptions", "-std=c11", "-w", "-DVRT_KERNEL=1", *a["cflags"], *opt,
              "-I", os.path.join(KDIR, "include"), "-I", KDIR, "-I", RUNTIME]
    sources = [(prog_c, [])]
    for f in core_runtime():
        sources.append((f, ["-Dvrt_safepoint=vrt_gc_safepoint"] if os.path.basename(f) == "vrt.c" else []))
    sources += [
        (os.path.join(KDIR, "libc.c"), []),
        (os.path.join(KDIR, "kmath.c"), []),
        (os.path.join(KDIR, "kmem.c"), []),
        (os.path.join(KDIR, "kernel.c"), []),
        (os.path.join(KDIR, a["plat"]), []),
        (os.path.join(KDIR, a["boot"]), []),
    ]
    headers = [os.path.join(RUNTIME, "vrt.h")] + [os.path.join(KDIR, f) for f in os.listdir(KDIR) if f.endswith(".h")]
    headers += [os.path.join(KDIR, "include", f) for f in os.listdir(os.path.join(KDIR, "include")) if f.endswith(".h")]
    newest_header = max(os.path.getmtime(h) for h in headers)
    # The runtime's objects don't depend on the program: they're shared by every kernel build in a cache folder
    # (one per compiler + flags), written atomically so builds running at the same time don't trip over each other.
    import hashlib
    key = hashlib.sha1("|".join([cc, *cflags]).encode()).hexdigest()[:12]
    cache = os.path.join(os.environ.get("VANTA_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "vanta"),
                         f"kernel-{arch}-{key}")
    os.makedirs(cache, exist_ok=True)
    objs, running = [], []
    for s, extra in sources:
        name = os.path.basename(s).replace(".", "_") + ".o"
        obj = os.path.join(work if s == prog_c else cache, name)
        objs.append(obj)
        if (s != prog_c and os.path.exists(obj)
                and os.path.getmtime(obj) >= max(os.path.getmtime(s), newest_header)):
            continue
        tmp = f"{obj}.{os.getpid()}.tmp"
        cmd = [cc, *cflags, *extra, "-c", s, "-o", tmp]
        running.append((s, tmp, obj, subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))
    errors = []
    for s, tmp, obj, p in running:
        _, err = p.communicate()
        if p.returncode != 0:
            errors.append(f"{os.path.basename(s)}:\n{err[-3000:]}")
            if os.path.exists(tmp):
                os.remove(tmp)
        else:
            os.replace(tmp, obj)
    if errors:
        fail("the C compiler failed:\n" + "\n".join(errors))

    elf64 = os.path.join(work, "kernel64.elf")
    r = subprocess.run([ld, "-nostdlib", "-static", "-T", os.path.join(KDIR, a["ld"]), "-z", "max-page-size=0x1000",
                        "--no-dynamic-linker", "-o", elf64, *objs], capture_output=True, text=True)
    if r.returncode != 0:
        fail("linking the kernel failed:\n" + r.stderr[-4000:])
    if arch == "x86":
        # Multiboot loaders (QEMU's -kernel, GRUB) want a 32-bit ELF; the 64-bit code inside is fine.
        r = subprocess.run([objcopy, "-O", "elf32-i386", elf64, out], capture_output=True, text=True)
        if r.returncode != 0:
            fail("llvm-objcopy failed:\n" + r.stderr[-2000:])
    else:
        shutil.copy(elf64, out)
    if iso:
        if arch != "x86":
            fail("--iso makes a PC boot image; it works with --arch x86")
        make_iso(out, os.path.abspath(iso))
    return out


LIMINE_DIRS = ["/opt/homebrew/share/limine", "/usr/local/share/limine", "/usr/share/limine"]


def framebuffer_copy(kernel, out):
    """A copy of the kernel whose Multiboot header asks the boot loader for a 1024x768 graphics mode (flag bit 2).
    UEFI computers have no VGA text mode, so the loader must set up a framebuffer; the kernel then runs its console
    there."""
    import struct
    data = bytearray(open(kernel, "rb").read())
    for off in range(0, min(len(data), 8192) - 48, 4):
        magic, flags, check = struct.unpack_from("<III", data, off)
        if magic == 0x1BADB002 and (magic + flags + check) & 0xFFFFFFFF == 0:
            flags |= 4
            struct.pack_into("<III", data, off, magic, flags, (-(magic + flags)) & 0xFFFFFFFF)
            break
    else:
        fail("couldn't find the Multiboot header in the kernel")
    with open(out, "wb") as f:
        f.write(data)


def make_iso(kernel, iso):
    """A bootable CD/USB image with the Limine boot loader, which loads Multiboot kernels. BIOS computers boot the
    kernel in VGA text mode; UEFI computers boot a copy that asks for a framebuffer (Limine picks with ${FW_TYPE})."""
    limine = find_tool(["limine"])
    xorriso = find_tool(["xorriso"])
    share = next((d for d in LIMINE_DIRS if os.path.exists(os.path.join(d, "limine-bios-cd.bin"))), None)
    if not (limine and xorriso and share):
        fail("--iso needs xorriso and the Limine boot loader (macOS: brew install xorriso limine; "
             "Linux: apt install xorriso and get Limine from github.com/limine-bootloader/limine)")
    root = iso + ".root"
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "boot", "limine"))
    os.makedirs(os.path.join(root, "EFI", "BOOT"))
    shutil.copy(kernel, os.path.join(root, "boot", "kernel-BIOS.elf"))
    framebuffer_copy(kernel, os.path.join(root, "boot", "kernel-UEFI.elf"))
    for f in ("limine-bios.sys", "limine-bios-cd.bin", "limine-uefi-cd.bin"):
        if os.path.exists(os.path.join(share, f)):
            shutil.copy(os.path.join(share, f), os.path.join(root, "boot", "limine", f))
    if os.path.exists(os.path.join(share, "BOOTX64.EFI")):
        shutil.copy(os.path.join(share, "BOOTX64.EFI"), os.path.join(root, "EFI", "BOOT", "BOOTX64.EFI"))
    with open(os.path.join(root, "boot", "limine", "limine.conf"), "w") as f:
        f.write("timeout: 0\n\n/Vanta\n    protocol: multiboot1\n    path: boot():/boot/kernel-${FW_TYPE}.elf\n")
    cmd = [xorriso, "-as", "mkisofs", "-R", "-r", "-J", "-b", "boot/limine/limine-bios-cd.bin", "-no-emul-boot",
           "-boot-load-size", "4", "-boot-info-table"]
    if os.path.exists(os.path.join(root, "boot", "limine", "limine-uefi-cd.bin")):
        cmd += ["--efi-boot", "boot/limine/limine-uefi-cd.bin", "-efi-boot-part", "--efi-boot-image"]
    cmd += ["--protective-msdos-label", root, "-o", iso]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        fail("xorriso failed:\n" + r.stderr[-3000:])
    r = subprocess.run([limine, "bios-install", iso], capture_output=True, text=True)
    if r.returncode != 0:
        fail("limine bios-install failed:\n" + (r.stdout + r.stderr)[-3000:])
    shutil.rmtree(root, ignore_errors=True)
    return iso
