#!/usr/bin/env python3
"""Generate the committed native GUI protocol artifacts from one manifest.

`protocol/native-protocol.json` is the single authority for the native GUI
protocol tables: the protocol version, the scalar text/bool field tables, the
task-kind routes, and the extern node record layout shared by the Zig engine
and the Rust GPUI host. This script renders that manifest into:

- `src/signals/native_protocol_gen.zig` (whole file)
- `crates/gpui-host/src/protocol_gen.rs` (whole file)
- `platform-gui/Elem.roc` (between GENERATED markers)
- `docs/native-gui-protocol.md` (between GENERATED markers)

Generated artifacts are committed; regeneration is idempotent. `--check`
regenerates in memory and fails when any artifact is stale.
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
RUST_OUT = ROOT / "crates" / "gpui-host" / "src" / "protocol_gen.rs"
ROC_OUT = ROOT / "platform-gui" / "Elem.roc"
DOCS_OUT = ROOT / "docs" / "native-gui-protocol.md"

ROC_BEGIN = "# BEGIN GENERATED PROTOCOL (scripts/generate_protocol.py; edit protocol/native-protocol.json)"
ROC_END = "# END GENERATED PROTOCOL"
DOCS_BEGIN = "<!-- BEGIN GENERATED PROTOCOL TABLES (scripts/generate_protocol.py; edit protocol/native-protocol.json) -->"
DOCS_END = "<!-- END GENERATED PROTOCOL TABLES -->"

NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
RAW_NODE_TYPES = {
    "u64": ("u64", "u64"),
    "usize": ("usize", "usize"),
    "slice": ("Slice", "Slice"),
    "style": ("Style", "Style"),
    "viewport": ("Viewport", "[u32; 2]"),
}


def load_manifest(path: Path = MANIFEST) -> dict:
    with path.open("rb") as f:
        manifest = json.load(f)
    validate(manifest)
    return manifest


def validate(manifest: dict) -> None:
    if manifest.get("schema_version") != 1:
        raise SystemExit("unsupported protocol manifest schema")
    for key in ("protocol_version", "timer_version"):
        if not isinstance(manifest.get(key), int) or manifest[key] < 1:
            raise SystemExit(f"protocol manifest {key} must be a positive integer")
    for table, custom_key in (("text_fields", "custom_text_field_id"), ("bool_fields", "custom_bool_field_id")):
        fields = manifest.get(table)
        if not fields:
            raise SystemExit(f"protocol manifest is missing {table}")
        validate_fields(table, fields, reserved_id=manifest.get(custom_key))
    fields = manifest.get("raw_node", {}).get("fields")
    if not fields:
        raise SystemExit("protocol manifest is missing raw_node.fields")
    seen: set[str] = set()
    for field in fields:
        name = field.get("name", "")
        if not NAME_RE.fullmatch(name):
            raise SystemExit(f"invalid raw_node field name: {name!r}")
        if name in seen:
            raise SystemExit(f"duplicate raw_node field name: {name!r}")
        seen.add(name)
        if field.get("type") not in RAW_NODE_TYPES:
            raise SystemExit(f"unknown raw_node field type for {name!r}: {field.get('type')!r}")
        if not field.get("doc"):
            raise SystemExit(f"raw_node field {name!r} is missing a doc line")
    history = manifest.get("version_history", [])
    if not history or history[0]["version"] != manifest["protocol_version"]:
        raise SystemExit("version_history must start with the current protocol version")
    versions = [entry["version"] for entry in history]
    if versions != sorted(versions, reverse=True) or len(set(versions)) != len(versions):
        raise SystemExit("version_history must be unique and newest-first")


def validate_fields(table: str, fields: list[dict], *, reserved_id: int | None, require_scope: bool = True) -> None:
    ids: set[int] = set()
    names: set[str] = set()
    for field in fields:
        name = field.get("name", "")
        if not NAME_RE.fullmatch(name):
            raise SystemExit(f"invalid {table} name: {name!r}")
        if name in names:
            raise SystemExit(f"duplicate {table} name: {name!r}")
        names.add(name)
        ident = field.get("id")
        if not isinstance(ident, int) or ident < 0:
            raise SystemExit(f"invalid {table} id for {name!r}")
        if ident in ids:
            raise SystemExit(f"duplicate {table} id: {ident}")
        ids.add(ident)
        if reserved_id is not None and ident == reserved_id:
            raise SystemExit(f"{table} id {ident} is reserved for custom attribute markers")
        if not field.get("doc"):
            raise SystemExit(f"{table} entry {name!r} is missing a doc line")
        if require_scope:
            if not isinstance(field.get("native"), bool):
                raise SystemExit(f"{table} entry {name!r} must declare native: true/false")
            if field["native"] == ("browser_op" in field):
                raise SystemExit(f"{table} entry {name!r}: exactly the web fields carry a browser_op")


def natives(fields: list[dict]) -> list[dict]:
    return [field for field in fields if field["native"]]


def render_zig(manifest: dict) -> str:
    lines: list[str] = []
    out = lines.append
    out("//! Native GUI protocol tables generated from protocol/native-protocol.json.")
    out("//!")
    out("//! GENERATED FILE - do not edit by hand. Update the manifest and run")
    out("//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies")
    out("//! that this committed artifact matches the manifest.")
    out("")
    out("/// Version of the statically linked native GUI presentation boundary.")
    out(f"pub const protocol_version: u32 = {manifest['protocol_version']};")
    out("")
    out("/// Version of the separate native timer boundary.")
    out(f"pub const timer_version: u32 = {manifest['timer_version']};")
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
        out("    /// Identifies fields consumed only by the native presentation adapter.")
        out(f"    pub fn isNative(self: {enum_name}) bool {{")
        out("        return switch (self) {")
        native_tags = ", ".join("." + field["name"] for field in natives(fields))
        out(f"            {native_tags} => true,")
        out("            else => false,")
        out("        };")
        out("    }")
        out("")
        out("    /// Returns the browser opcode name for a web scalar, or null for native")
        out("    /// metadata that must be rejected before browser wire preparation.")
        out(f"    pub fn browserOpName(self: {enum_name}) ?[]const u8 {{")
        out("        return switch (self) {")
        for field in fields:
            if not field["native"]:
                out(f"            .{field['name']} => \"{field['browser_op']}\",")
        out(f"            {native_tags} => null,")
        out("        };")
        out("    }")
        out("};")
        out("")
    text_fields = manifest["text_fields"]
    bool_fields = manifest["bool_fields"]
    out("/// Total declared scalar text fields.")
    out(f"pub const text_field_count: usize = {len(text_fields)};")
    out("")
    out("/// Total declared scalar boolean fields.")
    out(f"pub const bool_field_count: usize = {len(bool_fields)};")
    out("")
    out("/// Scalar text fields consumed only by the native presentation adapter.")
    out(f"pub const native_text_field_count: usize = {len(natives(text_fields))};")
    out("")
    out("/// Scalar boolean fields consumed only by the native presentation adapter.")
    out(f"pub const native_bool_field_count: usize = {len(natives(bool_fields))};")
    out("")
    out("/// The extern node record served through `signals_read_changed`. Zig and Rust")
    out("/// declare this layout from the same manifest order, so the field order is ABI;")
    out("/// `signals_node_size` and the host-side size assertion pin the layout.")
    out("pub fn RawNode(comptime Slice: type, comptime Style: type, comptime Viewport: type) type {")
    out("    return extern struct {")
    for field in manifest["raw_node"]["fields"]:
        out(f"        /// {field['doc']}")
        out(f"        {field['name']}: {RAW_NODE_TYPES[field['type']][0]},")
    out("    };")
    out("}")
    return "\n".join(lines) + "\n"


def render_rust(manifest: dict) -> str:
    lines: list[str] = []
    out = lines.append
    out("//! Native GUI protocol tables generated from protocol/native-protocol.json.")
    out("//!")
    out("//! GENERATED FILE - do not edit by hand. Update the manifest and run")
    out("//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies")
    out("//! that this committed artifact matches the manifest.")
    out("")
    out("use crate::bridge::{Slice, Style};")
    out("")
    out("/// Version of the statically linked native GUI presentation boundary.")
    out(f"pub const PROTOCOL_VERSION: u32 = {manifest['protocol_version']};")
    out("")
    out("/// Version of the separate native timer boundary.")
    out(f"pub const TIMER_VERSION: u32 = {manifest['timer_version']};")
    out("")
    out("/// The extern node record read through `signals_read_changed`. Zig and Rust")
    out("/// declare this layout from the same manifest order, so the field order is ABI;")
    out("/// the `signals_node_size` assertion in `bridge::Engine::open` pins the layout.")
    out("#[repr(C)]")
    out("pub struct RawNode {")
    for field in manifest["raw_node"]["fields"]:
        out(f"    /// {field['doc']}")
        out(f"    pub {field['name']}: {RAW_NODE_TYPES[field['type']][1]},")
    out("}")
    return "\n".join(lines) + "\n"


def render_roc_section(manifest: dict) -> str:
    lines: list[str] = [ROC_BEGIN]
    out = lines.append
    for table, kind in (("text_fields", "TextField"), ("bool_fields", "BoolField")):
        for field in manifest[table]:
            const = field.get("roc_const")
            if const is None:
                continue
            out(f"# {field['doc']}")
            out(f"{const} : Node.{kind}")
            out(f"{const} = {{ id: {field['id']} }}")
    out(ROC_END)
    return "\n".join(lines)


def render_docs_section(manifest: dict) -> str:
    lines: list[str] = [DOCS_BEGIN]
    out = lines.append
    out("")
    out(f"The statically linked GUI boundary uses protocol version **{manifest['protocol_version']}**")
    out(f"and the separate timer boundary is version **{manifest['timer_version']}**.")
    out("")
    out("| Version | Change |")
    out("| --- | --- |")
    for entry in manifest["version_history"]:
        out(f"| {entry['version']} | {entry['summary']} |")
    out("")
    out("Scalar text fields:")
    out("")
    out("| Id | Field | Scope | Purpose |")
    out("| --- | --- | --- | --- |")
    for field in manifest["text_fields"]:
        scope = "native" if field["native"] else f"browser (`{field['browser_op']}`)"
        out(f"| {field['id']} | `{field['name']}` | {scope} | {field['doc']} |")
    out(f"| {manifest['custom_text_field_id']} | - | shared | Reserved marker for named custom text attributes. |")
    out("")
    out("Scalar boolean fields:")
    out("")
    out("| Id | Field | Scope | Purpose |")
    out("| --- | --- | --- | --- |")
    for field in manifest["bool_fields"]:
        scope = "native" if field["native"] else f"browser (`{field['browser_op']}`)"
        out(f"| {field['id']} | `{field['name']}` | {scope} | {field['doc']} |")
    out(f"| {manifest['custom_bool_field_id']} | - | shared | Reserved marker for named custom boolean attributes. |")
    out("")
    out(DOCS_END)
    return "\n".join(lines)


def replace_section(content: str, begin: str, end: str, section: str, path: Path) -> str:
    start = content.find(begin)
    stop = content.find(end)
    if start < 0 or stop < 0 or stop < start:
        raise SystemExit(f"{path} is missing its GENERATED protocol markers")
    return content[:start] + section + content[stop + len(end):]


def render_all(manifest: dict) -> dict[Path, str]:
    artifacts = {ZIG_OUT: render_zig(manifest), RUST_OUT: render_rust(manifest)}
    for path, begin, end, section in (
        (ROC_OUT, ROC_BEGIN, ROC_END, render_roc_section(manifest)),
        (DOCS_OUT, DOCS_BEGIN, DOCS_END, render_docs_section(manifest)),
    ):
        artifacts[path] = replace_section(path.read_text(), begin, end, section, path)
    return artifacts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail when any committed artifact differs from the manifest rendering.")
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
