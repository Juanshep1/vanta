// Vanta Studio — a full IDE for the Vanta language, in the browser.
// Runs the real vanta.py interpreter via Pyodide, adds a canvas game API,
// and ships with Vee: an AI assistant that writes Vanta projects for you.

"use strict";

/* ================================ state ================================ */

const LS_KEY = "vanta-studio-project";
const LS_PROVIDER = "vanta-studio-provider";        // "anthropic" | "openrouter"
const LS_API = "vanta-studio-apikey";               // anthropic key
const LS_MODEL = "vanta-studio-model";              // anthropic model
const LS_API_OR = "vanta-studio-apikey-or";         // openrouter key
const LS_MODEL_OR = "vanta-studio-model-or";        // openrouter model

const PROVIDERS = {
  anthropic: {
    label: "Claude",
    keyLS: LS_API, modelLS: LS_MODEL,
    defaultModel: "claude-fable-5",
    placeholder: "sk-ant-...",
    note: "Get a key at console.anthropic.com.",
    models: ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6",
             "claude-haiku-4-5-20251001"],
  },
  openrouter: {
    label: "OpenRouter",
    keyLS: LS_API_OR, modelLS: LS_MODEL_OR,
    defaultModel: "anthropic/claude-sonnet-4.6",
    placeholder: "sk-or-...",
    note: "Get a key at openrouter.ai/keys — any model slug from openrouter.ai/models works.",
    models: ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.8",
             "openai/gpt-5", "openai/gpt-5-mini", "google/gemini-2.5-pro",
             "google/gemini-2.5-flash", "deepseek/deepseek-chat",
             "meta-llama/llama-4-maverick"],
  },
};

const getProvider = () => localStorage.getItem(LS_PROVIDER) || "anthropic";
const getAiKey = () => localStorage.getItem(PROVIDERS[getProvider()].keyLS) || "";
const getAiModel = () => {
  const p = PROVIDERS[getProvider()];
  return localStorage.getItem(p.modelLS) || p.defaultModel;
};

let files = {};            // name -> content
let openTabs = [];         // [name]
let active = null;         // current file name
let pyodide = null;
let pyReady = false;
let runProject, ideTick, hasFrame, flushDraws;
let gameLoop = null;       // requestAnimationFrame id
let frameToggle = false;   // 30fps from 60fps RAF
let lastError = "";
let aiHistory = [];        // [{role, content}]
let aiBusy = false;

const $ = (id) => document.getElementById(id);
const statusEl = $("status"), consoleEl = $("console");
const codeEl = $("code"), highlightEl = $("highlight"), gutterEl = $("gutter");
const canvas = $("screen"), ctx = canvas.getContext("2d");

/* ============================== templates ============================== */

const TEMPLATES = [
  { file: "hello.va", name: "Hello, Vanta", desc: "variables, loops, functions, maps" },
  { file: "snake.va", name: "Snake", desc: "a full game — arrows to play" },
  { file: "balls.va", name: "Bouncing Balls", desc: "objects + animation" },
  { file: "paint.va", name: "Paint", desc: "draw with your mouse" },
  { file: "art.va", name: "Night City", desc: "generative art, new every run" },
  { file: "quiz.va", name: "Quiz Show", desc: "console game with ask + match" },
  { file: "bank.va", name: "Bank Accounts", desc: "types, inheritance, errors" },
];

/* ======================= the Python side (bridge) ======================= */
// Defines the canvas/game builtins and run helpers inside Pyodide.
// Draw commands are returned to JS as JSON strings (no proxy leaks).

