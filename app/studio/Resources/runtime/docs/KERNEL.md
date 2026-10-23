# Vanta on bare metal — writing an operating system in Vanta

`vantac --kernel` compiles a Vanta program into a **kernel**: a file a PC (or QEMU) boots directly, with no
Windows, macOS or Linux underneath. Your program *is* the operating system. The whole Vanta language works —
functions, closures, types, lists, maps, text, `attempt`/`rescue`, the garbage collector — plus a set of kernel
builtins for the screen, keyboard, timer, interrupts, hardware ports, memory, graphics and an in-memory file system.

```
python3 native/vantac.py examples/os/hello_kernel.va --kernel -o out/hello.elf
qemu-system-x86_64 -kernel out/hello.elf
```

```
# hello_kernel.va
say "Hello from Vanta!"
halt()
```

[examples/os/clock_kernel.va](../examples/os/clock_kernel.va) adds a timer, the keyboard and an interrupt handler,
and the big one, [examples/os/vantaos.va](../examples/os/vantaos.va), boots to a colorful banner and a shell with
files, a calculator, snake, a multitasking demo and graphics.

---

## 1. Building

```
python3 native/vantac.py kernel.va --kernel -o out/kernel.elf [--arch x86|arm64] [--iso out/vanta.iso] [--keep-c] [--debug]
vanta build --kernel kernel.va            # the vanta CLI passes this through to vantac
```

| option | what it does |
|---|---|
| `--kernel` | build a bare-metal kernel instead of a desktop program |
| `-o FILE` | the kernel file (default: next to the source, `.elf`) |
| `--arch x86` | (default) a 64-bit PC kernel, loaded with the Multiboot standard |
| `--arch arm64` | a kernel for QEMU's arm64 `virt` board (serial console only) |
| `--iso FILE` | also make a bootable CD / USB-stick image (x86, needs `xorriso` + `limine`) |
| `--keep-c` | keep the generated C next to the kernel |
| `--debug` | build without optimisation, with debug info |

Tools: any `clang` (Homebrew's LLVM is preferred), `ld.lld` and `llvm-objcopy`
(macOS: `brew install llvm lld`; Linux: `apt install clang lld llvm`). For `--iso`: `brew install xorriso limine`.
The runtime's objects are compiled once and cached in `~/.cache/vanta/kernel-<arch>-<hash>/` (or `$VANTA_CACHE`), so a
rebuild takes about a second.

**What a kernel program can't use.** Builtins that need an operating system underneath — files on a disk
(`read_file`, `write_file`, `list_dir`, ...), `arguments`, `env`, processes, networking, threads, databases, SDL games —
are refused at compile time with a message naming each one and its line:

```
Oops! kernel builds can't use these, because there is no operating system underneath: read_file (files, line 2).
For files, use the ram file system: write_to_file, read_from_file, list_files, file_exists, delete_file;
these aren't available in kernel builds: run (needs processes and the system, line 3)
```

Everything else in the core library works: maths, text, lists, maps, sets, `sort`, `map`/`keep`/`reduce`, JSON,
big whole numbers, `now()`, `clock()`, `sleep(seconds)`, `random`, ...

---

## 2. How it boots (x86)

1. **The boot loader** — QEMU's `-kernel`, GRUB or Limine — finds the *Multiboot header* in the first 8 KiB of the
   kernel file (magic number `0x1BADB002`, flags: page-align, give us the memory map), loads the kernel at 1 MiB and
   jumps to `_start` in **32-bit protected mode**, with a pointer to the *Multiboot information* (memory map, boot
   loader name, framebuffer if any). The kernel is a 64-bit program wrapped in a 32-bit ELF file, which is what
   Multiboot loaders accept.
2. **`_start`** (`native/runtime/kernel/boot_x86_64.S`) checks that the CPU can run 64-bit code, builds page tables
   that map the first 4 GiB of memory one-to-one (virtual address = physical address, 2 MiB pages), turns on PAE,
   long mode and paging, loads a 64-bit GDT and jumps into 64-bit code. It turns on SSE (the compiler uses it for
   decimals) and calls `kmain`.
3. **`kmain`** (`pc.c`) sets up the serial port, gives every usable page of RAM from the memory map to the page
   allocator, installs the interrupt table (IDT), remaps the PIC, starts the PIT timer at 1000 Hz, reads the clock
   chip, and turns interrupts on.
4. **`kmain_common`** (`kernel.c`) clears the screen, runs the runtime's C constructors (they register builtin
   tables), registers the kernel builtins and calls the compiled Vanta program's `main`.
