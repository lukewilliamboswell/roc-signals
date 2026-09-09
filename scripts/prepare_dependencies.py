#!/usr/bin/env python3
"""Install verified, locked link inputs for local Roc application builds.

Platform bundling uses its own fresh verified staging tree. It never trusts these
mutable development copies as evidence of a dependency's origin.
"""

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import shutil
import tempfile

from dependency_artifacts import materialize

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "dependencies.lock.json"
CACHE = Path.home() / ".cache/roc-signals/dependencies"
WEB_ARTIFACTS = ("musl-x64musl", "musl-arm64musl")
WINDOWS_IMPORTS = "windows-imports-x64win"
FREETYPE = "freetype-x64glibc"
XKBCOMMON = "xkbcommon-x64glibc"
XKBCOMMON_LIBRARIES = ("libxkbcommon.so", "libxkbcommon-x11.so")


@contextmanager
def verified_xkbcommon(lock=LOCK, cache=CACHE):
    """Admit both keyboard libraries and their upstream redistribution notice."""
    with tempfile.TemporaryDirectory(prefix="signals-verified-xkbcommon-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock, (XKBCOMMON,), cache, destination)
        manifest = json.loads((destination / XKBCOMMON / "dependency.json").read_text())
        expected = {"targets/x64glibc/" + name for name in XKBCOMMON_LIBRARIES}
        expected.add("licenses/xkbcommon/LICENSE")
        if set(manifest["files"]) != expected:
            raise ValueError("incomplete or unexpected xkbcommon inputs")
        yield destination


def install_xkbcommon(destination, lock=LOCK, cache=CACHE):
    """Verify the release and stage both development inputs before replacement."""
    with verified_xkbcommon(lock, cache) as inputs:
        source = inputs / XKBCOMMON / "targets/x64glibc"
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination, prefix=".xkbcommon-") as temporary:
            staged = Path(temporary)
            for name in XKBCOMMON_LIBRARIES:
                shutil.copyfile(source / name, staged / name)
            for name in XKBCOMMON_LIBRARIES:
                (staged / name).replace(destination / name)
        return json.loads((inputs / "dependencies.lock.json").read_text())


@contextmanager
def verified_freetype(lock=LOCK, cache=CACHE):
    """Admit only the complete FreeType library and license inventory."""
    with tempfile.TemporaryDirectory(prefix="signals-verified-freetype-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock, (FREETYPE,), cache, destination)
        manifest = json.loads((destination / FREETYPE / "dependency.json").read_text())
        expected = {"targets/x64glibc/libfreetype.so"}
        expected.update("licenses/freetype/" + name for name in
                        ("LICENSE.TXT", "FTL.TXT", "GPLv2.TXT", "NOTICE"))
        if set(manifest["files"]) != expected:
            raise ValueError("incomplete or unexpected FreeType inputs")
        yield destination


def install_freetype(destination, lock=LOCK, cache=CACHE):
    """Replace the development link input only after release verification."""
    with verified_freetype(lock, cache) as inputs:
        source = inputs / FREETYPE / "targets/x64glibc/libfreetype.so"
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as pending:
            path = Path(pending.name)
        try:
            shutil.copyfile(source, path)
            path.replace(destination / "libfreetype.so")
        finally:
            path.unlink(missing_ok=True)
        return json.loads((inputs / "dependencies.lock.json").read_text())


@contextmanager
def verified_windows_imports(lock=LOCK, cache=CACHE):
    with tempfile.TemporaryDirectory(prefix="signals-verified-imports-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock, (WINDOWS_IMPORTS,), cache, destination)
        manifest = json.loads((destination / WINDOWS_IMPORTS / "dependency.json").read_text())
        if set(manifest["files"]) != {"targets/x64win/advapi32.lib", "licenses/windows-imports/COPYING"}:
            raise ValueError("incomplete or unexpected Windows import inputs")
        yield destination


def install_windows_imports(destination, lock=LOCK, cache=CACHE):
    with verified_windows_imports(lock, cache) as inputs:
        source = inputs / WINDOWS_IMPORTS / "targets/x64win/advapi32.lib"
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as pending:
            path = Path(pending.name)
        try:
            shutil.copyfile(source, path)
            path.replace(destination / "advapi32.lib")
        finally:
            path.unlink(missing_ok=True)
        return json.loads((inputs / "dependencies.lock.json").read_text())


@contextmanager
def verified_web_dependencies(lock=LOCK, cache=CACHE):
    with tempfile.TemporaryDirectory(prefix="signals-verified-dependencies-") as temporary:
        destination = Path(temporary) / "inputs"
        materialize(lock, WEB_ARTIFACTS, cache, destination)
        for target in ("x64musl", "arm64musl"):
            tree = destination / f"musl-{target}" / "targets" / target
            if {path.name for path in tree.iterdir()} != {"libc.a", "crt1.o"}:
                raise ValueError(f"incomplete or unexpected musl link inputs for {target}")
        yield destination


def install_web_dependencies(lock=LOCK, cache=CACHE, platform=ROOT / "platform-web"):
    with verified_web_dependencies(lock, cache) as inputs:
        for identity in WEB_ARTIFACTS:
            for source in (inputs / identity / "targets").rglob("*"):
                if not source.is_file():
                    continue
                destination = platform / "targets" / source.relative_to(inputs / identity / "targets")
                destination.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as pending:
                    path = Path(pending.name)
                try:
                    with source.open("rb") as original, path.open("wb") as output:
                        shutil.copyfileobj(original, output)
                    path.replace(destination)
                finally:
                    path.unlink(missing_ok=True)



if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--cache", type=Path, default=CACHE)
    args = parser.parse_args()
    install_web_dependencies(args.lock, args.cache)