const BOOTSTRAP = `
import sys, json, builtins
sys.path.insert(0, '.')
import vanta
import js

builtins.input = lambda prompt='': (js.window.prompt(prompt) or '')

_draws = []
_color = ['#e7e3f5']

def _num(v):
    f = float(v)
    return int(f) if f == int(f) else f

def _b_canvas(args):
    _draws.append(["size", _num(args[0]), _num(args[1])])

def _b_clear(args):
    _draws.append(["clear", str(args[0]) if args else "#0d0d17"])

def _b_color(args):
    _color[0] = str(args[0])

def _b_rect(args):
    _draws.append(["rect", _num(args[0]), _num(args[1]), _num(args[2]), _num(args[3]), _color[0]])

def _b_circle(args):
    _draws.append(["circle", _num(args[0]), _num(args[1]), _num(args[2]), _color[0]])

def _b_line(args):
    _draws.append(["line", _num(args[0]), _num(args[1]), _num(args[2]), _num(args[3]), _color[0]])

def _b_text(args):
    size = _num(args[3]) if len(args) > 3 else 16
    _draws.append(["text", _num(args[0]), _num(args[1]), vanta.display(args[2]), size, _color[0]])

def _b_keydown(args):
    return bool(js.vantaKeyDown(str(args[0]).lower()))

def _b_mousex(args):
    return int(js.vantaMouseX())

def _b_mousey(args):
    return int(js.vantaMouseY())

def _b_mousedown(args):
    return bool(js.vantaMouseDown())

def _b_stopgame(args):
    js.vantaStopGame()

_CANVAS = {
    "canvas": _b_canvas, "clear": _b_clear, "color": _b_color,
    "rect": _b_rect, "circle": _b_circle, "line": _b_line, "text_at": _b_text,
    "key_down": _b_keydown, "mouse_x": _b_mousex, "mouse_y": _b_mousey,
    "mouse_down": _b_mousedown, "stop_game": _b_stopgame,
}
for _n, _f in _CANVAS.items():
    vanta.BUILTINS[_n] = _f
    vanta.BUILTIN_VALUES[_n] = vanta.Builtin(_n, _f)

def studio_run(files_json, entry):
    files = json.loads(files_json)
    _draws.clear()
    _color[0] = '#e7e3f5'
    vanta.reset_runtime()
    for name, content in files.items():
        js_safe = name.replace('..', '')
        with open(js_safe, 'w') as f:
            f.write(content)
    try:
        vanta.run_source(files[entry])
        return ""
    except vanta.VantaError as e:
        return "Oops! " + str(e)
    except RecursionError:
        return "Oops! a function called itself too many times"
    except Exception as e:
        return "Internal error: " + str(e)

def studio_flush():
    out = json.dumps(_draws)
    _draws.clear()
    return out

def studio_has_frame():
    return vanta.GLOBAL_ENV.get("on_frame") is not vanta._MISSING

def studio_tick():
    try:
        vanta.call_vanta("on_frame", [])
        return ""
    except vanta.VantaError as e:
        return "Oops! " + str(e)
    except Exception as e:
        return "Internal error: " + str(e)
`;

/* ============================ boot pyodide ============================ */

async function boot() {
  try {
    pyodide = await loadPyodide();
    pyodide.setStdout({ batched: (s) => logOut(s) });
    pyodide.setStderr({ batched: () => {} });
    const src = await (await fetch("../vanta.py")).text();
    pyodide.FS.writeFile("vanta.py", src);
    await pyodide.runPythonAsync(BOOTSTRAP);
    runProject = pyodide.globals.get("studio_run");
    flushDraws = pyodide.globals.get("studio_flush");
    hasFrame = pyodide.globals.get("studio_has_frame");
    ideTick = pyodide.globals.get("studio_tick");
    pyReady = true;
    statusEl.textContent = "Ready";
    statusEl.classList.add("ready");
    $("run").disabled = false;
  } catch (err) {
    statusEl.textContent = "Failed to load interpreter: " + err;
    statusEl.classList.add("error");
  }
}

/* =========================== input bridges =========================== */

const pressedKeys = new Set();
let mouse = { x: 0, y: 0, down: false };

const KEYALIAS = {
  arrowleft: "left", arrowright: "right", arrowup: "up", arrowdown: "down",
  " ": "space", enter: "enter", escape: "escape",
};

window.vantaKeyDown = (name) => pressedKeys.has(name);
window.vantaMouseX = () => mouse.x;
window.vantaMouseY = () => mouse.y;
window.vantaMouseDown = () => mouse.down;
window.vantaStopGame = () => stopGame();

window.addEventListener("keydown", (e) => {
  const k = KEYALIAS[e.key.toLowerCase()] || e.key.toLowerCase();
  pressedKeys.add(k);
  const typing = ["TEXTAREA", "INPUT"].includes(document.activeElement.tagName);
  if (gameLoop && !typing &&
      ["left", "right", "up", "down", "space"].includes(k)) e.preventDefault();
});
window.addEventListener("keyup", (e) => {
  pressedKeys.delete(KEYALIAS[e.key.toLowerCase()] || e.key.toLowerCase());
});
canvas.addEventListener("mousemove", (e) => {
  const r = canvas.getBoundingClientRect();
  mouse.x = Math.round((e.clientX - r.left) * (canvas.width / r.width));
  mouse.y = Math.round((e.clientY - r.top) * (canvas.height / r.height));
});
canvas.addEventListener("mousedown", () => { mouse.down = true; canvas.focus(); });
window.addEventListener("mouseup", () => { mouse.down = false; });