5. When the program ends, the kernel prints `Program finished. System halted.` and stops the CPU. An uncaught error
   prints `Oops! line N: ...` like on a desktop, then halts.

On arm64, QEMU jumps to `_start` (`boot_arm64.S`) at EL1/EL2: it drops to EL1, turns on the FPU, sets up an
identity-mapped MMU (1 GiB blocks: devices below 1 GiB, cached RAM above) and calls `kmain_arm64`, which reads the
amount of RAM from the device tree.

### Memory layout (x86)

```
0x0000_0000 - 0x000F_FFFF   first megabyte: BIOS data, VGA text memory at 0xB8000 (never handed out)
0x0010_0000 - _kernel_end   the kernel: Multiboot header, code, constants, data, bss (incl. a 1 MiB stack
                            and the page tables)
_kernel_end - end of RAM    free pages: the page allocator owns them; the heap takes them as it grows
0xFD00_0000 (typically)     the graphics card's framebuffer (QEMU), mapped like everything below 4 GiB
```

* **Page allocator** (`kmem.c`): one bit per 4 KiB page of the first 4 GiB. Usable RAM comes from the Multiboot memory
  map; the first megabyte, the kernel image and the boot information are reserved.
* **Heap** (`malloc`/`free`): small blocks (up to 4 KiB) come from 27 size classes carved out of 1 MiB arenas, and go
  back on a free list per class; big blocks get their own run of pages, returned to the page allocator when freed.
* **Vanta values** live on that heap and are collected by the runtime's normal mark-and-sweep garbage collector,
  which runs at safe points (function entries and loop turns) — exactly as on a desktop.

On arm64, RAM starts at `0x4000_0000`; the device tree is at the start of RAM and the kernel is loaded 1 MiB in.

### How the normal Vanta runtime runs without an operating system

The runtime files (`vrt.c`, `vrt_builtins.c`, `vrt_core.c`, `vrt_big.c`, ...) are compiled unchanged with
`-ffreestanding` against the kernel's own small C library headers (`native/runtime/kernel/include/`):

* `libc.c` — `memcpy`/`memset`/`strlen`/..., ctype, a full `printf` family (doubles print exactly, using a small
  bignum), `strtod`/`strtol`, `qsort`, time functions (from the real-time clock), and stdio that writes to the
  console. `fopen`/`stat`/`opendir` simply fail (and the compiler refuses the builtins that would call them).
* `kmath.c` — `sqrt`, `exp`, `log`, `pow`, `sin`, `cos`, `atan2`, ... On x86 they use the x87 unit's 80-bit
  instructions, so results match a desktop to the last digit; arm64 uses portable C.
* `setjmp`/`longjmp` (for `attempt`/`rescue`) are in the boot assembly.

---

## 3. Kernel builtins

These exist only in `--kernel` builds. All names are plain English; arguments in `[brackets]` are optional.

### The screen (text)

The PC text screen is 80 columns × 25 rows (x from 0 to 79, y from 0 to 24). `say` writes at the cursor and scrolls;
it also copies everything to the serial port (COM1), which is how tests read the output.

| builtin | what it does |
|---|---|
| `say value` | print a line (screen + serial) |
| `ask "prompt" into name` | read a line typed on the keyboard (or the serial port): backspace works, ↑/↓ recall earlier lines; a number comes back as a number |
| `clear_screen([color])` | clear the screen; one color name colors the background: `clear_screen("blue")` |
| `print_at(x, y, text, [color])` | write text at a position without moving the cursor |
| `set_color(color)` | the color for what `say` prints next |
| `set_cursor(x, y)` / `cursor_position()` | move the cursor / where it is, as `[x, y]` |
| `show_cursor()` / `hide_cursor()` | the blinking cursor |
| `screen_columns()` / `screen_rows()` | the size of the text screen in characters |
| `keep_top_rows(n)` | the top `n` rows stay put when the screen scrolls (for a status bar) |

**Colors** are names — `black, blue, green, cyan, red, magenta (purple), brown (orange), light gray, dark gray,
light blue, light green, light cyan, light red, pink, yellow, white` — optionally with a background:
`"yellow on blue"`. A number 0–255 also works: background × 16 + text color (the VGA attribute byte).

```
clear_screen("black")
print_at(30, 10, "Welcome!", "yellow on blue")
set_color("light green")
say "ready."
```

