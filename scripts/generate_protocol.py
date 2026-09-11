#!/usr/bin/env python3
"""Generate the committed native GUI protocol artifacts from one manifest.

`protocol/native-protocol.json` is the single authority for the native GUI
protocol tables: the protocol version, the scalar text/bool field tables, the
task-kind routes, and the extern node record layout shared by the Zig engine
and the Rust GPUI host. This script renders that manifest into:

- `src/signals/native_protocol_gen.zig` (whole file)
- `crates/gpui-host/src/protocol_gen.rs` (whole file)
- `platform-gui/Gui.roc` (between GENERATED markers)
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
ROC_OUT = ROOT / "platform-gui" / "Gui.roc"
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
    if manifest.get("schema_version") != 2:
        raise SystemExit("unsupported protocol manifest schema")
    for key in ("protocol_version", "effect_version", "timer_version"):
        if not isinstance(manifest.get(key), int) or manifest[key] < 1:
            raise SystemExit(f"protocol manifest {key} must be a positive integer")
    for table, custom_key in (("text_fields", "custom_text_field_id"), ("bool_fields", "custom_bool_field_id")):
        fields = manifest.get(table)
        if not fields:
            raise SystemExit(f"protocol manifest is missing {table}")
        validate_fields(table, fields, reserved_id=manifest.get(custom_key))
    validate_fields("task_kinds", manifest.get("task_kinds", []), reserved_id=None, require_scope=False)
    if manifest["task_kinds"][0]["id"] != 0 or manifest["task_kinds"][0]["name"] != "external":
        raise SystemExit("task kind 0 must remain the external route")
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
    validate_task_shapes(manifest)


FIELD_TYPES = {"path", "text", "u64", "bool", "enum", "list", "tagged", "hex_sha256"}
FIXTURE_RULES = {"directory_path_budget", "canceled_empty_detail"}
REQUEST_RULES = {"log_cursor", "assets_manifest"}


def validate_shape_fields(where: str, fields: list[dict], *, nested: bool = False) -> None:
    """Checks one ordered field list: names, types, and the bounds each type carries.

    A list's element fields and a tagged field's variant fields are checked the
    same way, so a shape nests to any depth the codec can frame.
    """
    names = set()
    for field in fields:
        for key in ("name", "type", "doc"):
            if key not in field:
                raise ValueError(f"{where}: field {field.get('name', '?')!r} is missing {key}")
        if not re.fullmatch(r"[a-z][a-z0-9_]*", field["name"]):
            raise ValueError(f"{where}: invalid field name {field['name']!r}")
        if field["name"] in names:
            raise ValueError(f"{where}: duplicate field {field['name']!r}")
        names.add(field["name"])
        kind = field["type"]
        if kind not in FIELD_TYPES:
            raise ValueError(f"{where}.{field['name']}: unknown field type {kind!r}")
        if kind == "text" and not isinstance(field.get("max_bytes"), int):
            raise ValueError(f"{where}.{field['name']}: text needs max_bytes")
        if kind == "enum" and not field.get("values"):
            raise ValueError(f"{where}.{field['name']}: enum needs values")
        if kind == "list":
            if not isinstance(field.get("max_items"), int) or not field.get("of"):
                raise ValueError(f"{where}.{field['name']}: list needs max_items and of")
            validate_shape_fields(f"{where}.{field['name']}", field["of"], nested=True)
            spelling = field.get("spelling")
            if spelling is not None and sorted(spelling) != sorted(sub["name"] for sub in field["of"]):
                raise ValueError(f"{where}.{field['name']}: spelling must permute the element fields")
        if kind == "tagged":
            if not field.get("variants"):
                raise ValueError(f"{where}.{field['name']}: tagged needs variants")
            for variant in field["variants"]:
                validate_shape_fields(f"{where}.{field['name']}.{variant['tag']}", variant["fields"], nested=True)


def validate_task_shapes(manifest: dict) -> None:
    fixtures: dict[str, str] = {}
    for kind in manifest["task_kinds"]:
        if kind["name"] == "external":
            if kind.get("request") or kind.get("result") or kind.get("fixture"):
                raise ValueError("external tasks carry no manifest shape")
            continue
        for side in ("request", "result"):
            if side not in kind:
                raise ValueError(f"task kind {kind['name']!r} is missing its {side} shape")
            validate_shape_fields(f"{kind['name']}.{side}", kind[side])
        for rule in kind.get("rules", []):
            if rule not in FIXTURE_RULES:
                raise ValueError(f"task kind {kind['name']!r}: unknown fixture rule {rule!r}")
        for rule in kind.get("request_rules", []):
            if rule not in REQUEST_RULES:
                raise ValueError(f"task kind {kind['name']!r}: unknown request rule {rule!r}")
        fixture = kind.get("fixture")
        if fixture is not None:
            if fixture in fixtures and manifest_result(manifest, fixtures[fixture]) != kind["result"]:
                raise ValueError(f"fixture {fixture!r} is shared by kinds with different result shapes")
            fixtures.setdefault(fixture, kind["name"])
    error = manifest["task_error"]
    validate_shape_fields("task_error", error["fields"])
    if error["fixture"] in fixtures:
        raise ValueError("the error fixture must not share a name with a result fixture")
    for rule in error.get("rules", []):
        if rule not in FIXTURE_RULES:
            raise ValueError(f"task_error: unknown fixture rule {rule!r}")


def manifest_result(manifest: dict, kind_name: str) -> list[dict]:
    return next(kind["result"] for kind in manifest["task_kinds"] if kind["name"] == kind_name)


def request_frames(kind: dict) -> int | None:
    """Frames a request carries after the codec frame, or None when a list makes it variable."""
    if any(field["type"] == "list" for field in kind.get("request", [])):
        return None
    return len(kind.get("request", []))


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
    out("/// Version of the separate native effects (task transport) boundary.")
    out(f"pub const effect_version: u32 = {manifest['effect_version']};")
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
    out("/// Closed task service routes. Names remain diagnostics; native hosts dispatch")
    out("/// only this value, and browser hosts reject native service requests.")
    out("pub const TaskKind = enum(u32) {")
    for kind in manifest["task_kinds"]:
        out(f"    /// {kind['doc']}")
        out(f"    {kind['name']} = {kind['id']},")
    out("};")
    out("")
    out("/// One field of a task request or result, in wire order.")
    out("pub const TaskField = struct {")
    out("    name: []const u8,")
    out("    kind: TaskFieldKind,")
    out("};")
    out("")
    out("/// The typed shape of one task field. Text bounds are UTF-8 bytes; a list is")
    out("/// framed as its count and then each element's fields in order; a tagged")
    out("/// field is framed as its tag and then the chosen variant's fields.")
    out("pub const TaskFieldKind = union(enum) {")
    out("    path,")
    out("    text: struct { max_bytes: usize, non_empty: bool = false },")
    out("    unsigned: struct { max_value: ?u64 = null },")
    out("    boolean,")
    out("    symbol: []const []const u8,")
    out("    hex_sha256,")
    out("    list: struct { min_items: usize = 0, max_items: usize, of: []const TaskField, spelling: ?[]const []const u8 = null },")
    out("    tagged: []const TaskVariant,")
    out("};")
    out("")
    out("/// One variant of a tagged task field.")
    out("pub const TaskVariant = struct { tag: []const u8, fields: []const TaskField };")
    out("")
    out("/// The manifest's shape for one task kind: what a request carries after the")
    out("/// codec frame, what a successful result carries, the spec fixture that spells")
    out("/// the result, and the hand-written rules the generic validators call by name.")
    out("pub const TaskSchema = struct {")
    out("    kind: TaskKind,")
    out("    request: []const TaskField,")
    out("    result: []const TaskField,")
    out("    fixture: ?[]const u8,")
    out("    rules: []const []const u8,")
    out("    request_rules: []const []const u8,")
    out("};")
    out("")
    out("/// Every task kind's shape, indexed by kind.")
    out("pub const task_schemas = [_]TaskSchema{")
    for kind in manifest["task_kinds"]:
        out("    .{")
        out(f"        .kind = .{kind['name']},")
        out(f"        .request = &{zig_fields(kind.get('request', []), 2)},")
        out(f"        .result = &{zig_fields(kind.get('result', []), 2)},")
        fixture = kind.get("fixture")
        out(f"        .fixture = {zig_string(fixture) if fixture else 'null'},")
        out(f"        .rules = &{zig_strings(kind.get('rules', []))},")
        out(f"        .request_rules = &{zig_strings(kind.get('request_rules', []))},")
        out("    },")
    out("};")
    out("")
    error = manifest["task_error"]
    out("/// The error shape every non-external task kind may settle with.")
    out(f"pub const task_error_fields = {zig_fields(error['fields'], 0)};")
    out("")
    out("/// The spec fixture that spells a task error.")
    out(f"pub const task_error_fixture = {zig_string(error['fixture'])};")
    out("")
    out("/// The hand-written rules the error fixture applies, by name.")
    out(f"pub const task_error_rules = {zig_strings(error.get('rules', []))};")
    out("")
    out("/// Frames a request of this kind carries after the codec frame, or null")
    out("/// when a list field makes the count depend on the request.")
    out("pub fn requestFrames(kind: TaskKind) ?usize {")
    out("    return switch (kind) {")
    for kind in manifest["task_kinds"]:
        frames = request_frames(kind)
        out(f"        .{kind['name']} => {'null' if frames is None else frames},")
    out("    };")
    out("}")
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


def zig_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def zig_initializer(type_name: str, items: list[str]) -> str:
    """Spells an array literal the way `zig fmt` does: one item hugs its braces."""
    if not items:
        return type_name + "{}"
    if len(items) == 1:
        return type_name + "{" + items[0] + "}"
    return type_name + "{ " + ", ".join(items) + " }"


def zig_strings(values: list[str]) -> str:
    return zig_initializer("[_][]const u8", [zig_string(value) for value in values])


def zig_field_kind(field: dict) -> str:
    kind = field["type"]
    if kind == "path":
        return ".path"
    if kind == "text":
        non_empty = ", .non_empty = true" if field.get("non_empty") else ""
        return f".{{ .text = .{{ .max_bytes = {field['max_bytes']}{non_empty} }} }}"
    if kind == "u64":
        max_value = f".{{ .max_value = {field['max_value']} }}" if "max_value" in field else ".{}"
        return f".{{ .unsigned = {max_value} }}"
    if kind == "bool":
        return ".boolean"
    if kind == "enum":
        return f".{{ .symbol = &{zig_strings(field['values'])} }}"
    if kind == "hex_sha256":
        return ".hex_sha256"
    if kind == "list":
        min_items = f".min_items = {field['min_items']}, " if "min_items" in field else ""
        spelling = f", .spelling = &{zig_strings(field['spelling'])}" if field.get("spelling") else ""
        return f".{{ .list = .{{ {min_items}.max_items = {field['max_items']}, .of = &{zig_fields(field['of'], 0)}{spelling} }} }}"
    if kind == "tagged":
        variants = [
            f".{{ .tag = {zig_string(variant['tag'])}, .fields = &{zig_fields(variant['fields'], 0)} }}"
            for variant in field["variants"]]
        return f".{{ .tagged = &{zig_initializer('[_]TaskVariant', variants)} }}"
    raise ValueError(kind)


def zig_fields(fields: list[dict], indent: int) -> str:
    return zig_initializer("[_]TaskField", [
        f".{{ .name = {zig_string(field['name'])}, .kind = {zig_field_kind(field)} }}" for field in fields])


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
    out("/// Version of the separate native effects (task transport) boundary.")
    out(f"pub const EFFECT_VERSION: u32 = {manifest['effect_version']};")
    out("")
    out("/// Version of the separate native timer boundary.")
    out(f"pub const TIMER_VERSION: u32 = {manifest['timer_version']};")
    out("")
    out("/// Closed task service routes carried in native effect messages.")
    out("#[allow(dead_code)]")
    out("pub mod task_kind {")
    for kind in manifest["task_kinds"]:
        out(f"    /// {kind['doc']}")
        out(f"    pub const {kind['name'].upper()}: u32 = {kind['id']};")
    out("}")
    out("")
    out("/// Frames each task kind's request carries after the codec frame, from the")
    out("/// manifest; `None` where a list field makes the count depend on the request.")
    out("/// `effects::Request::decode` is tested against this table.")
    out("#[allow(dead_code)]")
    out("pub const REQUEST_FRAMES: &[(u32, Option<usize>)] = &[")
    for kind in manifest["task_kinds"]:
        frames = request_frames(kind)
        out(f"    ({kind['id']}, {'None' if frames is None else f'Some({frames})'}),")
    out("];")
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
    out(f"The statically linked GUI boundary uses protocol version **{manifest['protocol_version']}**;")
    out(f"the separate native effects boundary is version **{manifest['effect_version']}** and the")
    out(f"separate timer boundary is version **{manifest['timer_version']}**.")
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
    out("`Node.TaskKind` is an explicit closed route:")
    out("")
    out("| Id | Kind | Purpose |")
    out("| --- | --- | --- |")
    for kind in manifest["task_kinds"]:
        out(f"| {kind['id']} | `{kind['name']}` | {kind['doc']} |")
    out("")
    out("Each kind's request and result are framed in this order after the `files1`")
    out("codec frame. A list is framed as its count and then each element's fields;")
    out("a tagged field as its tag and then the chosen variant's fields. The spec")
    out("fixture named for a kind spells its result; `reject-file` spells the error.")
    out("")
    for kind in manifest["task_kinds"]:
        if kind["name"] == "external":
            continue
        out(f"`{kind['name']}` — request: {docs_fields(kind['request']) or 'none'}; result: {docs_fields(kind['result']) or 'none'}"
            + (f"; fixture `{kind['fixture']}`" if kind.get("fixture") else "") + ".")
        out("")
    error = manifest["task_error"]
    out(f"Task error — {docs_fields(error['fields'])}; fixture `{error['fixture']}`.")
    out("")
    out(DOCS_END)
    return "\n".join(lines)


def docs_field(field: dict) -> str:
    kind = field["type"]
    if kind == "text":
        return f"`{field['name']}` text ≤ {field['max_bytes']} B"
    if kind == "u64":
        return f"`{field['name']}` u64" + (f" ≤ {field['max_value']}" if "max_value" in field else "")
    if kind == "enum":
        return f"`{field['name']}` one of " + "/".join(f"`{value}`" for value in field["values"])
    if kind == "list":
        return f"`{field['name']}` list (≤ {field['max_items']}) of [{docs_fields(field['of'])}]"
    if kind == "tagged":
        return f"`{field['name']}` " + " | ".join(
            f"`{variant['tag']}`" + (f" [{docs_fields(variant['fields'])}]" if variant["fields"] else "")
            for variant in field["variants"])
    return f"`{field['name']}` {kind}"


def docs_fields(fields: list[dict]) -> str:
    return ", ".join(docs_field(field) for field in fields)


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