/* ============================== running ============================== */

function renderDraws(json) {
  const cmds = JSON.parse(json);
  for (const c of cmds) {
    switch (c[0]) {
      case "size":
        if (canvas.width !== c[1] || canvas.height !== c[2]) {
          canvas.width = c[1]; canvas.height = c[2];
        }
        break;
      case "clear":
        ctx.fillStyle = c[1];
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        break;
      case "rect":
        ctx.fillStyle = c[5];
        ctx.fillRect(c[1], c[2], c[3], c[4]);
        break;
      case "circle":
        ctx.fillStyle = c[4];
        ctx.beginPath();
        ctx.arc(c[1], c[2], c[3], 0, Math.PI * 2);
        ctx.fill();
        break;
      case "line":
        ctx.strokeStyle = c[5];
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(c[1], c[2]);
        ctx.lineTo(c[3], c[4]);
        ctx.stroke();
        break;
      case "text":
        ctx.fillStyle = c[5];
        ctx.font = `600 ${c[4]}px ui-monospace, Menlo, monospace`;
        ctx.fillText(c[3], c[1], c[2]);
        break;
    }
  }
  return cmds.length;
}

function run() {
  if (!pyReady || !active) return;
  stopGame();
  consoleEl.innerHTML = "";
  lastError = "";
  ctx.fillStyle = "#0d0d17";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  const err = runProject(JSON.stringify(files), active);
  const drew = renderDraws(flushDraws());
  if (err) { logErr(err); showPane("console"); return; }

  if (hasFrame()) {
    showPane("canvasPane");
    canvas.focus();
    $("stopBtn").disabled = false;
    const loop = () => {
      frameToggle = !frameToggle;
      if (frameToggle) {                      // ~30fps
        const tickErr = ideTick();
        renderDraws(flushDraws());
        if (tickErr) { logErr(tickErr); stopGame(); showPane("console"); return; }
      }
      gameLoop = requestAnimationFrame(loop);
    };
    gameLoop = requestAnimationFrame(loop);
  } else if (drew > 0) {
    showPane("canvasPane");
  }
}

function stopGame() {
  if (gameLoop) cancelAnimationFrame(gameLoop);
  gameLoop = null;
  $("stopBtn").disabled = true;
}

function logOut(s) {
  const div = document.createElement("div");
  div.textContent = s;
  consoleEl.appendChild(div);
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

function logErr(s) {
  lastError = s;
  const div = document.createElement("div");
  div.className = "err";
  div.textContent = s;
  const fix = document.createElement("button");
  fix.textContent = "Fix with Vee";
  fix.onclick = () => askVee("__FIX__");
  div.appendChild(fix);
  consoleEl.appendChild(div);
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

function showPane(id) {
  document.querySelectorAll(".bottom-tabs button").forEach((b) =>
    b.classList.toggle("active", b.dataset.pane === id));
  document.querySelectorAll(".pane").forEach((p) =>
    p.classList.toggle("active", p.id === id));
}

/* =========================== syntax highlight =========================== */

const KEYWORDS = new Set(("let be change to if otherwise end repeat while for each in say " +
  "give back stop skip import is and or not yes no nothing times at type has " +
  "attempt rescue new from super match when increase decrease by make fix ask into add me " +
  "plus minus divided over under above below least most than bigger smaller greater more an a").split(" "));

const BUILTINS = new Set(("length text number uppercase lowercase trim replace starts_with ends_with " +
  "find split lines pad_left pad_right join chr code abs round floor ceil sqrt power sin cos tan " +
  "log exp sum product min max random now today clock first last range contains keys values sort " +
  "reverse slice push pop remove_at map keep reduce each count_where find_where sort_by type_of " +
  "is_a is_number is_text is_list is_map is_function is_nothing matches find_all replace_all " +
  "fail assert read_file write_file read_bytes band bor bxor bnot shift_left shift_right run shell " +
  "arguments env to_json from_json canvas clear color rect circle line text_at key_down mouse_x " +
  "mouse_y mouse_down stop_game shuffle choice sample roll chance pi e on_frame").split(" "));

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function highlightLine(line) {
  let out = "", i = 0;
  const n = line.length;
  while (i < n) {
    const c = line[i];
    if (c === "#") {                                   // comment to end of line
      out += `<span class="tok-com">${esc(line.slice(i))}</span>`;
      break;
    }
    if (c === '"') {                                   // string with {interp}
      let j = i + 1, buf = '"';
      while (j < n && line[j] !== '"') {
        if (line[j] === "\\" && j + 1 < n) { buf += line[j] + line[j + 1]; j += 2; continue; }
        buf += line[j]; j++;
      }
      if (j < n) { buf += '"'; j++; }
      const inner = esc(buf).replace(/\{[^}]*\}/g,
        (m) => `</span><span class="tok-interp">${m}</span><span class="tok-str">`);
      out += `<span class="tok-str">${inner}</span>`;
      i = j;
      continue;
    }
    if (/[0-9]/.test(c)) {
      let j = i;
      while (j < n && /[0-9.]/.test(line[j])) j++;
      out += `<span class="tok-num">${line.slice(i, j)}</span>`;
      i = j;
      continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < n && /[A-Za-z0-9_]/.test(line[j])) j++;
      const word = line.slice(i, j);
      if (KEYWORDS.has(word)) out += `<span class="tok-kw">${word}</span>`;
      else if (BUILTINS.has(word)) out += `<span class="tok-fn">${word}</span>`;
      else out += esc(word);
      i = j;
      continue;
    }
    if ("+-*/%^<>=!:[](){},.".includes(c)) {
      out += `<span class="tok-op">${esc(c)}</span>`;
      i++;
      continue;
    }
    out += esc(c);
    i++;
  }
  return out;
}