Text can include box and block characters, which the screen draws: `█ ░ ▒ ▓ ▀ ▄ ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ ═ ║ ╔ ╗ ╚ ╝ • · ° ← ↑ → ↓ ♥ ★ ■ ▲ ▼ ◆`.

### The keyboard

| builtin | what it does |
|---|---|
| `read_key()` | wait for a key and return its name |
| `poll_key()` | the next key if one was pressed, otherwise `""` (never waits — for games) |
| `key_pressed()` | is a key waiting to be read? |
| `key_pressed(name)` | is that key held down right now? `key_pressed("left")` |
| `clear_keys()` | forget keys pressed so far |

Key names: letters and symbols as typed (`"a"`, `"A"`, `"?"`, `" "`), and `"enter"`, `"backspace"`, `"tab"`,
`"escape"`, `"up"`, `"down"`, `"left"`, `"right"`, `"home"`, `"end"`, `"page up"`, `"page down"`, `"insert"`,
`"delete"`, `"f1"` … `"f12"`, `"ctrl+c"` (ctrl + any letter). The keyboard driver reads the PS/2 keyboard
(scancode set 1, shift, caps lock, ctrl); keys typed on the serial line arrive the same way (arrow escape codes too).

```
say "Press a key..."
let k be read_key()
say "You pressed {k}"
```

### Time

| builtin | what it does |
|---|---|
| `ticks()` | milliseconds since boot (the timer chip ticks 1000 times a second) |
| `uptime()` | whole seconds since boot |
| `sleep_ms(ms)` | wait; the CPU sleeps (`hlt`) until the time is up |
| `every(ms, function)` | run a function every `ms` milliseconds; returns a timer id |
| `stop_timer(id)` | stop it |
| `now()`, `clock()`, `sleep(seconds)` | (core builtins) the date/time from the real-time clock, in UTC |

```
to tick()
    print_at(70, 0, clock(), "white on blue")
end
every(1000, tick)        # a clock in the corner, updated every second
```

### Interrupts

| builtin | what it does |
|---|---|
| `on_interrupt(irq, function)` | run a Vanta function when hardware interrupt `irq` (0–15) happens; `on_interrupt(irq, nothing)` removes it |
| `enable_interrupts()` / `disable_interrupts()` | the CPU's interrupt flag (`sti` / `cli`) |

IRQ numbers on a PC: 0 timer, 1 keyboard, 3 COM2, 4 COM1, 6 floppy, 8 real-time clock, 12 PS/2 mouse, 14/15 disks.

**How it works — deferred handlers.** When an interrupt arrives, the kernel's C driver answers the hardware at once
(it reads the key, counts the tick, acknowledges the interrupt controller), notes that the interrupt happened and
returns. Your Vanta function runs a moment later, at the program's next *safe point* — every function call and every
loop turn has one, and so does waiting in `read_key`, `ask` or `sleep_ms`. That way a handler is just an ordinary
Vanta function: it can use lists, text and anything else, and it can't confuse the garbage collector. Handlers take
no values. Interrupts without a built-in driver are masked until your handler has run, so a device can't flood the
CPU. The same mechanism runs `every` timers.

```
let presses be 0
to on_key()
    change presses to presses + 1
end
on_interrupt(1, on_key)      # IRQ 1 = the keyboard (the driver still reads the key for read_key)
```

### Hardware: ports and memory

| builtin | what it does |
|---|---|
| `port_in8(port)`, `port_in16(port)`, `port_in32(port)` | read an I/O port (x86 `in`) |
| `port_out8(port, value)`, `port_out16(...)`, `port_out32(...)` | write an I/O port (x86 `out`) |
| `peek8(address)`, `peek16(address)`, `peek32(address)` | read memory at a raw address |
| `poke8(address, value)`, `poke16(...)`, `poke32(...)` | write memory at a raw address |

The first 4 GiB are mapped one-to-one, so an address is a physical address. Reading or writing memory that doesn't
exist is reported as a normal Vanta error (`the CPU stopped: page fault at address 0x...`) that `attempt`/`rescue`
can catch. Addresses must be aligned to the size (a multiple of 2 for `peek16`, of 4 for `peek32`).

```
poke16(0xB8000, 0x4F41)              # a white-on-red "A" in the top-left corner of the VGA text screen
say port_in8(0x64)                   # the keyboard controller's status byte
port_out8(0x70, 0x00)                # ask the clock chip for the seconds...
say port_in8(0x71)                   # ...and read them (BCD)
```

