"""GUI discovery must not silently omit an app or its semantic specs."""

from pathlib import Path
import tempfile
import unittest

import gui_suite


class GuiDiscoveryTests(unittest.TestCase):
    def test_repository_apps_all_have_registered_specs(self):
        self.assertTrue(gui_suite.examples())

    def test_unregistered_app_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "examples-gui"
            (directory / "extra").mkdir(parents=True)
            (directory / "extra/main.roc").write_text("app")
            (directory / "examples.toml").write_text('schema_version = 1\n[[examples]]\nslug = "counter"\n')
            with self.assertRaisesRegex(ValueError, "differs from app directories"):
                gui_suite.examples(root)

    def test_registered_app_without_specs_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "examples-gui"
            (directory / "counter/specs").mkdir(parents=True)
            (directory / "counter/main.roc").write_text("app")
            (directory / "examples.toml").write_text('schema_version = 1\n[[examples]]\nslug = "counter"\n')
            with self.assertRaisesRegex(ValueError, "no .*scm files"):
                gui_suite.examples(root)

    def test_internal_fixture_without_specs_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "test/gui/presentation"
            (directory / "specs").mkdir(parents=True)
            (directory / "main.roc").write_text("app")
            with self.assertRaisesRegex(ValueError, "no .*scm files"):
                gui_suite.fixtures(root)

    def test_no_internal_fixtures_is_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(gui_suite.fixtures(Path(temporary)), ())


if __name__ == "__main__":
    unittest.main()
