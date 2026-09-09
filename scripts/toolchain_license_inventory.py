"""Collect runtime notice evidence from pinned Rust and Zig distributions.

This preserves upstream notices and Zig source comments. It does not infer which
runtime components a host links, or replace review of its binary dependency set.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile


def distribution_notices(archive, recipe):
    """Verify the distribution before reading its exact required notice files."""
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("missing or symlinked toolchain archive")
    size = archive.stat().st_size
    if size > 512 * 1024 * 1024 or ("size" in recipe and size != recipe["size"]):
        raise ValueError("toolchain archive size differs from recipe or exceeds limit")
    with archive.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != recipe["sha256"]:
            raise ValueError("toolchain archive differs from its pinned hash")
        source.seek(0)
        wanted = {}
        for name in recipe["notices"]:
            path = PurePosixPath(name)
            if (path.is_absolute() or ".." in path.parts or str(path) != name
                    or "\\" in name or not path.parts or name in wanted):
                raise ValueError("unsafe or duplicate toolchain notice path")
            wanted[name] = None
        if not wanted:
            raise ValueError("toolchain recipe selects no notices")
        with tarfile.open(fileobj=source, mode="r:xz") as packed:
            total = 0
            for index, member in enumerate(packed):
                if index >= 100000:
                    raise ValueError("toolchain archive exceeds member limit")
                prefix = recipe["prefix"] + "/"
                if not member.name.startswith(prefix):
                    continue
                name = member.name[len(prefix):]
                if name not in wanted:
                    continue
                if not member.isfile() or wanted[name] is not None:
                    raise ValueError("toolchain notice must be a unique regular file")
                total += member.size
                if member.size <= 0 or total > 16 * 1024 * 1024:
                    raise ValueError("toolchain notices exceed size limit or are empty")
                wanted[name] = packed.extractfile(member).read()
        if any(data is None for data in wanted.values()):
            raise ValueError("toolchain distribution is missing a required notice")
    return wanted


def collect(recipe_path, target, rust_archive, zig_archive, destination):
    """Write a hash-indexed review inventory only after both inputs verify."""
    if destination.exists():
        raise FileExistsError(destination)
    recipe_bytes = recipe_path.read_bytes()
    recipe = json.loads(recipe_bytes)
    if recipe["schema_version"] != 1:
        raise ValueError("unsupported toolchain notice recipe")
    if any(not re.fullmatch(r"[A-Za-z0-9_.+-]+", recipe[name]["version"])
           for name in ("rust", "zig")):
        raise ValueError("unsafe toolchain version")
    selected = {"rust": recipe["rust"]["targets"][target], "zig": recipe["zig"]}
    notices = {"rust": distribution_notices(rust_archive, selected["rust"]),
               "zig": distribution_notices(zig_archive, selected["zig"])}
    # Original Zig sources preserve notices embedded in standard-library and
    # compiler-runtime files, including components not covered by its root MIT
    # license. A source archive is not a claim that every component was linked.
    zig_sources = zig_archive.read_bytes()
    if hashlib.sha256(zig_sources).hexdigest() != selected["zig"]["sha256"]:
        raise ValueError("Zig source archive changed during collection")
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = {"schema_version": 1, "target": target,
              "recipe_sha256": hashlib.sha256(recipe_bytes).hexdigest(),
              "toolchains": {}, "files": {}}
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".toolchain-notices-") as temporary:
        stage = Path(temporary) / "inventory"
        stage.mkdir()
        for name, files in notices.items():
            result["toolchains"][name] = {"version": recipe[name]["version"],
                                           "archive_sha256": selected[name]["sha256"],
                                           "source_url": selected[name]["source_url"]}
            for path, data in files.items():
                relative = f"notices/{name}/{path}"
                output = stage / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(data)
                result["files"][relative] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        relative = "sources/zig-" + recipe["zig"]["version"] + ".tar.xz"
        (stage / relative).parent.mkdir()
        (stage / relative).write_bytes(zig_sources)
        result["files"][relative] = {"sha256": selected["zig"]["sha256"], "size": len(zig_sources)}
        (stage / "inventory.json").write_text(json.dumps(result, indent=2) + "\n")
        stage.rename(destination)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe", type=Path, default=Path(__file__).resolve().parents[1] /
                        "dependencies/gui-host-notices/toolchains.json")
    parser.add_argument("--target", choices=("x64glibc", "arm64mac", "x64win"), required=True)
    parser.add_argument("--rust-archive", type=Path, required=True)
    parser.add_argument("--zig-source-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    collect(args.recipe, args.target, args.rust_archive, args.zig_source_archive, args.output)
