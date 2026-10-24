#!/usr/bin/env python3
"""Generate the committed scalar field tables from one manifest.

`protocol/native-protocol.json` is the single authority for the scalar text and
boolean field tables: each field's descriptor id, its name in the engine, and
the browser opcode that sets it, plus the ids reserved for named custom
attributes. This script renders that manifest into
`src/signals/native_protocol_gen.zig`, which the descriptor stream, render
cache, and browser command encoder all read.

The generated artifact is committed; regeneration is idempotent. `--check`
regenerates in memory and fails when the artifact is stale.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "protocol" / "native-protocol.json"
ZIG_OUT = ROOT / "src" / "signals" / "native_protocol_gen.zig"

SCHEMA_VERSION = 2
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
FIELD_KEYS = {"id", "name", "browser_op", "doc"}


def load_manifest(path: Path = MANIFEST) -> dict:
    with path.open("rb") as f:
        manifest = json.load(f)
    validate(manifest)
    return manifest


def validate(manifest: dict) -> None:
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise SystemExit("unsupported protocol manifest schema")
    for table, custom_key in (("text_fields", "custom_text_field_id"), ("bool_fields", "custom_bool_field_id")):
        reserved = manifest.get(custom_key)
        if not isinstance(reserved, int) or reserved < 0:
            raise SystemExit(f"protocol manifest {custom_key} must be a non-negative integer")
        fields = manifest.get(table)
        if not fields:
            raise SystemExit(f"protocol manifest is missing {table}")
        validate_fields(table, fields, reserved_id=reserved)


def validate_fields(table: str, fields: list[dict], *, reserved_id: int) -> None:
    ids: set[int] = set()
    names: set[str] = set()
    ops: set[str] = set()
    for field in fields:
        name = field.get("name", "")
        if not NAME_RE.fullmatch(name):
            raise SystemExit(f"invalid {table} name: {name!r}")
        if name in names:
            raise SystemExit(f"duplicate {table} name: {name!r}")
        names.add(name)
        unknown = set(field) - FIELD_KEYS
        if unknown:
            raise SystemExit(f"{table} entry {name!r} has unknown keys: {sorted(unknown)}")
        ident = field.get("id")
        if not isinstance(ident, int) or isinstance(ident, bool) or ident < 0:
            raise SystemExit(f"invalid {table} id for {name!r}")
        if ident in ids:
            raise SystemExit(f"duplicate {table} id: {ident}")
        ids.add(ident)
        if ident == reserved_id:
            raise SystemExit(f"{table} id {ident} is reserved for custom attribute markers")
        op = field.get("browser_op", "")
        if not NAME_RE.fullmatch(op):
            raise SystemExit(f"{table} entry {name!r} must name its browser_op")
        if op in ops:
            raise SystemExit(f"duplicate {table} browser_op: {op!r}")
        ops.add(op)
        if not field.get("doc"):
            raise SystemExit(f"{table} entry {name!r} is missing a doc line")


def render_zig(manifest: dict) -> str:
    lines: list[str] = []
    out = lines.append
    out("//! Scalar field tables generated from protocol/native-protocol.json.")
    out("//!")
    out("//! GENERATED FILE - do not edit by hand. Update the manifest and run")
    out("//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies")
    out("//! that this committed artifact matches the manifest.")
    out("")
    out("/// Field id reserved for named custom text attributes; never a typed slot.")
    out(f"pub const custom_text_field_id: u64 = {manifest['custom_text_field_id']};")
    out("")
    out("/// Field id reserved for named custom boolean attributes; never a typed slot.")
    out(f"pub const custom_bool_field_id: u64 = {manifest['custom_bool_field_id']};")
    out("")
    for enum_name, table in (("TextField", "text_fields"), ("BoolField", "bool_fields")):
        fields = manifest[table]
        kind = "text" if enum_name == "TextField" else "boolean"
        out(f"/// Scalar {kind} fields carried by the shared descriptor machinery.")
        out(f"pub const {enum_name} = enum(u64) {{")
        for field in fields:
            out(f"    /// {field['doc']}")
            out(f"    {field['name']} = {field['id']},")
        out("")
        out("    /// Returns the name of the browser opcode that sets this field.")
        out(f"    pub fn browserOpName(self: {enum_name}) []const u8 {{")
        out("        return switch (self) {")
        for field in fields:
            out(f"            .{field['name']} => \"{field['browser_op']}\",")
        out("        };")
        out("    }")
        out("};")
        out("")
    out("/// Total declared scalar text fields.")
    out(f"pub const text_field_count: usize = {len(manifest['text_fields'])};")
    out("")
    out("/// Total declared scalar boolean fields.")
    out(f"pub const bool_field_count: usize = {len(manifest['bool_fields'])};")
    return "\n".join(lines) + "\n"


def render_all(manifest: dict) -> dict[Path, str]:
    return {ZIG_OUT: render_zig(manifest)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail when the committed artifact differs from the manifest rendering.")
    args = parser.parse_args()
    artifacts = render_all(load_manifest())
    stale = []
    for path, content in artifacts.items():
        current = path.read_text() if path.exists() else None
        if current == content:
            continue
        if args.check:
            stale.append(path)
        else:
            path.write_text(content)
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        names = ", ".join(str(path.relative_to(ROOT)) for path in stale)
        print(f"stale generated protocol artifacts: {names}", file=sys.stderr)
        print("run `python3 scripts/generate_protocol.py` and commit the result", file=sys.stderr)
        return 1
    if args.check:
        print("generated protocol artifacts match protocol/native-protocol.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
