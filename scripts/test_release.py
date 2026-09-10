"""The combined release publishes and tests exact immutable platform bytes."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release


class ReleaseTests(unittest.TestCase):
    def manifest_fixture(self, root):
        assets = {}
        for kind, name in (("web", "WebHash.tar.zst"), ("gui", "GuiHash.tar.zst"),
                           ("examples", release.EXAMPLES)):
            path = root / name
            path.write_bytes(kind.encode())
            assets[kind] = release.record(path, "0.2.0-rc2")
        manifest = {
            "schema_version": 2,
            "version": "0.2.0-rc2",
            "source_sha": "a" * 40,
            "compiler_pin": "nightly-2026-09-04-c125b82",
            "max_transitive_mb": release.MAX_TRANSITIVE_MB,
            "assets": assets,
            "inputs": {"web_hosts": {}, "gui_hosts": {}, "linker_inputs": {}},
            "provenance": {
                "signer_workflow": release.REPOSITORY + "/.github/workflows/release.yml",
                "source_ref": "refs/heads/main",
            },
        }
        (root / release.MANIFEST).write_text(json.dumps(manifest))
        (root / "release-notes.md").write_text("notes")
        return manifest

    def test_manifest_requires_two_distinct_platforms_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest_fixture(root)
            self.assertEqual(release.read_manifest(root), manifest)
            (root / "GuiHash.tar.zst").write_bytes(b"replacement")
            with self.assertRaisesRegex(ValueError, "differs from its manifest"):
                release.read_manifest(root)
            manifest = self.manifest_fixture(root)
            manifest["assets"]["gui"] = manifest["assets"]["web"]
            (root / release.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "distinct platform"):
                release.read_manifest(root)

    def test_manifest_rejects_missing_inputs_and_unexpected_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest_fixture(root)
            manifest["inputs"].pop("web_hosts")
            (root / release.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "input locks"):
                release.read_manifest(root)
            manifest = self.manifest_fixture(root)
            (root / "unreviewed").write_text("no")
            with self.assertRaisesRegex(ValueError, "unexpected asset"):
                release.read_manifest(root)

    def test_examples_keep_web_and_gui_roots_distinct_and_include_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            web = root / "examples-web/demo"
            gui = root / "examples-gui/demo"
            vendor = root / "vendor/unicode"
            for directory in (web, gui, vendor):
                directory.mkdir(parents=True)
            (web / "main.roc").write_text(
                'app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-web/main.roc" }'
            )
            (gui / "main.roc").write_text(
                'app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }'
            )
            (gui / "theme.json").write_bytes(b"{\"theme\":true}")
            (vendor / "Unicode.roc").write_text("module []")
            web_example = SimpleNamespace(source=Path("examples-web/demo/main.roc"))
            archive = root / release.EXAMPLES

            def files(directory):
                return tuple(path for path in directory.rglob("*") if path.is_file())

            with patch.object(release, "ROOT", root), \
                    patch.object(release, "web_examples", return_value=(web_example,)), \
                    patch.object(release, "gui_examples", return_value=(gui,)), \
                    patch.object(release, "tracked_files", side_effect=files), \
                    patch.object(release.bundle_browser, "runtime_files", return_value={"signals.mjs": b"runtime"}):
                release.write_examples(archive, "nightly-2026-09-04-c125b82", "https://release/Web.tar.zst",
                                       "https://release/Gui.tar.zst")
            with zipfile.ZipFile(archive) as packed:
                self.assertIn('platform "https://release/Web.tar.zst"',
                              packed.read("examples-web/demo/main.roc").decode())
                self.assertIn('platform "https://release/Gui.tar.zst"',
                              packed.read("examples-gui/demo/main.roc").decode())
                self.assertEqual(packed.read("examples-gui/demo/theme.json"), b"{\"theme\":true}")

    def test_archive_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as packed:
                packed.writestr("../escaped", "no")
            with self.assertRaisesRegex(ValueError, "unsafe example archive"):
                release.extract_examples(archive, root / "out")
            self.assertFalse((root / "escaped").exists())

    def test_every_release_compiler_command_raises_the_fat_package_budget(self):
        with patch.object(release.driver, "run") as run:
            release.roc_run("roc", "build", Path("example/main.roc"), "--target=x64glibc")
        command = run.call_args.args[0]
        self.assertIn(f"--max-transitive-mb={release.MAX_TRANSITIVE_MB}", command)

    def test_prepare_invokes_only_the_no_build_two_package_bundler(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "releases/0.2.0-rc2.md").write_text("candidate")
            output = root / "release"
            web_lock = root / "web.lock"
            gui_lock = root / "gui.lock"
            web_lock.write_text("{}")
            gui_lock.write_text("{}")
            calls = []

            def bundle(command, **kwargs):
                calls.append(command)
                bundle_root = Path(command[command.index("--output-dir") + 1])
                for kind, name in (("web", "WebHash.tar.zst"), ("gui", "GuiHash.tar.zst")):
                    path = bundle_root / kind / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(kind.encode())
                (bundle_root / "bundles.json").write_text(json.dumps({
                    "web": "web/WebHash.tar.zst", "gui": "gui/GuiHash.tar.zst",
                }))
                return subprocess.CompletedProcess(command, 0)

            def examples(path, *args):
                with zipfile.ZipFile(path, "x") as packed:
                    packed.writestr("README.md", "examples")

            with patch.object(release, "ROOT", root), \
                    patch.object(release, "clean_source_sha", return_value="a" * 40), \
                    patch.object(release, "validate_roots", return_value="nightly-2026-09-04-c125b82"), \
                    patch.object(release, "verify_compiler"), \
                    patch.object(release, "read_lock", return_value={"schema_version": 1, "artifacts": {}}), \
                    patch.object(release, "write_examples", side_effect=examples), \
                    patch.object(release.subprocess, "run", side_effect=bundle):
                release.prepare("0.2.0-rc2", output, "roc", web_lock, gui_lock)
            self.assertEqual(len(calls), 1)
            command = list(map(os.fspath, calls[0]))
            self.assertIn("--package", command)
            self.assertIn("all", command)
            self.assertIn("--no-build", command)
            self.assertIn("--prebuilt-web-host-lock", command)
            self.assertIn("--prebuilt-host-lock", command)
            self.assertFalse(any(tool in command for tool in ("zig", "cargo", "rustc")))

    def test_publication_requires_exact_tested_main_context(self):
        manifest = {"source_sha": "a" * 40}
        environment = {
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": release.REPOSITORY,
            "GITHUB_SHA": "a" * 40,
        }
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(release.subprocess, "check_output", return_value="a" * 40 + "\n"):
            release.require_publish_context(manifest)
            for key in environment:
                changed = dict(environment, **{key: "wrong"})
                with self.subTest(key=key), patch.dict(os.environ, changed, clear=True), \
                        self.assertRaisesRegex(ValueError, "explicit main"):
                    release.require_publish_context(manifest)

    def test_workflow_has_one_publisher_and_no_host_toolchain_setup(self):
        workflow = (release.ROOT / ".github/workflows/release.yml").read_text()
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("./.github/actions/setup-roc", workflow)
        self.assertNotIn("./.github/actions/setup-toolchain", workflow)
        self.assertNotIn("zig", workflow.lower())
        self.assertNotIn("cargo", workflow.lower())
        self.assertFalse((release.ROOT / ".github/workflows/gui-release.yml").exists())


if __name__ == "__main__":
    unittest.main()
