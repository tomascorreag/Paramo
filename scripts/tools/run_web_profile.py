#!/usr/bin/env python3
"""Run scripts/tools/profile_web.gd inside a real browser, unattended.

    python scripts/tools/run_web_profile.py
    python scripts/tools/run_web_profile.py --headless --fires 80
    python scripts/tools/run_web_profile.py --browser edge --keep-open

Serves docs/ over http, opens the exported build at `?profile`, waits for the
page to POST its own report back, prints it, and cleans up. Exit code 0 if a
report arrived, 1 otherwise.

WHY THE PAGE REPORTS ITSELF instead of being scraped. Driving a browser from
outside means CDP: a debugging port, target discovery, a WebSocket client, and
polling for "has it finished". The page already runs our code, so it can just
POST the result to the server that served it — same origin, no protocol, no
dependencies. This script's whole job is then "open a URL, wait for a file".

THE ONE THING THAT DECIDES WHETHER THE RUN IS WORTH ANYTHING is whether the
browser got a real GPU. Headless Chrome falls back to SwiftShader, a CPU
rasterizer, and a CPU rasterizer's fragment cost has no relation to a GPU's —
which would make every fill number (the entire point of the tool) fiction. So:
  - the default is HEADFUL, parked off-screen, which gets the real GPU;
  - the harness reports its adapter string and this script re-checks it, because
    what matters is what the browser GRANTED, not what we ASKED for.
--headless is offered for the script census, and says so.
"""

import argparse
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS = os.path.join(ROOT, "docs")

BROWSERS = {
    "chrome": [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ],
    "edge": [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    ],
}

_report = {"payload": None}


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves docs/, and collects the one POST the page makes when it finishes."""

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=DOCS, **kw)

    def do_POST(self):
        if self.path != "/__profile":
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace")
        try:
            _report["payload"] = json.loads(body)
        except json.JSONDecodeError:
            _report["payload"] = {"text": body}
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass  # the asset requests are noise; the report is the output


def find_browser(name):
    for p in BROWSERS[name]:
        if os.path.exists(p):
            return p
    return None


def browser_argv(exe, url, headless, width, height):
    argv = [
        exe,
        f"--user-data-dir={tempfile.mkdtemp(prefix='paramo-profile-')}",
        # A throwaway profile is not just hygiene: it guarantees no service
        # worker from a previous export is registered, which is the documented
        # way this project's web build serves stale bytes after a re-export.
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-search-engine-choice-screen",
        # Keep the tab at full speed while it is not the foreground window.
        "--disable-background-timer-throttling",
        "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows",
        # WINDOWS-SPECIFIC AND LOAD-BEARING for the off-screen trick: without it
        # Chrome's native occlusion detection decides a window it cannot see is
        # hidden and STOPS DRIVING requestAnimationFrame — the harness would sit
        # at frame 1 forever and the run would time out with no report.
        "--disable-features=CalculateNativeWinOcclusion",
        # Unpin the frame rate. The browser normally paces rAF to the display,
        # which is the vsync floor the harness has to fight with ballast; with
        # these the GPU is allowed to run flat out and fill costs show up
        # directly. NOTE this makes the run UNREPRESENTATIVE of a player's
        # frame pacing — it prices the work, it does not tell you the fps
        # someone will see.
        "--disable-gpu-vsync",
        "--disable-frame-rate-limit",
        f"--window-size={width},{height}",
    ]
    if headless:
        # `=new` is the modern headless mode; it CAN reach the real GPU on some
        # machines. Whether it did is checked after the fact from the adapter
        # string, never assumed from this flag.
        argv += ["--headless=new", "--use-angle=default"]
    else:
        # Off-screen rather than hidden: a real window, on a real compositor,
        # with a real GPU context — just not on top of whatever you are doing.
        argv += ["--window-position=-32000,-32000"]
    argv.append(url)
    return argv


def kill_tree(proc):
    """Chrome spawns a process tree; terminating the launcher orphans the rest."""
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            capture_output=True,
        )
    else:
        proc.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", choices=sorted(BROWSERS), default="chrome")
    ap.add_argument("--headless", action="store_true",
                    help="script census only — fill numbers will be invalid")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--fires", type=int, default=40)
    ap.add_argument("--visitors", type=int, default=8)
    ap.add_argument("--width", type=int, default=1440)
    ap.add_argument("--height", type=int, default=810)
    ap.add_argument("--keep-open", action="store_true")
    ap.add_argument("--extra", default="",
                    help='extra URL query, e.g. "seed=26&ysort=0". Pin the seed '
                         'for ANY comparison across two runs: the map is '
                         'procedural and regenerates per launch.')
    ap.add_argument("--out", default="", help="also write the report here")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(DOCS, "index.pck")):
        print("no docs/index.pck — export first:", file=sys.stderr)
        print('  godot --path . --headless --export-release "Web"', file=sys.stderr)
        return 1

    exe = find_browser(args.browser)
    if exe is None:
        print(f"{args.browser} not found in any known location", file=sys.stderr)
        return 1

    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    url = (f"http://localhost:{args.port}/?profile"
           f"&fires={args.fires}&visitors={args.visitors}")
    if args.extra:
        url += "&" + args.extra.lstrip("&")
    argv = browser_argv(exe, url, args.headless, args.width, args.height)
    print(f"[run_web_profile] {args.browser} "
          f"{'headless' if args.headless else 'headful (off-screen)'} -> {url}")

    # Popen and do NOT wait: a Windows GUI executable does not hand this shell
    # back if you read its output (chrome --version hung a terminal for two
    # minutes proving it).
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    deadline = time.time() + args.timeout
    profile_dir = next((a.split("=", 1)[1] for a in argv
                        if a.startswith("--user-data-dir=")), None)
    try:
        while time.time() < deadline and _report["payload"] is None:
            if proc.poll() is not None and _report["payload"] is None:
                # Chrome commonly relaunches itself and the launcher exits; only
                # treat that as fatal once nothing has arrived for a while.
                time.sleep(2.0)
                if _report["payload"] is None and time.time() > deadline - 1:
                    break
            time.sleep(0.5)
    finally:
        if not args.keep_open:
            kill_tree(proc)
        httpd.shutdown()

    payload = _report["payload"]
    if payload is None:
        print(f"\nNO REPORT after {args.timeout:.0f}s.", file=sys.stderr)
        print("Likely causes, in order: the build never finished loading; the "
              "map never settled; the page threw. Re-run with --keep-open and "
              "look at the tab's console.", file=sys.stderr)
        return 1

    text = payload.get("text", "")
    print()
    print(text)

    if payload.get("software_rasterizer"):
        print("\n[run_web_profile] SOFTWARE RASTERIZER "
              f"({payload.get('adapter')}). The fill tables above are INVALID; "
              "only the script census is usable. Re-run headful.", file=sys.stderr)
    else:
        print(f"\n[run_web_profile] GPU: {payload.get('adapter')}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        with open(os.path.splitext(args.out)[0] + ".json", "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        print(f"[run_web_profile] wrote {args.out}")

    if profile_dir and not args.keep_open:
        shutil.rmtree(profile_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
