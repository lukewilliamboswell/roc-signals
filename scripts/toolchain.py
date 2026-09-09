#!/usr/bin/env python3
"""Read the selected header pins and check the installed compiler identity."""

import argparse
import json
from pathlib import Path
import re
import subprocess

from compiler_pins import TOKEN, discover, local_sources, read_pin, version

ROOT = Path(__file__).resolve().parents[1]


def app_platform_span(source: str):
    """Locate the app header's platform literal, excluding comments and bodies."""
    tokens = iter(token for token in TOKEN.finditer(source) if not token.group().startswith("#"))
    first = next(tokens, None)
    if first is None or first.group() != "app":
        return None
    stack = []
    record = False
    found = []
    previous = None
    for token in tokens:
        value = token.group()
        if not stack and value == "{":
            record = True
        if record and len(stack) == 1 and previous == ":" and value == "platform":
            literal = next(tokens, None)
            if literal is None or not re.fullmatch(r'"[^"\\\n]+"', literal.group()):
                raise ValueError("platform dependency must be one unescaped literal")
            found.append((literal.start() + 1, literal.end() - 1))
            previous = literal.group()
            continue
        if value in {"[", "{", "("}:
            stack.append({"[": "]", "{": "}", "(": ")"}[value])
        elif value in {"]", "}", ")"}:
            if not stack or stack.pop() != value:
                raise ValueError("malformed app header")
            if record and not stack:
                if len(found) != 1:
                    raise ValueError("app header must contain exactly one platform")
                return found[0]
        previous = value
    raise ValueError("incomplete app header")


def replace_platform(source: str, reference: str) -> str:
    span = app_platform_span(source)
    if span is None:
        return source
    if any(character in reference for character in '\\"\n\r'):
        raise ValueError("platform reference cannot contain escapes or newlines")
    start, end = span
    return source[:start] + reference + source[end:]


def development_pin(root: Path = ROOT) -> str:
    return read_pin(root / "platform-web/main.roc")


def validate_roots(root: Path = ROOT) -> str:
    config = json.loads((root / ".github/roc-nightly.json").read_text())
    expected = {"platform-web/main.roc", "platform-gui/main.roc"}
    for directory in ("examples-web", "examples-gui"):
        expected.update(path.relative_to(root).as_posix()
                        for path in (root / directory).rglob("main.roc"))
    if set(config["compiler_roots"]) != expected:
        raise ValueError("compiler_roots must select both platforms and every web and GUI example")
    if (root / ".roc-version").exists():
        raise ValueError("remove competing .roc-version authority")
    return version(discover(local_sources(root, config["compiler_roots"])))


def verify_compiler(roc: str, pin: str) -> None:
    actual = subprocess.check_output([roc, "version"], text=True).strip()
    # Official nightly binaries report their source commit, not the tag date.
    commit = pin.rsplit("-", 1)[-1] if pin.startswith("nightly-") else None
    if pin not in actual and not (commit and re.search(r"(?<![0-9a-f])" + re.escape(commit) + r"[0-9a-f]*(?![0-9a-f])", actual)):
        raise ValueError(f"compiler does not match {pin}: {actual}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--roc-bin")
    args = parser.parse_args()
    pin = validate_roots() if args.check else development_pin()
    if args.roc_bin:
        verify_compiler(args.roc_bin, pin)
    print(pin)