function refreshEditor() {
  const text = codeEl.value;
  highlightEl.innerHTML = text.split("\n").map(highlightLine).join("\n") + "\n";
  const lines = text.split("\n").length;
  gutterEl.textContent = Array.from({ length: lines }, (_, k) => k + 1).join("\n");
  syncScroll();
}

function syncScroll() {
  highlightEl.scrollTop = codeEl.scrollTop;
  highlightEl.scrollLeft = codeEl.scrollLeft;
  gutterEl.scrollTop = codeEl.scrollTop;
}

function updateLineCol() {
  const pos = codeEl.selectionStart;
  const before = codeEl.value.slice(0, pos).split("\n");
  $("lineCol").textContent = `${before.length}:${before[before.length - 1].length + 1}`;
}

/* ============================ files & tabs ============================ */

function saveProject() {
  localStorage.setItem(LS_KEY, JSON.stringify({ files, openTabs, active }));
}

function loadProject() {
  try {
    const data = JSON.parse(localStorage.getItem(LS_KEY));
    if (data && data.files && Object.keys(data.files).length) {
      files = data.files;
      openTabs = (data.openTabs || []).filter((t) => files[t]);
      active = files[data.active] !== undefined ? data.active : Object.keys(files)[0];
      if (!openTabs.includes(active)) openTabs.push(active);
      return;
    }
  } catch (e) { /* fall through to default */ }
  files = { "main.va": `# Welcome to Vanta Studio!\n# Try a Template from the toolbar, or ask Vee to build you something.\n\nsay "Hello, Vanta!"\n` };
  openTabs = ["main.va"];
  active = "main.va";
}

function renderFiles() {
  const tree = $("fileTree");
  tree.innerHTML = "";
  for (const name of Object.keys(files).sort()) {
    const li = document.createElement("li");
    li.textContent = name;
    li.classList.toggle("active", name === active);
    li.onclick = () => openFile(name);
    const del = document.createElement("button");
    del.className = "del";
    del.textContent = "×";
    del.onclick = (e) => { e.stopPropagation(); deleteFile(name); };
    li.appendChild(del);
    tree.appendChild(li);
  }
  const tabs = $("tabs");
  tabs.innerHTML = "";
  for (const name of openTabs) {
    const tab = document.createElement("div");
    tab.className = "tab" + (name === active ? " active" : "");
    tab.textContent = name;
    tab.onclick = () => openFile(name);
    const x = document.createElement("span");
    x.className = "x";
    x.textContent = " ×";
    x.onclick = (e) => { e.stopPropagation(); closeTab(name); };
    tab.appendChild(x);
    tabs.appendChild(tab);
  }
}

function openFile(name) {
  active = name;
  if (!openTabs.includes(name)) openTabs.push(name);
  codeEl.value = files[name];
  refreshEditor();
  renderFiles();
  saveProject();
}

function closeTab(name) {
  openTabs = openTabs.filter((t) => t !== name);
  if (active === name) {
    active = openTabs[openTabs.length - 1] || Object.keys(files)[0];
    if (active) codeEl.value = files[active];
  }
  refreshEditor();
  renderFiles();
  saveProject();
}

function deleteFile(name) {
  if (Object.keys(files).length === 1) { toast("Can't delete the last file"); return; }
  if (!confirm(`Delete ${name}?`)) return;
  delete files[name];
  openTabs = openTabs.filter((t) => t !== name);
  if (active === name) active = Object.keys(files)[0];
  codeEl.value = files[active];
  refreshEditor();
  renderFiles();
  saveProject();
}

