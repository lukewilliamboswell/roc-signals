"""Local property campaigns and CI must begin with the same regression seeds."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fuzz


class CorpusSeedTests(unittest.TestCase):
    def test_committed_inputs_join_existing_seeds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.multiple(fuzz, WORK_DIR=root / "work", REGRESSION_DIR=root / "regressions"):
                target = fuzz.Target("structural", "test")
                target.regression_dir.mkdir(parents=True)
                (target.regression_dir / "nested").write_bytes(b"nested fixture")
                (target.regression_dir / "README.md").write_text("not an input")
                target.corpus_dir.mkdir(parents=True)
                (target.corpus_dir / "local").write_bytes(b"local fixture")
                fuzz.seed_corpus(target)
                fuzz.seed_corpus(target)
                self.assertEqual(
                    {path.name: path.read_bytes() for path in target.corpus_dir.iterdir()},
                    {"regression-nested": b"nested fixture", "local": b"local fixture"},
                )
                (target.regression_dir / "later").write_bytes(b"new regression")
                fuzz.seed_corpus(target)
                self.assertEqual((target.corpus_dir / "regression-later").read_bytes(), b"new regression")

    def test_empty_target_gets_a_minimal_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.multiple(fuzz, WORK_DIR=root / "work", REGRESSION_DIR=root / "regressions"):
                target = fuzz.Target("empty", "test")
                fuzz.seed_corpus(target)
                self.assertEqual((target.corpus_dir / "seed").read_bytes(), target.seed)


if __name__ == "__main__":
    unittest.main()
