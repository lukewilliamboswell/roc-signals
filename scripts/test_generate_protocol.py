"""Unit tests for the scalar field table generator."""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_protocol as gen


def manifest() -> dict:
    return copy.deepcopy(gen.load_manifest())


class ManifestValidationTests(unittest.TestCase):
    def test_committed_manifest_loads(self):
        self.assertEqual(manifest()["schema_version"], gen.SCHEMA_VERSION)

    def test_unsupported_schema_is_rejected(self):
        bad = manifest()
        bad["schema_version"] = 1
        with self.assertRaisesRegex(SystemExit, "unsupported protocol manifest schema"):
            gen.validate(bad)

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

    def test_every_field_requires_a_browser_op(self):
        bad = manifest()
        del bad["text_fields"][0]["browser_op"]
        with self.assertRaisesRegex(SystemExit, "must name its browser_op"):
            gen.validate(bad)

    def test_duplicate_browser_op_is_rejected(self):
        bad = manifest()
        bad["bool_fields"][1]["browser_op"] = bad["bool_fields"][0]["browser_op"]
        with self.assertRaisesRegex(SystemExit, "duplicate bool_fields browser_op"):
            gen.validate(bad)

    def test_unknown_field_key_is_rejected(self):
        bad = manifest()
        bad["text_fields"][0]["native"] = True
        with self.assertRaisesRegex(SystemExit, "unknown keys"):
            gen.validate(bad)

    def test_missing_doc_is_rejected(self):
        bad = manifest()
        bad["text_fields"][2]["doc"] = ""
        with self.assertRaisesRegex(SystemExit, "missing a doc line"):
            gen.validate(bad)


class RenderingTests(unittest.TestCase):
    def test_every_field_renders_its_id_and_browser_op(self):
        data = manifest()
        zig = gen.render_zig(data)
        for field in data["text_fields"] + data["bool_fields"]:
            self.assertIn(f"    {field['name']} = {field['id']},", zig)
            self.assertIn(f"            .{field['name']} => \"{field['browser_op']}\",", zig)

    def test_counts_render_from_the_tables(self):
        data = manifest()
        zig = gen.render_zig(data)
        self.assertIn(f"pub const text_field_count: usize = {len(data['text_fields'])};", zig)
        self.assertIn(f"pub const bool_field_count: usize = {len(data['bool_fields'])};", zig)

    def test_committed_artifacts_are_current(self):
        for path, content in gen.render_all(gen.load_manifest()).items():
            self.assertEqual(path.read_text(), content, f"stale generated artifact: {path}")


if __name__ == "__main__":
    unittest.main()
