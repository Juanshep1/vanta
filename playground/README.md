# Vanta Playground

A single-page web app that runs Vanta in your browser. It loads the unmodified
`vanta.py` interpreter with [Pyodide](https://pyodide.org) (CPython compiled to
WebAssembly), so the language you run here is exactly the language in this repo.

Two modes:
- **Code** — write Vanta, press Run, see the output.
- **Emulator** — load a `.ch8` ROM and play it. The entire CHIP-8 CPU is
  `emulator/chip8.va` — pure Vanta. The browser only provides the screen,
  keyboard, and the per-frame timing (as every emulator relies on its host for).

## Run it locally

Serve the repository root (so the page can fetch `../vanta.py`, `../emulator/`,
and `../roms/`) and open the playground:

```bash
cd /path/to/vanta
python3 -m http.server 8000
# then open http://localhost:8000/playground/
```

## How it works
- `index.html` / `style.css` — the page.
- `app.js` — boots Pyodide, `fetch`es `../vanta.py` into Pyodide's filesystem,
  `import vanta`, and exposes small helpers. Vanta output (Python `print`) is
  routed to the output pane via Pyodide's stdout hook.
- The emulator frame loop lives in JS (`requestAnimationFrame`) because Pyodide
  is synchronous — a Vanta `while` loop would freeze the tab. Each frame, JS
  calls the Vanta functions `chip8_step`, `chip8_display`, and `chip8_key`
  through the `call_vanta` bridge in `vanta.py`.

## Notes
- It's a tree-walking interpreter inside WebAssembly, so it's not fast. Simple
  ROMs (IBM logo, Breakout) are fine; heavier ones run slower. Use the speed
  slider to trade smoothness for accuracy.
- `ask` (input) is wired to the browser's `prompt()` dialog.

## Hosting
This folder is static and works on GitHub Pages. With Pages enabled on the repo,
it's served at `https://juanshep1.github.io/vanta/playground/`.
