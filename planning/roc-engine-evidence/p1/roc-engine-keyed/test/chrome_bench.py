#!/usr/bin/env python3
"""Drive the paired in-browser bench (chrome.html) in headless Chrome.

Serves the repository root plus the two Wasm artifacts on 127.0.0.1, starts
Chrome headless on the page, waits for the page to POST its results, then
stops Chrome and writes the JSON. No browser-automation package is needed.

usage: chrome_bench.py --current A.wasm --new B.wasm --out results.json
         [--chrome /usr/bin/google-chrome] [--iterations N] [--warmups N] [--cases a,b]
"""

from __future__ import annotations

import argparse
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[4]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", required=True, type=Path)
    parser.add_argument("--new", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--chrome", default="/usr/bin/google-chrome")
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--cases", default="")
    parser.add_argument("--timeout", type=float, default=1800)
    args = parser.parse_args()

    wasm = {"/wasm/current.wasm": args.current.resolve(), "/wasm/new.wasm": args.new.resolve()}
    done = threading.Event()
    result: dict[str, bytes] = {}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=str(ROOT), **k)

        def log_message(self, *_):
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in wasm:
                data = wasm[path].read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/wasm")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            super().do_GET()

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            result["body"] = self.rfile.read(length)
            self.send_response(204)
            self.end_headers()
            done.set()

    Handler.extensions_map[".mjs"] = "text/javascript"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    query = f"iterations={args.iterations}&warmups={args.warmups}"
    if args.cases:
        query += f"&cases={args.cases}"
    url = f"http://127.0.0.1:{port}/benchmarks/js-framework-benchmark/roc-engine-keyed/test/chrome.html?{query}"
    profile = tempfile.mkdtemp(prefix="roc-engine-chrome-")
    chrome = subprocess.Popen(
        [args.chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
         "--disable-extensions", "--disable-background-timer-throttling",
         "--disable-renderer-backgrounding", "--js-flags=--expose-gc",
         f"--user-data-dir={profile}", "--window-size=1200,900", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not done.wait(args.timeout):
            raise SystemExit("timed out waiting for the page to post results")
    finally:
        chrome.terminate()
        try:
            chrome.wait(10)
        except subprocess.TimeoutExpired:
            chrome.kill()
        server.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
    data = json.loads(result["body"])
    if "error" in data:
        raise SystemExit(f"page failed: {data['error']}")
    args.out.write_text(json.dumps(data, indent=1))
    version = subprocess.run([args.chrome, "--version"], capture_output=True, text=True).stdout.strip()
    print(version)
    print(data.get("userAgent", ""))
    for case, samples in data["cases"].items():
        line = [case.ljust(17)]
        for engine in ("current", "new"):
            for field in ("script_ms", "layout_ms", "wasm_ms") + (("decode_ms",) if engine == "new" else ()):
                values = sorted(s[field] for s in samples[engine])
                mid = len(values) // 2
                median = values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2
                line.append(f"{engine}.{field.split('_')[0]} {median:.2f} [{values[0]:.2f}-{values[-1]:.2f}]")
        print("  ".join(line))


if __name__ == "__main__":
    main()