### The system

| builtin | what it does |
|---|---|
| `halt()` | print `System halted.` and stop the CPU |
| `reboot()` | restart the computer (keyboard controller reset, then a CPU reset) |
| `power_off()` | turn the (virtual) machine off — works in QEMU, Bochs and VirtualBox |
| `memory_info()` | a map: `total`, `free`, `used`, `heap`, `heap_used`, `blocks`, `pages`, `free_pages`, `page_size` (bytes) |
| `system_info()` | a map: `arch`, `cpu`, `loader`, `memory`, `screen`, `columns`, `rows` |
| `beep([hz], [ms])` | the PC speaker (QEMU needs `-audiodev ...,id=a -machine pcspk-audiodev=a` to make it audible) |

```
let m be memory_info()
let free_mb be floor(m["free"] / 1048576)
say "free memory: {free_mb} MB"
```

### Graphics (framebuffer)

| builtin | what it does |
|---|---|
| `graphics_mode([width], [height])` | switch to a 32-bit graphics mode (default 800 × 600); `yes` if it worked |
| `screen_width()` / `screen_height()` | size in pixels (characters in text mode) |
| `rgb(r, g, b)` | a color number from red, green, blue (0–255 each) |
| `put_pixel(x, y, color)` | one pixel |
| `fill_rect(x, y, w, h, color)` / `draw_rect(...)` | a filled / outlined rectangle |
| `draw_line(x1, y1, x2, y2, color)` | a line |
| `fill_circle(x, y, radius, color)` | a filled circle |
| `draw_text(x, y, text, color, [scale])` | text with the built-in 8 × 16 font, optionally scaled up |
| `double_buffer(yes)` / `show_frame()` | draw into memory, then show the whole frame at once (no flicker) |

Drawing colors are numbers like `0xFF8800`, `"#FF8800"`, `rgb(255, 136, 0)` or the color names above. In QEMU
graphics uses the Bochs/QEMU display adapter (the default VGA card); if the boot loader already set up a framebuffer
(UEFI), the kernel uses that one. After `graphics_mode`, `say`, `ask` and `print_at` keep working — the console is
drawn on the framebuffer (800 × 600 gives 100 × 37 characters). There is no way back to text mode.

```
if graphics_mode(800, 600)
    fill_rect(0, 0, 800, 600, rgb(20, 30, 80))
    fill_circle(400, 300, 100, "yellow")
    draw_text(300, 500, "Hello, pixels!", "white", 2)
end
```

### The ram file system

Files live in memory, so they disappear when the computer turns off. Names are text and may contain `/`.

| builtin | what it does |
|---|---|
| `write_to_file(name, text)` | create the file or replace what's in it |
| `append_to_file(name, text)` | add to the end (creating the file if needed) |
| `read_from_file(name)` | the file's text (error if there's no such file) |
| `create_file(name)` | an empty file (does nothing if it exists) |
| `list_files()` | all the names, sorted |
| `file_exists(name)` | `yes` / `no` |
| `file_length(name)` | its size in bytes |
| `delete_file(name)` / `rename_file(old, new)` | remove / rename |

```
write_to_file("notes.txt", "buy milk")
append_to_file("notes.txt", "\nwrite an OS")
for each name in list_files()
    say name + ": " + read_from_file(name)
end
```

---

## 4. Running it in QEMU

```
qemu-system-x86_64 -kernel out/vantaos.elf                    # a window with the VGA screen
qemu-system-x86_64 -kernel out/vantaos.elf -serial stdio      # ...and the serial console in your terminal
qemu-system-x86_64 -kernel out/vantaos.elf -display none -serial stdio    # no window: type into the terminal
qemu-system-x86_64 -cdrom out/vantaos.iso                     # boot the ISO (BIOS)
qemu-system-x86_64 -cdrom out/vantaos.iso -m 256M \
    -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd   # boot it with UEFI
qemu-system-aarch64 -M virt -cpu cortex-a72 -kernel out/vantaos-arm.elf -nographic       # arm64 (Ctrl-A X quits)
```

Handy QEMU options: `-m 256M` (more memory), `-no-reboot` (stop instead of rebooting), `-monitor stdio` (the QEMU
monitor: `sendkey a`, `screendump shot.ppm`, `quit`).

**Headless testing** (what `tools/kernel_headless.py` does, and what `python3 run_tests.py` runs; it skips itself if
QEMU or the LLVM tools are missing):

