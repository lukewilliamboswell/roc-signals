"""Size measurement helpers: section parsing, family grouping, budgets."""

import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wasm_size  # noqa: E402


def section(kind: int, payload: bytes) -> bytes:
    assert len(payload) < 128
    return bytes([kind, len(payload)]) + payload


def report(**sizes: tuple[int, int]) -> dict:
    return {
        "label": "x",
        "revision": "abc",
        "dirty": [],
        "tools": {"roc": "Roc nightly", "zig": "0.16.0"},
        "compression": {"implementation": "node-zlib"},
        "fixtures": [
            {"name": name, "raw": raw, "code": raw - 10, "gzip": gzip, "brotli": gzip - 5}
            for name, (raw, gzip) in sizes.items()
        ],
    }


class SectionTests(unittest.TestCase):
    def test_sections_are_summed_by_kind(self) -> None:
        binary = b"\0asm\1\0\0\0" + section(1, b"\x01\x60\x00\x00") + section(10, b"\x00" * 20) + section(11, b"\x00" * 7) + section(0, b"\x04name") + section(0, b"\x01x")
        sections = wasm_size.wasm_sections(binary)
        self.assertEqual(sections["code"], 20)
        self.assertEqual(sections["data"], 7)
        self.assertEqual(sections["custom"], 7)

    def test_truncated_or_foreign_binaries_are_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            wasm_size.wasm_sections(b"\0asm\1\0\0\0" + bytes([10, 5, 0]))
        with self.assertRaises(SystemExit):
            wasm_size.wasm_sections(b"\x7fELF")

    def test_multi_byte_leb128_lengths(self) -> None:
        payload = b"\x00" * 300
        binary = b"\0asm\1\0\0\0" + bytes([10, 0xAC, 0x02]) + payload
        self.assertEqual(wasm_size.wasm_sections(binary)["code"], 300)


class FamilyTests(unittest.TestCase):
    def test_generic_arguments_and_anonymous_suffixes_collapse(self) -> None:
        names = [
            "hash_map.HashMapUnmanaged(u32,engine.Engine(wasm_host.WasmCtx).Record,std.hash_map.AutoContext(u32),80).get",
            "hash_map.HashMapUnmanaged(u64,[]const u8,std.hash_map.AutoContext(u64),80).get__anon_1234",
            "host_value_registry.Registry(roc_platform_abi.HostValueCapabilityHandle__struct_1269).slot",
        ]
        self.assertEqual(wasm_size.symbol_family(names[0]), "hash_map.HashMapUnmanaged.get")
        self.assertEqual(wasm_size.symbol_family(names[1]), "hash_map.HashMapUnmanaged.get")
        self.assertEqual(wasm_size.symbol_family(names[2]), "host_value_registry.Registry.slot")


class BudgetTests(unittest.TestCase):
    def test_generated_budgets_pass_then_fail_on_growth(self) -> None:
        baseline = report(counter=(100_000, 40_000), rows=(200_000, 70_000))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "budgets.toml"
            with contextlib.redirect_stderr(io.StringIO()):
                wasm_size.write_budgets(baseline, path)
            self.assertIn("never", path.read_text())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(wasm_size.check_budgets(baseline, path), 0)
                grown = report(counter=(101_000, 40_000), rows=(200_000, 70_000))
                self.assertEqual(wasm_size.check_budgets(grown, path), 0)
                grown = report(counter=(101_001, 40_000), rows=(200_000, 70_000))
                self.assertEqual(wasm_size.check_budgets(grown, path), 1)
                missing = report(counter=(100_000, 40_000))
                self.assertEqual(wasm_size.check_budgets(missing, path), 1)
                extra = report(counter=(100_000, 40_000), rows=(200_000, 70_000), new=(1, 1))
                self.assertEqual(wasm_size.check_budgets(extra, path), 1)

    def test_compare_reports_cumulative_delta(self) -> None:
        before = report(counter=(100_000, 40_000), rows=(200_000, 70_000))
        after = report(counter=(90_000, 36_000), rows=(200_000, 70_000))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            wasm_size.compare(before, after)
        self.assertIn("| counter | 100,000 | 90,000 | -10,000 (-10.00%)", output.getvalue())
        self.assertIn("| **cumulative** | 300,000 | 290,000 | -10,000 (-3.33%)", output.getvalue())


if __name__ == "__main__":
    unittest.main()
