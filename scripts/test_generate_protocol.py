"""Unit tests for the native protocol generator."""

from __future__ import annotations

import copy
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_protocol as gen


def manifest() -> dict:
    return copy.deepcopy(gen.load_manifest())


class ManifestValidationTests(unittest.TestCase):
    def test_committed_manifest_loads(self):
        self.assertEqual(manifest()["schema_version"], 1)

    def test_duplicate_field_id_is_rejected(self):
        bad = manifest()
        bad["text_fields"][1]["id"] = bad["text_fields"][0]["id"]
        with self.assertRaisesRegex(SystemExit, "duplicate text_fields id"):
            gen.validate(bad)

    def test_duplicate_field_name_is_rejected(self):
        bad = manifest()
        bad["bool_fields"][1]["name"] = bad["bool_fields"][0]["name"]
        with self.assertRaisesRegex(SystemExit, "duplicate bool_fields name"):
            gen.validate(bad)

    def test_custom_marker_id_stays_reserved(self):
        bad = manifest()
        bad["text_fields"][0]["id"] = bad["custom_text_field_id"]
        with self.assertRaisesRegex(SystemExit, "reserved for custom attribute markers"):
            gen.validate(bad)

    def test_native_field_carries_no_browser_op(self):
        bad = manifest()
        native = next(f for f in bad["text_fields"] if f["native"])
        native["browser_op"] = "set_text"
        with self.assertRaisesRegex(SystemExit, "exactly the web fields carry a browser_op"):
            gen.validate(bad)

    def test_web_field_requires_browser_op(self):
        bad = manifest()
        web = next(f for f in bad["text_fields"] if not f["native"])
        del web["browser_op"]
        with self.assertRaisesRegex(SystemExit, "exactly the web fields carry a browser_op"):
            gen.validate(bad)

    def test_unknown_raw_node_type_is_rejected(self):
        bad = manifest()
        bad["raw_node"]["fields"][0]["type"] = "pointer"
        with self.assertRaisesRegex(SystemExit, "unknown raw_node field type"):
            gen.validate(bad)

    def test_missing_doc_is_rejected(self):
        bad = manifest()
        bad["task_kinds"][2]["doc"] = ""
        with self.assertRaisesRegex(SystemExit, "missing a doc line"):
            gen.validate(bad)

    def test_version_history_must_lead_with_current_version(self):
        bad = manifest()
        bad["protocol_version"] += 1
        with self.assertRaisesRegex(SystemExit, "version_history must start"):
            gen.validate(bad)

    def test_external_task_route_is_pinned_to_zero(self):
        bad = manifest()
        bad["task_kinds"][0]["id"] = max(kind["id"] for kind in bad["task_kinds"]) + 1
        with self.assertRaisesRegex(SystemExit, "external route"):
            gen.validate(bad)


class RenderingTests(unittest.TestCase):
    def test_raw_node_order_matches_between_zig_and_rust(self):
        data = manifest()
        expected = [field["name"] for field in data["raw_node"]["fields"]]
        zig = gen.render_zig(data)
        zig_struct = zig.split("return extern struct {", 1)[1]
        zig_names = re.findall(r"^        (\w+): ", zig_struct, re.M)
        rust = gen.render_rust(data)
        rust_struct = rust.split("pub struct RawNode {", 1)[1]
        rust_names = re.findall(r"^    pub (\w+): ", rust_struct, re.M)
        self.assertEqual(zig_names, expected)
        self.assertEqual(rust_names, expected)

    def test_versions_render_into_both_languages(self):
        data = manifest()
        zig = gen.render_zig(data)
        rust = gen.render_rust(data)
        self.assertIn(f"pub const protocol_version: u32 = {data['protocol_version']};", zig)
        self.assertIn(f"pub const PROTOCOL_VERSION: u32 = {data['protocol_version']};", rust)
        self.assertIn(f"pub const EFFECT_VERSION: u32 = {data['effect_version']};", rust)
        self.assertIn(f"pub const TIMER_VERSION: u32 = {data['timer_version']};", rust)

    def test_native_counts_render_from_the_tables(self):
        data = manifest()
        zig = gen.render_zig(data)
        native_text = sum(1 for field in data["text_fields"] if field["native"])
        native_bool = sum(1 for field in data["bool_fields"] if field["native"])
        self.assertIn(f"pub const native_text_field_count: usize = {native_text};", zig)
        self.assertIn(f"pub const native_bool_field_count: usize = {native_bool};", zig)

    def test_roc_section_renders_declared_constants(self):
        data = manifest()
        section = gen.render_roc_section(data)
        for table, kind in (("text_fields", "TextField"), ("bool_fields", "BoolField")):
            for field in data[table]:
                const = field.get("roc_const")
                if const is None:
                    self.assertNotIn(f"{field['name']}_field", section)
                else:
                    self.assertIn(f"{const} : Node.{kind}", section)
                    self.assertIn(f"{const} = {{ id: {field['id']} }}", section)

    def test_docs_section_tables_cover_every_field_and_task(self):
        data = manifest()
        section = gen.render_docs_section(data)
        for field in data["text_fields"] + data["bool_fields"]:
            self.assertIn(f"`{field['name']}`", section)
        for kind in data["task_kinds"]:
            self.assertIn(f"| {kind['id']} | `{kind['name']}` |", section)

    def test_committed_artifacts_are_current(self):
        for path, content in gen.render_all(gen.load_manifest()).items():
            self.assertEqual(path.read_text(), content, f"stale generated artifact: {path}")

    def test_section_replacement_requires_markers(self):
        with self.assertRaisesRegex(SystemExit, "GENERATED protocol markers"):
            gen.replace_section("no markers here", gen.ROC_BEGIN, gen.ROC_END, "x", gen.ROC_OUT)


if __name__ == "__main__":
    unittest.main()