function createFile(name, content = "", open = true) {
  if (!name) return;
  if (!name.endsWith(".va")) name += ".va";
  files[name] = content;
  if (open) openFile(name); else { renderFiles(); saveProject(); }
  return name;
}

function uniqueName(base) {
  if (!files[base]) return base;
  const stem = base.replace(/\.va$/, "");
  let k = 2;
  while (files[`${stem}-${k}.va`]) k++;
  return `${stem}-${k}.va`;
}

/* ================================ Vee ================================ */

const F = "```";

function systemPrompt() {
  const fileDump = Object.entries(files)
    .map(([n, c]) => `--- ${n} ---\n${c.length > 4000 ? c.slice(0, 4000) + "\n...(truncated)" : c}`)
    .join("\n\n");
  return `You are Vee, the friendly AI built into Vanta Studio — a browser IDE for Vanta, a plain-English programming language. You write ONLY valid Vanta (never Python/JS).

VANTA REFERENCE (complete — use nothing else):
Output/vars: say "Hi {name}" (interpolation with {}, {{ }} literal). let x be 5 / change x to 6 / fix K be 9 (const). Comments: #.
Values: numbers, "text", yes/no, nothing, [1,2], {"k": 1}.
Math: + - * / % ^ (words: plus minus times divided by). increase x by 1 / decrease x by 1.
Compare: is, is not, is over/under, is at least/most (or > < >= <= == !=). Logic: and or not. Membership: x is in list.
If: if C ... otherwise if C ... otherwise ... end. Inline: "a" if C otherwise "b".
Match: match v / when 1 ... / otherwise ... end.
Loops: repeat N times ... end | while C ... end | for each x in xs ... end | for each k, v in map ... end. stop=break, skip=continue.
Lists: xs[0], xs[-1], xs[1:3], add v to xs, change xs at 0 to 9, [n*2 for each n in xs if n is over 1], [0] * 4. NOTE: list/map literals must fit on ONE line (build big ones with add ... to).
Maps: m["k"], change m at "k" to v, keys(m), values(m).
Functions: to add(a, b) ... give back a + b ... end. Defaults: to f(x, y be 2). Lambdas: make x give x * 2. Closures work. Higher-order: map/keep/reduce(fn, list[, start]).
Types: type Dog / has name / to speak() ... me.name ... end / end. new Dog("Rex"). setup() runs on creation; show() controls printing. Inheritance: type Pup from Dog, super.speak(), d is a Dog.
Errors: attempt ... rescue e ... end. fail("msg"). assert(cond, "msg").
Input: ask "Q?" into x (browser prompt).
Stdlib: length text number uppercase lowercase trim replace split join sort reverse range contains sum product min max abs round floor ceil sqrt sin cos tan random(a,b) now to_json from_json matches find_all replace_all. import "math"/"lists"/"text"/"random" (random lib: shuffle choice sample roll chance).
RESERVED words (never use as variable names): to be is at in by has from when match make fix new super times back each.

STUDIO CANVAS API (host builtins available here):
canvas(w, h) — set size (do this first, e.g. 480x360). clear("#0d0d17"). color("#b388ff") then rect(x,y,w,h) / circle(x,y,r) / line(x1,y1,x2,y2) / text_at(x,y,"msg"[,size]).
Game loop: define to on_frame() ... end — the IDE calls it 30x/second after the file runs. key_down("left"/"right"/"up"/"down"/"space"/"a"...) -> yes/no. mouse_x() mouse_y() mouse_down(). stop_game().

RESPONSE RULES:
- Be brief and warm. Explanations short; code complete.
- When you create or modify a file, emit it as a fenced block exactly like:
${F}va file=name.va
...entire file content...
${F}
  The IDE turns these into one-click Apply buttons. Always send the COMPLETE file, not a diff.
- Default entry file is the user's active file. For new projects prefer one file unless asked.
- Games MUST use on_frame() for animation — never an infinite while loop (it would freeze the page).

CURRENT PROJECT (active file: ${active}):
${fileDump}
${lastError ? "\nLATEST CONSOLE ERROR:\n" + lastError : ""}`;
}

function addMsg(role, html) {
  const div = document.createElement("div");
  div.className = "msg " + role;
  if (role === "user") div.textContent = html;
  else div.innerHTML = html;
  $("aiMessages").appendChild(div);
  $("aiMessages").scrollTop = $("aiMessages").scrollHeight;
  return div;
}