```
qemu-system-x86_64 -kernel out/vantaos.elf -display none -serial file:serial.txt \
    -monitor unix:/tmp/qm.sock,server,nowait -no-reboot
# then, on the monitor socket:  sendkey h  sendkey e  sendkey l  sendkey p  sendkey ret   screendump screen.ppm
```

`python3 tools/kernel_headless.py --shots DIR` also saves PNG screenshots of the screen.

---

## 5. Real hardware and USB sticks

`--iso` makes a hybrid image with the [Limine](https://github.com/limine-bootloader/limine) boot loader that boots
from a CD or a USB stick, on BIOS and UEFI PCs:

```
python3 native/vantac.py examples/os/vantaos.va --kernel -o out/vantaos.elf --iso out/vantaos.iso
# write it to a USB stick — THIS ERASES THE STICK. Find the right disk first (macOS: diskutil list; Linux: lsblk)
diskutil unmountDisk /dev/diskN && sudo dd if=out/vantaos.iso of=/dev/rdiskN bs=4m     # macOS
sudo dd if=out/vantaos.iso of=/dev/sdX bs=4M status=progress && sync                    # Linux
```

Then boot the PC from the stick (usually F12, F11, Esc or F8 at power-on picks the boot device).
On a BIOS PC the kernel runs in VGA text mode. On a UEFI PC there is no text mode, so the ISO boots a copy of the
kernel that asks Limine for a 1024 × 768 framebuffer and the console is drawn there. You can also boot the kernel
with GRUB: `multiboot /boot/kernel.elf` in `grub.cfg`.

Caveats — this is a teaching kernel, not a driver collection:

* **Turn off Secure Boot** in the firmware settings (the image isn't signed). An x86-64 (64-bit) CPU is required.
* **Keyboard:** the driver speaks PS/2. Most PCs emulate PS/2 for USB keyboards ("legacy USB support" in the
  firmware settings) — on some newer machines, especially in UEFI mode, there's no emulation and the keyboard won't
  work. There is no USB driver.
* **No disks, network or sound card drivers:** files live in memory. The serial console needs a real COM1 port.
* **Graphics:** `graphics_mode` uses the framebuffer the boot loader set up (UEFI) or the Bochs/QEMU display adapter;
  on a BIOS PC with a real graphics card it returns `no`.
* `power_off()` only knows emulators; on a real PC use the power button after `halt()`.
* Try it in QEMU first, and never `dd` to a disk you aren't sure about.

---

## 6. arm64

`--arch arm64` builds for QEMU's `virt` board: PL011 serial console (no screen), the generic timer, the PL031 clock,
memory from the device tree, PSCI for `reboot()`/`power_off()`. Input and timers are polled (no interrupt
controller driver yet), so `ask`, `read_key`, `every`, `sleep_ms` work while `on_interrupt`, ports and graphics are
x86-only and report a clear error. Text-screen builtins (`print_at`, ...) do nothing there; `say` goes to the serial
port. Use `-cpu cortex-a72` (or `max`): QEMU's default `virt` CPU is 32-bit.

---

## 7. Inside the kernel runtime

```
native/kernel_build.py          the --kernel build: compile, link (ld.lld), objcopy, ISO
native/runtime/kernel/
    boot_x86_64.S  link_x86_64.ld   Multiboot header, 32→64-bit switch, interrupt stubs, setjmp/longjmp, layout
    boot_arm64.S   link_arm64.ld    arm64 entry, MMU, exception vectors, setjmp/longjmp, layout
    pc.c                            x86 PC: VGA, COM1, IDT, PIC, PIT, PS/2, RTC, PCI + Bochs graphics, reboot
    virt_arm64.c                    arm64 virt: PL011, generic timer, PL031, device tree, PSCI
    kernel.c                        console, keyboard queue, line editor, deferred handlers, graphics, ram files,
                                    and kernel_table — the list of kernel builtins vantac reads
    kmem.c                          page allocator + malloc/free
    libc.c kmath.c include/         the freestanding C library
    font8x16.h                      the framebuffer font (tools/make_kernel_font.py)
tools/kernel_headless.py        the QEMU test
```

**Adding a kernel builtin:** write `static V k_name(int argc, V *a)` in `kernel.c` and add `{"name", k_name}` to
`kernel_table`. vantac reads that table, so the name works in kernel programs immediately (and only there).
The hardware it needs goes behind a `plat_*` function in `kplat.h`, implemented in `pc.c` (and `virt_arm64.c`).
