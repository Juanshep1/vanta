#!/usr/bin/env python3
"""Headless test for Vanta's HTTP server + client.

Starts a real Vanta web server (written in Vanta) in a background process,
makes live requests to it with Vanta's own http_get, and checks the responses.
Proves the full client<->server round-trip works end to end. Exit 0 on success.
"""

import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VANTA = os.path.join(HERE, "vanta.py")
PORT = 8771

SERVER = f"""
to handle(req)
    let path be req["path"]
    if path is "/"
        give back "<h1>hello from vanta</h1>"
    end
    if path is "/json"
        let name be req["query"]["name"]
        give back {{"status": 200, "body": {{"ok": yes, "name": name}}, "type": "application/json"}}
    end
    give back {{"status": 404, "body": "nope"}}
end
serve({PORT}, handle)
"""

CLIENT = f"""
let a be http_get("http://localhost:{PORT}/")
let abody be a["body"]
say abody
let b be http_get("http://localhost:{PORT}/json?name=Vanta")
say b["body"]
let c be http_get("http://localhost:{PORT}/missing")
let code be c["status"]
say code
"""


def write(name, text):
    path = os.path.join(HERE, name)
    with open(path, "w") as f:
        f.write(text)
    return path


def main():
    srv_path = write("_server_test.va", SERVER)
    cli_path = write("_client_test.va", CLIENT)
    proc = subprocess.Popen([sys.executable, VANTA, srv_path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # wait for the port to accept connections
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://localhost:{PORT}/", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)

        result = subprocess.run([sys.executable, VANTA, cli_path],
                                capture_output=True, text=True, timeout=30)
        out = result.stdout.strip().splitlines()
        assert result.returncode == 0, f"client crashed: {result.stderr}"
        assert out[0] == "<h1>hello from vanta</h1>", f"home page wrong: {out}"
        assert '"ok": true' in out[1] and '"name": "Vanta"' in out[1], f"json wrong: {out}"
        assert out[2] == "404", f"status code wrong: {out}"
        print("server_headless: PASS — Vanta served HTML + JSON and returned 404")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        for p in (srv_path, cli_path):
            try:
                os.remove(p)
            except OSError:
                pass


if __name__ == "__main__":
    main()
