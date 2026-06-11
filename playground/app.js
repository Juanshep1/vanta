// Vanta Playground — runs the Vanta interpreter (and the CHIP-8 emulator
// written in Vanta) in the browser via Pyodide (Python compiled to WebAssembly).

const statusEl = document.getElementById("status");
const outputEl = document.getElementById("output");
const sourceEl = document.getElementById("source");
const runBtn = document.getElementById("run");

// Python glue defined inside Pyodide. It imports the unmodified vanta.py and
// exposes small functions the page can call.
const BOOTSTRAP = `
import sys
sys.path.insert(0, '.')
import vanta
import js, builtins

# Browsers have no stdin; route Vanta's 'ask' through a JS prompt.
builtins.input = lambda prompt='': (js.window.prompt(prompt) or '')

def vanta_run(code):
    try:
        vanta.run_source(code)
    except vanta.VantaError as e:
        print('Oops! ' + str(e))
    except Exception as e:
        print('Internal error: ' + str(e))

_emu_ready = [False]
def emu_setup(src):
    if not _emu_ready[0]:
        vanta.run_source(src)
        _emu_ready[0] = True

def emu_load(byte_list):
    data = [int(b) for b in byte_list]
    vanta.call_vanta('chip8_init', [])
    vanta.call_vanta('chip8_load', [data])

def emu_step(n):
    vanta.call_vanta('chip8_step', [int(n)])

def emu_display():
    return vanta.call_vanta('chip8_display', [])

def emu_key(i, down):
    vanta.call_vanta('chip8_key', [int(i), 1 if down else 0])
`;

let pyodide, vanta_run, emu_setup, emu_load, emu_step, emu_display, emu_key;

async function boot() {
  pyodide = await loadPyodide();
  // Send all Python stdout to the output pane.
  pyodide.setStdout({ batched: (s) => { outputEl.textContent += s + "\n"; } });

  const vantaSrc = await (await fetch("../vanta.py")).text();
  pyodide.FS.writeFile("vanta.py", vantaSrc);
  await pyodide.runPythonAsync(BOOTSTRAP);

  vanta_run = pyodide.globals.get("vanta_run");
  emu_setup = pyodide.globals.get("emu_setup");
  emu_load = pyodide.globals.get("emu_load");
  emu_step = pyodide.globals.get("emu_step");
  emu_display = pyodide.globals.get("emu_display");
  emu_key = pyodide.globals.get("emu_key");

  const chip8Src = await (await fetch("../emulator/chip8.va")).text();
  emu_setup(chip8Src);

  statusEl.textContent = "Ready.";
  statusEl.classList.add("ready");
  runBtn.disabled = false;
  document.getElementById("load").disabled = false;
}

boot().catch((err) => {
  statusEl.textContent = "Failed to load: " + err;
  statusEl.classList.add("error");
  console.error(err);
});

// ---- Tabs ----------------------------------------------------------------
document.querySelectorAll(".tabs button").forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll(".tabs button").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById(btn.dataset.tab).classList.add("active");
    if (btn.dataset.tab !== "emulator") stopEmulator();
  };
});

// ---- Code mode -----------------------------------------------------------
runBtn.onclick = () => {
  outputEl.textContent = "";
  vanta_run(sourceEl.value);
};

// ---- Emulator mode -------------------------------------------------------
const canvas = document.getElementById("screen");
const ctx = canvas.getContext("2d");
const SCALE = 10;
let running = false;

const KEYMAP = {
  "1": 0x1, "2": 0x2, "3": 0x3, "4": 0xC,
  "q": 0x4, "w": 0x5, "e": 0x6, "r": 0xD,
  "a": 0x7, "s": 0x8, "d": 0x9, "f": 0xE,
  "z": 0xA, "x": 0x0, "c": 0xB, "v": 0xF,
};

function drawFrame(fb) {
  ctx.fillStyle = "#07070d";
  ctx.fillRect(0, 0, 640, 320);
  ctx.fillStyle = "#b388ff";
  for (let y = 0; y < 32; y++) {
    for (let x = 0; x < 64; x++) {
      if (fb[y * 64 + x]) ctx.fillRect(x * SCALE, y * SCALE, SCALE, SCALE);
    }
  }
}

function frame() {
  if (!running) return;
  const cycles = parseInt(document.getElementById("speed").value, 10);
  emu_step(cycles);
  const proxy = emu_display();
  const fb = proxy.toJs();
  proxy.destroy();
  drawFrame(fb);
  requestAnimationFrame(frame);
}

function startEmulator(bytes) {
  emu_load(bytes);
  running = true;
  document.getElementById("stop").disabled = false;
  requestAnimationFrame(frame);
}

function stopEmulator() {
  running = false;
  document.getElementById("stop").disabled = true;
}

document.getElementById("load").onclick = async () => {
  const url = document.getElementById("rom").value;
  const buf = await (await fetch(url)).arrayBuffer();
  startEmulator(Array.from(new Uint8Array(buf)));
};

document.getElementById("stop").onclick = stopEmulator;

document.getElementById("file").onchange = (e) => {
  const f = e.target.files[0];
  if (!f) return;
  const reader = new FileReader();
  reader.onload = () => startEmulator(Array.from(new Uint8Array(reader.result)));
  reader.readAsArrayBuffer(f);
};

window.addEventListener("keydown", (e) => {
  const k = KEYMAP[e.key.toLowerCase()];
  if (k !== undefined && emu_key) { emu_key(k, true); e.preventDefault(); }
});
window.addEventListener("keyup", (e) => {
  const k = KEYMAP[e.key.toLowerCase()];
  if (k !== undefined && emu_key) { emu_key(k, false); e.preventDefault(); }
});
