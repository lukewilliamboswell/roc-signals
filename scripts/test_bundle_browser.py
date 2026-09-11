"""Standalone imports must work using only the files we ship to consumers."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bundle_browser import bundle
from build_js_framework_benchmark import copy_runtime


class BrowserBundleTests(unittest.TestCase):
    def test_benchmark_runtime_includes_effect_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            copy_runtime(root)
            for name in ("effect_runner.mjs", "effect_http.mjs"):
                self.assertTrue((root / name).is_file(), name)
            result = subprocess.run(
                ["node", "--input-type=module", "-e", "await import('./signals.mjs');"],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_isolated_import_and_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "runtime.zip"
            bundle(archive)
            with zipfile.ZipFile(archive) as package:
                package.extractall(root / "public")
            public = root / "public"
            manifest = json.loads((public / "signals-runtime.json").read_text())
            self.assertTrue(manifest["roc_version"].startswith("nightly-"))
            for name, digest in manifest["sha256"].items():
                self.assertEqual(hashlib.sha256((public / name).read_bytes()).hexdigest(), digest)
            result = subprocess.run(
                ["node", "--input-type=module", "-e",
                 "import { mountSignalsApp } from './signals.mjs'; "
                 "if (typeof mountSignalsApp !== 'function') throw new Error('missing mount');"],
                cwd=public, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            second = root / "second.zip"
            bundle(second)
            self.assertEqual(archive.read_bytes(), second.read_bytes())


if __name__ == "__main__":
    unittest.main()