function mdToHtml(text) {
  // minimal markdown: fenced code (with file= apply buttons), inline code, bold
  let html = "";
  const parts = text.split(/```/);
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 0) {
      html += esc(parts[i])
        .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\n/g, "<br>");
    } else {
      let body = parts[i];
      let fname = null;
      const m = body.match(/^(?:va|vanta)?\s*(?:file=([\w./-]+))?\n/);
      if (m) { fname = m[1] || null; body = body.slice(m[0].length); }
      if (fname) {
        const id = "apply-" + Math.random().toString(36).slice(2);
        const verb = files[fname] !== undefined ? "Update" : "Create";
        html += `<button class="apply" data-file="${esc(fname)}" data-code="${encodeURIComponent(body)}" id="${id}">✓ ${verb} ${esc(fname)}</button>`;
      }
      html += `<pre><code>${esc(body)}</code></pre>`;
    }
  }
  return html;
}

function bindApplyButtons(container) {
  container.querySelectorAll(".apply").forEach((btn) => {
    btn.onclick = () => {
      const name = btn.dataset.file;
      files[name] = decodeURIComponent(btn.dataset.code);
      openFile(name);
      toast(`${name} saved — press Run!`);
      btn.textContent = `✓ Applied ${name}`;
      btn.disabled = true;
    };
  });
}

async function askVee(prompt) {
  if (aiBusy) return;
  if (prompt === "__FIX__") {
    prompt = lastError
      ? `My program failed with this error:\n${lastError}\n\nFix the active file (${active}) and send the full corrected file.`
      : "Review my active file for bugs and improvements.";
  }
  addMsg("user", prompt);
  aiHistory.push({ role: "user", content: prompt });
  const key = getAiKey();
  if (!key) { offlineVee(prompt); return; }

  aiBusy = true;
  const thinking = addMsg("vee thinking", "Vee is thinking");
  try {
    const text = getProvider() === "openrouter"
      ? await callOpenRouter(key)
      : await callAnthropic(key);
    thinking.remove();
    aiHistory.push({ role: "assistant", content: text });
    const div = addMsg("vee", mdToHtml(text));
    bindApplyButtons(div);
  } catch (err) {
    thinking.remove();
    addMsg("vee", `<b>Error:</b> ${esc(String(err.message || err))}`);
  }
  aiBusy = false;
}

async function callAnthropic(key) {
  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "anthropic-dangerous-direct-browser-access": "true",
    },
    body: JSON.stringify({
      model: getAiModel(),
      max_tokens: 8192,
      system: systemPrompt(),
      messages: aiHistory.slice(-12),
    }),
  });
  const data = await resp.json();
  if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
  return (data.content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
}

async function callOpenRouter(key) {
  const resp = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": "Bearer " + key,
      "HTTP-Referer": "https://juanshep1.github.io/vanta/ide/",
      "X-Title": "Vanta Studio",
    },
    body: JSON.stringify({
      model: getAiModel(),
      max_tokens: 8192,
      messages: [{ role: "system", content: systemPrompt() },
                 ...aiHistory.slice(-12)],
    }),
  });
  const data = await resp.json();
  if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
  const msg = data.choices && data.choices[0] && data.choices[0].message;
  if (!msg) throw new Error("empty response from OpenRouter");
  return msg.content || "";
}

function offlineVee(prompt) {
  const p = prompt.toLowerCase();
  let reply;
  const tpl = TEMPLATES.find((t) =>
    p.includes(t.file.replace(".va", "")) || p.includes(t.name.toLowerCase()));
  if (p.includes("game") || tpl) {
    const chosen = tpl || TEMPLATES[1];
    const name = uniqueName(chosen.file);
    fetch(`templates/${chosen.file}`).then((r) => r.text()).then((code) => {
      createFile(name, code);
      addMsg("vee", `I'm in offline mode (no API key), but I loaded my <b>${esc(chosen.name)}</b> template into <code>${esc(name)}</code> — press <b>Run</b>!<br><br>Add a Claude or OpenRouter key in ⚙ settings and I can write brand-new programs for you.`);
    });
    return;
  }
  if (p.includes("error") || p.includes("fix") || lastError) {
    let hint = "Check the line number in the error — Vanta error messages say exactly what they need.";
    if (lastError.includes("doesn't exist yet")) hint = "You used a variable before creating it. Create it first with <code>let name be value</code> — <code>change</code> only updates things that already exist.";
    else if (lastError.includes("missing its 'end'")) hint = "Every <code>if</code>, loop, <code>type</code>, and function must finish with <code>end</code>. Count your blocks!";
    else if (lastError.includes("reserved word")) hint = "That name is a Vanta keyword. Pick a different variable name.";
    else if (lastError.includes("divide by zero")) hint = "Something was divided by 0 — guard it with <code>if divisor is not 0</code>.";
    reply = `${lastError ? `<b>Your error:</b> <code>${esc(lastError)}</code><br><br>` : ""}${hint}<br><br><i>(I'm offline — add an API key in ⚙ settings for full fixes.)</i>`;
  } else if (p.includes("explain")) {
    reply = `Open the <b>Cheatsheet</b> in the toolbar for the whole language on one page. Roughly: <code>let</code> creates, <code>change</code> updates, <code>say</code> prints, blocks end with <code>end</code>, and <code>to name() ... give back ...</code> defines functions.<br><br><i>(Add an API key in ⚙ settings and I'll explain your exact code.)</i>`;
  } else {
    reply = `I'm in <b>offline mode</b> right now. I can still:<br>• load any template (try “make me a snake game”)<br>• explain common errors (run your code, then “fix my error”)<br>• show the <b>Cheatsheet</b><br><br>For full AI — writing new programs, fixing your exact code — add a Claude or OpenRouter key in ⚙ settings.`;
  }
  addMsg("vee", reply);
}

