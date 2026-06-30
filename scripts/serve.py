#!/usr/bin/env python3
"""Build and serve the Roc Signals static site."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
from pathlib import Path
import re
import shutil
import socket
import socketserver
import subprocess
import threading
import tomllib


ROOT = Path(__file__).resolve().parent.parent
WWW = ROOT / "www"
DIST = ROOT / "dist"
SITE_OUT = ROOT / ".site-out"
EXAMPLES_MANIFEST = WWW / "data" / "examples.toml"
TAILWIND_INPUT = WWW / "input.css"
TAILWIND_OUTPUT = WWW / "static" / "signals.css"
TAILWIND_CONFIG = ROOT / "tailwind.config.js"
PLATFORM_HEADER_RE = re.compile(r'platform\s+"[^"]+"')


def load_examples() -> list[dict[str, object]]:
    with EXAMPLES_MANIFEST.open("rb") as f:
        manifest = tomllib.load(f)
    examples = list(manifest.get("examples", []))
    if not examples:
        raise SystemExit(f"no examples found in {EXAMPLES_MANIFEST}")
    return examples


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--example",
        help="Build one public browser example by slug. Defaults to every public wasm example.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("PORT", "0")),
        help="Static file server port. Defaults to PORT or a random available port.",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("HOST", "localhost"),
        help="Static file server host. Defaults to HOST or localhost.",
    )
    parser.add_argument(
        "--app-opt",
        choices=("dev", "size"),
        default=os.environ.get("APP_OPT", "size"),
        help="Roc --opt mode for example wasm builds. Defaults to APP_OPT or size.",
    )
    parser.add_argument(
        "--host-opt",
        choices=("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"),
        default="ReleaseSmall",
        help="Zig optimize mode for platform host artifacts. Defaults to ReleaseSmall.",
    )
    parser.add_argument(
        "--roc-bin",
        default=os.environ.get("ROC_BIN") or os.environ.get("ROC") or "roc",
        help="Roc compiler path. Defaults to ROC_BIN, ROC, or roc from PATH.",
    )
    parser.add_argument(
        "--zola-bin",
        default=os.environ.get("ZOLA_BIN", "zola"),
        help="Zola CLI path. Defaults to ZOLA_BIN or zola from PATH.",
    )
    parser.add_argument(
        "--tailwind-bin",
        default=os.environ.get("TAILWIND_BIN", "tailwindcss"),
        help="Tailwind CSS standalone CLI path. Defaults to TAILWIND_BIN or tailwindcss.",
    )
    parser.add_argument(
        "--platform-url",
        default=os.environ.get("SIGNALS_PLATFORM_URL"),
        help="Release platform URL written into published example source files.",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SITE_BASE_URL"),
        help="Override Zola base_url for this build.",
    )
    parser.add_argument(
        "--skip-tailwind",
        action="store_true",
        default=os.environ.get("SKIP_TAILWIND") == "1",
        help="Skip generating www/static/signals.css.",
    )
    parser.add_argument(
        "--no-server",
        action="store_true",
        default=os.environ.get("NO_SERVER") == "1",
        help="Build dist/ only; do not start the static file server.",
    )
    return parser.parse_args()


def repo_path(value: str | Path) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return ROOT / path


def resolve_command(value: str, label: str) -> str:
    path = Path(value)
    if len(path.parts) == 1:
        found = shutil.which(value)
        if found is not None:
            return found
        raise SystemExit(f"missing {label}: {value}")

    resolved = repo_path(path)
    if resolved.exists() and os.access(resolved, os.X_OK):
        return str(resolved)
    raise SystemExit(f"missing {label}: {value}")


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def run(command: list[str | Path], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"\n==> {printable}", flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, env=env, check=True)


def clean_site_output() -> None:
    if SITE_OUT.exists():
        shutil.rmtree(SITE_OUT)
    SITE_OUT.mkdir()


def config_base_url() -> str:
    config = site_config()
    return str(config.get("base_url", "")).rstrip("/")


def config_release_platform_url() -> str | None:
    extra = site_config().get("extra", {})
    if not isinstance(extra, dict):
        return None

    value = extra.get("release_platform_url")
    if value is None:
        return None

    platform_url = str(value).strip()
    return platform_url or None


def site_config() -> dict[str, object]:
    with (WWW / "config.toml").open("rb") as f:
        return tomllib.load(f)


def build_hosts(host_opt: str) -> None:
    run(["zig", "build", "build-test-hosts", f"-Doptimize={host_opt}"])


def build_css(tailwind_bin: str, *, skip: bool) -> None:
    if skip:
        if not TAILWIND_OUTPUT.exists():
            print(f"Skipping Tailwind; {display_path(TAILWIND_OUTPUT)} does not exist.")
        else:
            ensure_trailing_newline(TAILWIND_OUTPUT)
        return

    run(
        [
            tailwind_bin,
            "-c",
            TAILWIND_CONFIG,
            "-i",
            TAILWIND_INPUT,
            "-o",
            TAILWIND_OUTPUT,
            "--minify",
        ]
    )
    ensure_trailing_newline(TAILWIND_OUTPUT)


def ensure_trailing_newline(path: Path) -> None:
    if not path.exists() or path.stat().st_size == 0:
        return
    with path.open("rb+") as f:
        f.seek(-1, os.SEEK_END)
        if f.read(1) != b"\n":
            f.write(b"\n")


def build_zola_site(zola_bin: str, *, base_url: str | None) -> None:
    command: list[str | Path] = [
        zola_bin,
        "--root",
        WWW,
        "build",
        "--output-dir",
        DIST,
        "--force",
    ]
    if base_url:
        command.extend(["--base-url", base_url])
    run(command)


def bundle_platform(roc_bin: str, out_dir: Path) -> Path:
    env = os.environ.copy()
    env["ROC_BIN"] = roc_bin
    env["BUNDLE_OUT_DIR"] = str(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [str(ROOT / "scripts" / "bundle.sh")],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=True,
    )
    print(result.stdout, end="")
    for line in result.stdout.splitlines():
        if line.startswith("Created:"):
            return Path(line.split(":", 1)[1].strip())
    raise SystemExit("scripts/bundle.sh did not print a Created: line")


class ReusableTcpServer(socketserver.TCPServer):
    allow_reuse_address = True


class StaticSiteHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.end_headers()


class DirectoryServer:
    def __init__(self, directory: Path, port: int = 0):
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
        self.httpd = ReusableTcpServer(("127.0.0.1", port), handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return int(self.httpd.server_address[1])

    def __enter__(self) -> "DirectoryServer":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


class PortReservation:
    def __init__(self, host: str, requested_port: int):
        self.socket: socket.socket | None = None
        if requested_port != 0:
            self.port = requested_port
            return

        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self.socket = socket.socket(family, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((host, 0))
        self.port = int(self.socket.getsockname()[1])

    def close(self) -> None:
        if self.socket is not None:
            self.socket.close()
            self.socket = None


def rewrite_platform_headers(root: Path, platform_ref: str) -> None:
    replacement = f'platform "{platform_ref}"'
    for source in sorted(root.rglob("*.roc")):
        text = source.read_text(encoding="utf-8")
        updated, count = PLATFORM_HEADER_RE.subn(replacement, text, count=1)
        if count != 0:
            source.write_text(updated, encoding="utf-8")


def copy_example_dir(source_dir: Path, dest_dir: Path, *, platform_ref: str) -> None:
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    shutil.copytree(source_dir, dest_dir)
    rewrite_platform_headers(dest_dir, platform_ref)


def public_wasm_examples(examples: list[dict[str, object]], selected_slug: str | None) -> list[dict[str, object]]:
    selected = [
        example
        for example in examples
        if bool(example.get("public", True)) and bool(example.get("wasm", True))
    ]
    if selected_slug is None:
        return selected

    matches = [example for example in selected if example.get("slug") == selected_slug]
    if not matches:
        valid = ", ".join(str(example.get("slug")) for example in selected)
        raise SystemExit(f"unknown public wasm example '{selected_slug}'. Valid examples: {valid}")
    return matches


def build_example_wasm(
    roc_bin: str,
    example: dict[str, object],
    *,
    build_platform_ref: str,
    publish_platform_ref: str,
    app_opt: str,
) -> None:
    slug = str(example["slug"])
    source = Path(str(example["source"]))
    source_dir = ROOT / source.parent
    build_dir = SITE_OUT / "examples" / slug
    publish_dir = DIST / "examples" / slug / "source"
    wasm_path = DIST / "examples" / slug / "app.wasm"

    copy_example_dir(source_dir, build_dir, platform_ref=build_platform_ref)
    copy_example_dir(source_dir, publish_dir, platform_ref=publish_platform_ref)
    wasm_path.parent.mkdir(parents=True, exist_ok=True)

    run(
        [
            roc_bin,
            "build",
            "--target=wasm32",
            f"--opt={app_opt}",
            "--no-cache",
            f"--output={wasm_path}",
            build_dir / source.name,
        ]
    )


def build_examples(
    roc_bin: str,
    examples: list[dict[str, object]],
    *,
    bundle: Path,
    platform_url: str | None,
    app_opt: str,
) -> None:
    release_platform_ref = (
        platform_url
        or config_release_platform_url()
        or f"{config_base_url()}/platform/{bundle.name}"
    )
    with DirectoryServer(bundle.parent) as bundle_server:
        build_platform_ref = f"http://127.0.0.1:{bundle_server.port}/{bundle.name}"
        print(f"\nUsing local platform bundle for wasm builds: {build_platform_ref}")
        print(f"Writing published example headers as: {release_platform_ref}")
        for example in examples:
            build_example_wasm(
                roc_bin,
                example,
                build_platform_ref=build_platform_ref,
                publish_platform_ref=release_platform_ref,
                app_opt=app_opt,
            )


def local_url_host(host: str) -> str:
    if host in {"0.0.0.0", "::"}:
        return "localhost"
    return host


def serve_dist(host: str, port: int) -> None:
    handler = functools.partial(StaticSiteHandler, directory=DIST)
    with ReusableTcpServer((host, port), handler) as httpd:
        actual_port = int(httpd.server_address[1])
        url = f"http://{local_url_host(host)}:{actual_port}/"
        print(f"\nServing {display_path(DIST)}", flush=True)
        print(f"Open: {url}", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


def main() -> int:
    args = parse_args()
    examples = public_wasm_examples(load_examples(), args.example)
    roc_bin = resolve_command(args.roc_bin, "Roc compiler")
    zola_bin = resolve_command(args.zola_bin, "Zola CLI")
    tailwind_bin = args.tailwind_bin if args.skip_tailwind else resolve_command(args.tailwind_bin, "Tailwind CSS CLI")
    port_reservation = None if args.no_server else PortReservation(args.host, args.port)
    server_port = args.port if args.no_server else port_reservation.port
    zola_base_url = args.base_url
    if zola_base_url is None and not args.no_server:
        zola_base_url = f"http://{local_url_host(args.host)}:{server_port}"

    try:
        clean_site_output()
        build_hosts(args.host_opt)
        build_css(tailwind_bin, skip=args.skip_tailwind)
        build_zola_site(zola_bin, base_url=zola_base_url)
        bundle = bundle_platform(roc_bin, DIST / "platform")
        build_examples(
            roc_bin,
            examples,
            bundle=bundle,
            platform_url=args.platform_url,
            app_opt=args.app_opt,
        )

        print(f"\nBuilt {display_path(DIST)}", flush=True)
        if not args.no_server:
            assert port_reservation is not None
            port_reservation.close()
            serve_dist(args.host, server_port)
    finally:
        if port_reservation is not None:
            port_reservation.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
