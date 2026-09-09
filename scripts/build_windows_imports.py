#!/usr/bin/env python3
"""Build Windows DLL import libraries independently of the Signals host."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import dependency_archive
import windows_imports
from dependency_archive import digest, write_archive

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "dependencies/windows-imports.json"


def build(output):
    recipe_bytes = RECIPE.read_bytes()
    recipe = json.loads(recipe_bytes)
    version = subprocess.check_output(["zig", "version"], text=True).strip()
    if version != recipe["zig_version"]:
        raise ValueError("Windows import producer requires the recipe's exact Zig version")
    source = windows_imports.zig_lib_dir() / "libc/mingw"
    for name, expected in recipe["source_files_sha256"].items():
        if digest((source / name).read_bytes()) != expected:
            raise ValueError(f"MinGW source differs from its reviewed pin: {name}")
    with tempfile.TemporaryDirectory(prefix="signals-windows-imports-") as temporary:
        stage = Path(temporary)
        for name in recipe["libraries"]:
            windows_imports.windows_import_library(name, stage)
        files = {f"targets/x64win/{name}.lib": (stage / f"{name}.lib").read_bytes()
                 for name in recipe["libraries"]}
        files["licenses/windows-imports/COPYING"] = (source / "COPYING").read_bytes()
        metadata = {
            "schema_version": 1, "name": recipe["name"], "version": recipe["version"],
            "target": recipe["target"],
            "source": {"distribution": "Zig", "version": version,
                       "files_sha256": recipe["source_files_sha256"]},
            "build": {"zig_version": version, "recipe_sha256": digest(recipe_bytes),
                      "producer_sha256": digest(Path(__file__).read_bytes()),
                      "generator_sha256": digest(Path(windows_imports.__file__).read_bytes()),
                      "archive_writer_sha256": digest(Path(dependency_archive.__file__).read_bytes())},
        }
        archive = write_archive(output / "windows-imports-x64win.tar", metadata, files)
    print(f"{digest(archive.read_bytes())}  {archive.name}")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    build(parser.parse_args().output.resolve())
