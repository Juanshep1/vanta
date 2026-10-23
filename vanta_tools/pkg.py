"""Projects and packages: `vanta new` and `vanta get`.

vanta.json (the manifest):
    {
      "name": "weather",
      "version": "0.1.0",
      "description": "...",
      "entry": "main.va",
      "kind": "cli",
      "dependencies": {
        "colors": {"source": "https://github.com/someone/colors.git", "version": "v1.2.0"}
      }
    }

vanta.lock pins what was installed: {"packages": {"colors": {"source": ..., "version": ...,
"commit": "<git commit>"}}}. Packages install into ./packages/NAME (inside a project) or
~/.vanta/packages/NAME (--global, or outside a project); `import "colors"` finds them."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MANIFEST = "vanta.json"
LOCK = "vanta.lock"

# ------------------------------------------------------------------ vanta new

TEMPLATES = {
    "cli": '''## {name}: a command-line tool.

## Says hello to everyone named on the command line.
to greet(who)
    give back "Hello, {{who}}!"
end

let names be arguments()
if length(names) is 0
    say greet("world")
otherwise
    for each who in names
        say greet(who)
    end
end
''',
    "game": '''## {name}: a 2D game. Run it with: vanta build main.va --run

window(640, 480, "{name}")

let x be 320
let y be 240
let speed be 220

## Moves the player with the arrow keys (dt is the seconds since the last frame).
to update(dt)
    if key_down("left")
        change x to x - speed * dt
    end
    if key_down("right")
        change x to x + speed * dt
    end
    if key_down("up")
        change y to y - speed * dt
    end
    if key_down("down")
        change y to y + speed * dt
    end
end

## Draws one frame.
to draw()
    clear("midnightblue")
    circle(x, y, 24, "gold")
    draw_text("Arrow keys move. Close the window to quit.", 16, 16, "white")
end
''',
    "web": '''## {name}: a small web server. Run it, then open http://localhost:8080

## Answers one request: a page for /, JSON for /api, and 404 for anything else.
to handle(req)
    let path be req["path"]
    if path is "/"
        give back "<h1>Hello from {name}</h1><p>Try <a href='/api'>/api</a>.</p>"
    end
    if path is "/api"
        give back {{"status": 200, "body": {{"ok": yes, "app": "{name}"}}}}
    end
    give back {{"status": 404, "body": "Not found"}}
end

say "Serving on http://localhost:8080 (Ctrl-C to stop)"
serve(8080, handle)
''',
    "os": '''## {name}: a tiny operating system kernel.
## Build it with: vanta build main.va --kernel

clear_screen()
set_color("lime")
say "Welcome to {name}!"
set_color("white")
say "Press keys to see them. Press Esc to power off."

while yes
    let key be read_key()
    if key is "escape"
        say "Goodbye."
        power_off()
    end
    say "you pressed " + key
end
''',
}

TEST_TEMPLATES = {
    "cli": '''import "../main.va"

test "greets someone by name"
    expect greet("Ada") is "Hello, Ada!"
end

test "greets the world"
    expect greet("world") contains "world"
end
''',
}


def write(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def cmd_new(V, args):
    """vanta new NAME [--cli|--game|--web|--os]"""
    kind, name = "cli", None
    for a in args:
        if a in ("--cli", "--game", "--web", "--os"):
            kind = a[2:]
        elif a.startswith("-"):
            print(f"Oops! unknown option {a} (use --cli, --game, --web or --os)")
            return 1
        else:
            name = a
    if not name:
        print("Usage: vanta new NAME [--cli | --game | --web | --os]")
        return 1
    folder = name
    name = os.path.basename(os.path.normpath(name))
    if not re.fullmatch(r"[A-Za-z_][\w-]*", name):
        print(f"Oops! '{name}' isn't a good project name (use letters, digits, _ and -)")
        return 1
    if os.path.exists(folder) and os.listdir(folder):
        print(f"Oops! {folder} already exists and isn't empty")
        return 1
    manifest = {"name": name, "version": "0.1.0", "description": f"A Vanta {kind} project.",
                "entry": "main.va", "kind": kind, "dependencies": {}}
    write(os.path.join(folder, MANIFEST), json.dumps(manifest, indent=2) + "\n")
    write(os.path.join(folder, "main.va"), TEMPLATES[kind].format(name=name))
    if kind == "cli":
        tests = TEST_TEMPLATES["cli"]
    elif kind == "web":
        tests = (
            '## The web template keeps its handler in main.va; test your own helpers here.\n\n'
            'to page_title(app)\n    give back "Hello from " + app\nend\n\n'
            'test "builds the page title"\n    expect page_title("' + name + '") is "Hello from ' + name + '"\nend\n')
    else:
        tests = ('## Game and kernel programs need a window or a machine to run; test your plain\n'
                 '## helper functions here.\n\nto clamp_to(x, low, high)\n    give back max(low, min(high, x))\nend\n\n'
                 'test "keeps the player on screen"\n    expect clamp_to(700, 0, 640) is 640\n    expect clamp_to(-5, 0, 640) is 0\nend\n')
    write(os.path.join(folder, "tests", "test_main.va"), tests)
    run_line = {"cli": "vanta run main.va", "game": "vanta build main.va --run",
                "web": "vanta run main.va", "os": "vanta build main.va --kernel"}[kind]
    write(os.path.join(folder, "README.md"),
          f"# {name}\n\nA Vanta {kind} project.\n\n```\n{run_line}     # run it\n"
          f"vanta test               # run the tests in tests/\nvanta fmt                # tidy the code\n"
          f"vanta get                # install the dependencies in vanta.json\n```\n")
    write(os.path.join(folder, ".gitignore"), "packages/\n*.c\n*.app/\n.DS_Store\n")
    print(f"Created {kind} project '{name}' in {folder}/")
    print(f"  vanta.json  main.va  tests/test_main.va  README.md  .gitignore\n")
    print(f"  cd {folder}\n  {run_line}")
    return 0


# ------------------------------------------------------------------ manifests

def find_project(start=None):
    """The folder holding vanta.json, searching upward from `start` (default: cwd)."""
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, MANIFEST)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except ValueError as e:
        raise PackageError(f"{path} isn't valid JSON: {e}")


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


class PackageError(Exception):
    pass


# ------------------------------------------------------------------ sources

def split_version(spec):
    """'url@v1.2' -> ('url', 'v1.2'); git@host:user/repo stays whole."""
    at = spec.rfind("@")
    if at > max(spec.rfind("/"), spec.rfind(":")):
        return spec[:at], spec[at + 1:]
    return spec, None


def registry():
    src = os.environ.get("VANTA_REGISTRY") or os.path.join(os.path.expanduser("~"), ".vanta", "registry.json")
    if src.startswith(("http://", "https://")):
        import urllib.request
        try:
            with urllib.request.urlopen(src, timeout=15) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:
            raise PackageError(f"could not read the package index {src}: {e}")
    return load_json(src, {})


def resolve_source(source):
    """Turn what the user typed into something git (or a copy) can fetch."""
    if os.path.isdir(source):
        return os.path.abspath(source)
    if re.match(r"^(https?|git|ssh|file)://", source) or source.startswith("git@") or source.endswith(".git"):
        return source
    if re.fullmatch(r"[\w.-]+/[\w.-]+", source):
        return f"https://github.com/{source}.git"
    index = registry()
    if source in index:
        entry = index[source]
        return entry["source"] if isinstance(entry, dict) else entry
    raise PackageError(f"don't know where to find '{source}' — give a git URL, user/repo, a folder, "
                       f"or add it to ~/.vanta/registry.json")


def default_name(source):
    base = os.path.basename(source.rstrip("/"))
    if base.endswith(".git"):
        base = base[:-4]
    if ":" in base:
        base = base.split(":")[-1]
    for prefix in ("vanta-", "va-"):
        if base.startswith(prefix) and len(base) > len(prefix):
            base = base[len(prefix):]
    return base


def git(*args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise PackageError(f"git {' '.join(args[:2])} failed: {(r.stderr or r.stdout).strip()}")
    return r.stdout.strip()


def fetch(source, version=None, commit=None):
    """Fetch a package into a temporary folder. Returns (folder, commit or None)."""
    tmp = tempfile.mkdtemp(prefix="vanta-get-")
    dest = os.path.join(tmp, "pkg")
    local = os.path.isdir(source)
    if local and not os.path.isdir(os.path.join(source, ".git")):
        if version:
            raise PackageError(f"{source} is a plain folder, so it has no versions (drop @{version})")
        shutil.copytree(source, dest, ignore=shutil.ignore_patterns("packages", ".git"))
        return dest, None
    if shutil.which("git") is None:
        raise PackageError("installing packages needs git (https://git-scm.com)")
    git("clone", "--quiet", source, dest)
    if commit:
        git("checkout", "--quiet", commit, cwd=dest)
    elif version:
        tags = git("tag", "--list", cwd=dest).split()
        tag = version if version in tags else ("v" + version if "v" + version in tags else
                                               (version[1:] if version.startswith("v") and version[1:] in tags else None))
        if tag is None:
            shown = ", ".join(tags[-10:]) or "none"
            raise PackageError(f"{source} has no version {version} (its tags: {shown})")
        git("checkout", "--quiet", f"tags/{tag}", cwd=dest)
    head = git("rev-parse", "HEAD", cwd=dest)
    shutil.rmtree(os.path.join(dest, ".git"), ignore_errors=True)
    return dest, head


def install(spec_source, version, packages_dir, locked=None, name=None, seen=None, quiet=False):
    """Install one package (and its own dependencies). Returns lock entries {name: {...}}."""
    seen = seen if seen is not None else set()
    source = resolve_source(spec_source)
    commit = None
    if locked and locked.get("source") == spec_source and locked.get("version") == version:
        commit = locked.get("commit")
    folder, head = fetch(source, version, commit)
    meta = load_json(os.path.join(folder, MANIFEST), {})
    pname = name or meta.get("name") or default_name(source)
    if not re.fullmatch(r"[A-Za-z_][\w-]*", pname):
        raise PackageError(f"'{pname}' isn't a usable package name")
    target = os.path.join(packages_dir, pname)
    os.makedirs(packages_dir, exist_ok=True)
    if os.path.exists(target):
        shutil.rmtree(target)
    shutil.move(folder, target)
    shutil.rmtree(os.path.dirname(folder), ignore_errors=True)
    if not any(os.path.isfile(os.path.join(target, f)) for f in
               ([meta["entry"]] if meta.get("entry") else []) + ["main.va", pname + ".va"]):
        print(f"  note: {pname} has no main.va (import its files by path: import \"{pname}/FILE.va\")")
    entries = {pname: {"source": spec_source, "version": version, "commit": head}}
    shown = f"{pname} {version}" if version else pname
    if not quiet:
        print(f"  installed {shown}" + (f" ({head[:10]})" if head else "") + f" -> {os.path.relpath(target)}")
    seen.add(pname)
    for dep, spec in (meta.get("dependencies") or {}).items():      # its own dependencies, flat
        if dep in seen:
            continue
        dsrc, dver = parse_dependency(spec)
        entries.update(install(dsrc, dver, packages_dir, name=dep, seen=seen, quiet=quiet))
    return entries


def parse_dependency(spec):
    if isinstance(spec, dict):
        return spec.get("source"), spec.get("version")
    return split_version(str(spec))


def cmd_get(V, args):
    """vanta get [--global] [SOURCE[@VERSION] ...]"""
    global_install = "--global" in args or "-g" in args
    specs = [a for a in args if a not in ("--global", "-g")]
    project = None if global_install else find_project()
    packages_dir = os.path.join(project, "packages") if project else \
        os.path.join(os.path.expanduser("~"), ".vanta", "packages")
    try:
        if not specs:
            if not project:
                print("Oops! there's no vanta.json here. Use 'vanta get SOURCE' to install a package, "
                      "or 'vanta new NAME' to start a project.")
                return 1
            manifest = load_json(os.path.join(project, MANIFEST), {})
            lock = load_json(os.path.join(project, LOCK), {}).get("packages", {})
            deps = manifest.get("dependencies") or {}
            if not deps:
                print("No dependencies in vanta.json.")
                return 0
            new_lock = {}
            for name, spec in deps.items():
                src, ver = parse_dependency(spec)
                new_lock.update(install(src, ver, packages_dir, locked=lock.get(name), name=name))
            save_json(os.path.join(project, LOCK), {"lockfile": 1, "packages": dict(sorted(new_lock.items()))})
            print(f"{len(deps)} dependenc{'y' if len(deps) == 1 else 'ies'} installed; vanta.lock is up to date.")
            return 0
        manifest = load_json(os.path.join(project, MANIFEST), {}) if project else None
        lock = load_json(os.path.join(project, LOCK), {"lockfile": 1, "packages": {}}) if project else None
        for spec in specs:
            src, ver = split_version(spec)
            entries = install(src, ver, packages_dir)
            if project:
                top = next(iter(entries))
                manifest.setdefault("dependencies", {})[top] = {"source": src, "version": ver} if ver else {"source": src}
                lock.setdefault("packages", {}).update(entries)
        if project:
            save_json(os.path.join(project, MANIFEST), manifest)
            lock["packages"] = dict(sorted(lock["packages"].items()))
            save_json(os.path.join(project, LOCK), lock)
            print("Saved to vanta.json and vanta.lock.")
        return 0
    except PackageError as e:
        print(f"Oops! {e}")
        return 1
