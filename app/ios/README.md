# Vanta Pocket — the iOS IDE for Vanta

A native iPhone/iPad app for writing and running Vanta anywhere. Think of the
Python IDE apps, but built for Vanta from the ground up — and the programs run
**entirely on the phone**: the real, unmodified `vanta.py` executes inside
CPython compiled to WebAssembly (Pyodide), bundled with the app. No server,
no network, nothing to install on the phone.

## What's inside

- **Files** — multi-file projects in the app's Documents folder (visible in
  the iOS Files app too). Create, rename, duplicate, swipe-to-delete.
- **Editor** — syntax highlighting tuned for Vanta, a line-number gutter,
  auto-indent that knows `if`/`to`/`while` blocks, and a keyboard bar with
  the symbols and keywords Vanta uses most (`let`, `be`, `say`, `give back`,
  brackets, tab).
- **AI fix** — when a run fails, the failing line is painted red in the
  editor (its number too) and an error banner offers one-tap **✨ AI fix**:
  the model gets the file + the error and writes the corrected file back.
- **Console** — slides up from the bottom, streams output live. `ask` in a
  program pops a real native input dialog. Files your program `write_file`s
  show up in your file list.
- **vcode** — the Vanta coding agent as a chat panel. Bring your own
  Anthropic, OpenRouter, Ollama Cloud, or NVIDIA key (Settings — every
  provider keeps its own key and model, so switching never mixes them up;
  the full OpenRouter catalog is in a searchable picker), ask for a program, and vcode writes it, saves it, runs
  it, reads the output, and fixes its own errors. Tap 📎 to attach any of
  your project files and it fixes or builds on them — replies marked
  `# file: name.va` are saved to exactly that file, several at a time if
  needed.
- **Learn** — bundled example programs, one tap to copy into your files.

## Build it

```bash
brew install xcodegen        # once
cd app/ios
xcodegen generate
open VantaPocket.xcodeproj   # pick a simulator or your iPhone, press Run
```

To put it on a real iPhone, select your team under Signing & Capabilities
(a free Apple ID works).

## How it works

```
SwiftUI app
 ├─ editor / files / console / vcode chat   (native)
 └─ VantaEngine: hidden WKWebView
     └─ Pyodide (CPython → WebAssembly, bundled in Resources/pyodide/)
         └─ vanta.py — the real interpreter, bundled from the repo root
```

Everything the engine loads is served from the app bundle through a custom
`vanta-app://` URL scheme handler, which is why it works in airplane mode.
`ask` is routed through `window.prompt`, which WKWebView hands to native
code to present as a dialog. Stop reboots the engine (you can't interrupt
synchronous WebAssembly mid-flight; a reboot takes a couple of seconds).

Because the interpreter runs in a sandboxed WebAssembly VM with no sockets
and no processes, the networking / shell / process builtins (`serve`,
`http_get`, `shell`, `run`, the memory toolkit, hotkeys) are not available
on the phone. Everything else — the whole language and the rest of the
standard library — works.