/* ============================== cheatsheet ============================== */

const CHEAT = `
<h3>BASICS</h3><pre>say "Hi {name}"          # print (with interpolation)
let x be 5               # create     change x to 6   # update
fix limit be 100         # constant   # comment</pre>
<h3>DECISIONS</h3><pre>if score is over 90
    say "A"
otherwise if score is over 80
    say "B"
otherwise
    say "C"
end
let g be "pass" if score is at least 60 otherwise "fail"
match cmd
    when "start"
        say "go"
    otherwise
        say "?"
end</pre>
<h3>LOOPS</h3><pre>repeat 3 times ... end
while count is over 0 ... end
for each item in [1, 2, 3] ... end
for each key, value in map ... end     # stop / skip</pre>
<h3>LISTS &amp; MAPS</h3><pre>let xs be [1, 2, 3]      xs[0]  xs[-1]  xs[1:3]
add 4 to xs              change xs at 0 to 9
[n * n for each n in xs if n is over 1]
let m be { "name": "Ada" }    m["name"]   keys(m)</pre>
<h3>FUNCTIONS</h3><pre>to add(a, b)
    give back a + b
end
to greet(who, hi be "Hey") ... end     # default arg
let dbl be make x give x * 2           # lambda
map(dbl, xs)   keep(fn, xs)   reduce(fn, xs, 0)</pre>
<h3>TYPES</h3><pre>type Dog
    has name
    to speak()
        give back me.name + " barks"
    end
end
let d be new Dog("Rex")
type Pup from Dog ... super.speak() ... d is a Dog</pre>
<h3>ERRORS</h3><pre>attempt
    fail("boom")
rescue problem
    say "caught: {problem}"
end</pre>
<h3>CANVAS (Studio only)</h3><pre>canvas(480, 360)   clear("#0d0d17")   color("#b388ff")
rect(x, y, w, h)   circle(x, y, r)   line(x1,y1,x2,y2)
text_at(x, y, "msg", 16)
to on_frame() ... end        # runs 30x/second
key_down("left")  mouse_x()  mouse_y()  mouse_down()</pre>`;

/* =============================== wiring =============================== */

