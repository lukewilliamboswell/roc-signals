"""Exercise Cargo's real freshness checks when checkouts share build outputs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CargoCheckoutTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cargo"), "Cargo is required for its cache regression")
    def test_checkout_switch_and_source_edit_invalidate_only_when_needed(self):
        with tempfile.TemporaryDirectory(prefix="signals-cargo-cache-") as temporary:
            root = Path(temporary)
            environment = os.environ.copy()
            environment["CARGO_TARGET_DIR"] = str(root / "target")
            for name, value in (("one", 1), ("two", 2)):
                directory = root / name
                (directory / "src").mkdir(parents=True)
                (directory / ".cargo").mkdir()
                (directory / "Cargo.toml").write_text(
                    '[package]\nname="signals-cache-probe"\nversion="0.1.0"\nedition="2024"\n')
                (directory / "src/main.rs").write_text(f'fn main() {{ println!("{value}"); }}\n')
                shutil.copyfile(ROOT / ".cargo/config.toml", directory / ".cargo/config.toml")
                shutil.copyfile(ROOT / "crates/gpui-host/build.rs", directory / "build.rs")
            executable = root / "target/release" / ("signals-cache-probe.exe" if os.name == "nt"
                                                   else "signals-cache-probe")

            def build(name, expected):
                result = subprocess.run(
                    ["cargo", "build", "--offline", "--release", "--verbose"],
                    cwd=root / name, env=environment, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(subprocess.check_output([executable], text=True).strip(), expected)
                return result.stderr

            for name, value in (("one", "1"), ("two", "2"), ("one", "1"), ("two", "2")):
                build(name, value)
            self.assertNotIn("Compiling signals-cache-probe", build("two", "2"))
            (root / "two/src/main.rs").write_text('fn main() { println!("3"); }\n')
            build("two", "3")


if __name__ == "__main__":
    unittest.main()
