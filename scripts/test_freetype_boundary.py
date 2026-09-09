"""Prove Cargo bypasses a native producer that would otherwise build FreeType."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FreeTypeBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SIGNALS_TEST_CARGO_BOUNDARY") == "1", "requires the native Rust 1.95 Cargo probe")
    def test_override_prevents_native_build_even_with_pkg_config_disabled(self):
        with tempfile.TemporaryDirectory(prefix="signals-freetype-boundary-") as temporary:
            root = Path(temporary)
            (root / "src").mkdir()
            (root / "src/lib.rs").write_text("pub fn binding() -> usize { freetype_sys::binding() }\n")
            (root / "Cargo.toml").write_text(
                '[package]\nname="boundary-probe"\nversion="0.0.0"\nedition="2024"\n'
                '[dependencies]\nfreetype-sys={path="native"}\n')
            native = root / "native"
            (native / "src").mkdir(parents=True)
            (native / "Cargo.toml").write_text(
                '[package]\nname="freetype-sys"\nversion="0.20.1"\nedition="2024"\nlinks="freetype"\n')
            (native / "src/lib.rs").write_text("pub fn binding() -> usize { 1 }\n")
            (native / "build.rs").write_text('fn main() { panic!("NATIVE_FREETYPE_BUILD_MUST_NOT_RUN"); }\n')
            environment = dict(os.environ, RUSTUP_TOOLCHAIN="1.95.0", CARGO_TARGET_DIR=str(root / "target"),
                               PKG_CONFIG=str(root / "missing-pkg-config"), FREETYPE2_NO_PKG_CONFIG="1",
                               FREETYPE2_STATIC="1", CC=str(root / "missing-cc"), CXX=str(root / "missing-cxx"))
            command = ["cargo", "build", "--offline", "--lib", "--message-format=json"]
            baseline = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True)
            self.assertNotEqual(baseline.returncode, 0)
            self.assertIn("NATIVE_FREETYPE_BUILD_MUST_NOT_RUN", baseline.stderr)
            (root / ".cargo").mkdir()
            # Exercise the actual maintained configuration, not a mirrored override.
            (root / ".cargo/config.toml").write_bytes((ROOT / ".cargo/config.toml").read_bytes())
            environment["CARGO_TARGET_DIR"] = str(root / "override-target")
            overridden = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(overridden.returncode, 0, overridden.stderr)
            messages = [json.loads(line) for line in overridden.stdout.splitlines() if line.startswith("{")]
            freetype = [m for m in messages if "freetype-sys" in m.get("package_id", "")]
            self.assertTrue(freetype)
            self.assertFalse(any(m["reason"] == "build-script-executed" or
                                 "custom-build" in m.get("target", {}).get("kind", []) for m in freetype))

    def test_override_is_explicit_and_linux_only(self):
        config = tomllib.loads((ROOT / ".cargo/config.toml").read_text())
        self.assertEqual(config["target"]["x86_64-unknown-linux-gnu"]["freetype"],
                         {"rustc-link-lib": ["dylib=freetype"]})
        self.assertNotIn("freetype", config.get("target", {}).get("x86_64-pc-windows-msvc", {}))


if __name__ == "__main__":
    unittest.main()