function toast(msg) {
  let t = $("toast");
  if (!t) {
    t = document.createElement("div");
    t.id = "toast";
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.classList.add("show");
  setTimeout(() => t.classList.remove("show"), 2200);
}

function init() {
  loadProject();
  codeEl.value = files[active] || "";
  refreshEditor();
  renderFiles();
  $("cheatBody").innerHTML = CHEAT;

  // editor
  codeEl.addEventListener("input", () => {
    files[active] = codeEl.value;
    refreshEditor();
    saveProject();
  });
  codeEl.addEventListener("scroll", syncScroll);
  codeEl.addEventListener("keyup", updateLineCol);
  codeEl.addEventListener("click", updateLineCol);
  codeEl.addEventListener("keydown", (e) => {
    if (e.key === "Tab") {
      e.preventDefault();
      const s = codeEl.selectionStart, t = codeEl.selectionEnd;
      codeEl.value = codeEl.value.slice(0, s) + "    " + codeEl.value.slice(t);
      codeEl.selectionStart = codeEl.selectionEnd = s + 4;
      files[active] = codeEl.value;
      refreshEditor();
    }
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); run(); }
  });

  // toolbar
  $("run").onclick = run;
  $("stopBtn").onclick = stopGame;
  $("newFile").onclick = () => {
    const name = prompt("New file name:", uniqueName("untitled.va"));
    if (name) createFile(name.trim());
  };
  $("exportBtn").onclick = () => {
    const blob = new Blob([JSON.stringify({ files }, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "vanta-project.json";
    a.click();
  };
  $("importBtn").onclick = () => $("importFile").click();
  $("importFile").onchange = (e) => {
    const f = e.target.files[0];
    if (!f) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const data = JSON.parse(reader.result);
        if (!data.files) throw new Error("not a Vanta Studio project");
        files = data.files;
        openTabs = [Object.keys(files)[0]];
        active = openTabs[0];
        codeEl.value = files[active];
        refreshEditor(); renderFiles(); saveProject();
        toast("Project imported");
      } catch (err) { toast("Import failed: " + err.message); }
    };
    reader.readAsText(f);
  };

  // templates menu
  const menu = $("templatesMenu");
  for (const t of TEMPLATES) {
    const b = document.createElement("button");
    b.innerHTML = `${esc(t.name)}<small>${esc(t.desc)}</small>`;
    b.onclick = async () => {
      menu.classList.remove("open");
      const code = await (await fetch(`templates/${t.file}`)).text();
      createFile(uniqueName(t.file), code);
      toast(`${t.name} loaded — press Run!`);
    };
    menu.appendChild(b);
  }
  $("templatesBtn").onclick = (e) => { e.stopPropagation(); menu.classList.toggle("open"); };
  document.addEventListener("click", () => menu.classList.remove("open"));

  // bottom panes
  document.querySelectorAll(".bottom-tabs button").forEach((b) => {
    b.onclick = () => showPane(b.dataset.pane);
  });

  // AI
  $("aiForm").onsubmit = (e) => {
    e.preventDefault();
    const text = $("aiText").value.trim();
    if (!text) return;
    $("aiText").value = "";
    askVee(text);
  };
  $("aiText").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("aiForm").requestSubmit(); }
  });
  document.querySelectorAll(".chip").forEach((c) => {
    c.onclick = () => askVee(c.dataset.prompt);
  });

  // settings
  const refreshAiMode = () => {
    const p = PROVIDERS[getProvider()];
    $("aiMode").textContent = getAiKey()
      ? `${p.label} · ${getAiModel().replace("claude-", "")}`
      : "offline helper · add an API key for full AI";
  };
  const fillProviderFields = (provider) => {
    const p = PROVIDERS[provider];
    $("apiKey").value = localStorage.getItem(p.keyLS) || "";
    $("apiKey").placeholder = p.placeholder;
    $("aiModel").value = localStorage.getItem(p.modelLS) || p.defaultModel;
    $("providerNote").textContent = p.note;
    const list = $("modelList");
    list.innerHTML = "";
    for (const m of p.models) {
      const o = document.createElement("option");
      o.value = m;
      list.appendChild(o);
    }
  };
  refreshAiMode();
  $("settings").onclick = () => {
    $("aiProvider").value = getProvider();
    fillProviderFields(getProvider());
    $("settingsModal").hidden = false;
  };
  $("aiProvider").onchange = () => fillProviderFields($("aiProvider").value);
  $("settingsSave").onclick = () => {
    const provider = $("aiProvider").value;
    const p = PROVIDERS[provider];
    localStorage.setItem(LS_PROVIDER, provider);
    const k = $("apiKey").value.trim();
    if (k) localStorage.setItem(p.keyLS, k); else localStorage.removeItem(p.keyLS);
    const m = $("aiModel").value.trim();
    if (m) localStorage.setItem(p.modelLS, m); else localStorage.removeItem(p.modelLS);
    $("settingsModal").hidden = true;
    refreshAiMode();
    toast(k ? `Vee is powered by ${p.label}!` : "Vee is in offline mode");
  };
  $("settingsClose").onclick = () => { $("settingsModal").hidden = true; };

  // cheatsheet
  $("cheatsheet").onclick = () => { $("cheatModal").hidden = false; };
  $("cheatClose").onclick = () => { $("cheatModal").hidden = true; };

  // greeting
  addMsg("vee", `Hey! I'm <b>Vee</b> — I live inside Vanta Studio and I write Vanta.<br><br>Try: <i>“make me a snake game”</i>, <i>“explain my code”</i>, or run something and click <i>“fix my error”</i>.<br><br>⚙ Add a Claude or OpenRouter API key to give me my full brain.`);

  boot();
}

init();
