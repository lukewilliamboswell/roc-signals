"""The mini-CI entry point validates its compiler before running checks."""

from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.path.insert(0, str(Path(__file__).resolve().parent))
LOADER = SourceFileLoader("minici_entrypoint", str(Path(__file__).with_name("minici")))
SPEC = spec_from_loader(LOADER.name, LOADER)
MINICI = module_from_spec(SPEC)
LOADER.exec_module(MINICI)


class MiniCiTests(unittest.TestCase):
    def test_gui_pipeline_threads_one_owned_output_through_every_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ci-owned"
            with patch.dict(MINICI.os.environ, {MINICI.GUI_OUTPUT_ENV: str(output)}, clear=True), \
                    patch.object(MINICI, "run") as run, \
                    patch.object(MINICI.platform, "system", return_value="Darwin"):
                MINICI.gui()
                (output / "gui").mkdir(parents=True)
                MINICI.gui_smoke()
                MINICI.gui_scenarios()

            gui_command = run.call_args_list[1].args
            smoke_command = run.call_args_list[2].args
            scenario_command = run.call_args_list[3].args
            self.assertEqual(gui_command[-2:], ("--output-dir", str(output)))
            self.assertEqual(smoke_command[-2:], ("--directory", str(output / "gui")))
            self.assertIn(str(output / "gui-scenarios"), scenario_command)

    def test_gui_consumer_requires_an_explicit_producer_output(self):
        with patch.dict(MINICI.os.environ, {}, clear=True), \
                self.assertRaisesRegex(SystemExit, MINICI.GUI_OUTPUT_ENV):
            MINICI.gui_output()

    def test_hosted_target_omits_full_local_campaigns(self):
        with patch.object(MINICI, "shared_sources") as shared, \
                patch.object(MINICI, "run") as run:
            MINICI.hosted()
        shared.assert_called_once_with()
        command = run.call_args.args
        self.assertIn("native", command)
        self.assertIn("fuzz", command)
        self.assertNotIn("fault", command)
        self.assertNotIn("wasm-fault", command)
        self.assertNotIn("bench", command)
        self.assertNotIn("bundle", command)
        self.assertNotIn("coverage", command)

    def test_compiler_mismatch_stops_before_selected_target(self):
        target = Mock()
        mismatch = ValueError("compiler does not match nightly-test: debug")
        with patch.dict(MINICI.TARGETS, {"smoke": target}, clear=True), \
                patch.dict(MINICI.os.environ, {"ROC_BIN": "roc"}, clear=True), \
                patch.object(MINICI.shutil, "which", return_value="/tools/roc"), \
                patch.object(MINICI, "validate_roots", return_value="nightly-test"), \
                patch.object(MINICI, "verify_compiler", side_effect=mismatch), \
                patch.object(sys, "argv", ["minici", "smoke"]):
            with self.assertRaisesRegex(SystemExit, "requires Roc nightly-test"):
                MINICI.main()
        target.assert_not_called()

    def test_selection_does_not_require_the_compiler(self):
        target = Mock()
        with patch.dict(MINICI.TARGETS, {"selection": target}, clear=True), \
                patch.object(MINICI, "ensure_pinned_roc") as preflight, \
                patch.object(sys, "argv", ["minici", "selection"]):
            MINICI.main()
        preflight.assert_not_called()
        target.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
