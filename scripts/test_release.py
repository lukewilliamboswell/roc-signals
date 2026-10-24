"""The release publishes and tests exact immutable platform bytes."""

import ast
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
    def test_controller_text_io_is_explicitly_utf8(self):
        tree = ast.parse(Path(release.__file__).read_text(encoding="utf-8"))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute)
                 and node.func.attr in {"read_text", "write_text"}]
        self.assertTrue(calls)
        for call in calls:
            with self.subTest(line=call.lineno):
                encoding = next((keyword.value for keyword in call.keywords
                                 if keyword.arg == "encoding"), None)
                self.assertIsInstance(encoding, ast.Constant)
                self.assertEqual(encoding.value, "utf-8")

    def manifest_fixture(self, root):
        assets = {}
        for kind, name in (("web", "WebHash.tar.zst"), ("examples", release.EXAMPLES)):
            path = root / name
            path.write_bytes(kind.encode())
            assets[kind] = release.record(path, "0.2.0-rc2")
        manifest = {
            "schema_version": 3,
            "version": "0.2.0-rc2",
            "source_sha": "a" * 40,
            "compiler_pin": "nightly-2026-09-04-c125b82",
            "max_transitive_mb": release.MAX_TRANSITIVE_MB,
            "assets": assets,
            "inputs": {"web_hosts": {}, "linker_inputs": {}},
            "provenance": {
                "signer_workflow": release.REPOSITORY + "/.github/workflows/release.yml",
                "source_ref": "refs/heads/main",
            },
        }
        (root / release.MANIFEST).write_text(json.dumps(manifest))
        (root / "release-notes.md").write_text("notes")
        return manifest

    def test_manifest_requires_exactly_the_web_platform_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest_fixture(root)
            self.assertEqual(release.read_manifest(root), manifest)
            (root / "WebHash.tar.zst").write_bytes(b"replacement")
            with self.assertRaisesRegex(ValueError, "differs from its manifest"):
                release.read_manifest(root)
            manifest = self.manifest_fixture(root)
            manifest["assets"]["extra"] = manifest["assets"]["web"]
            (root / release.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "exactly the web platform"):
                release.read_manifest(root)
            manifest = self.manifest_fixture(root)
            manifest["schema_version"] = 2
            (root / release.MANIFEST).write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "unsupported platform release manifest"):
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

    def test_examples_bind_the_web_platform_and_include_pages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            web = root / "examples-web/demo"
            web.mkdir(parents=True)
            (web / "main.roc").write_text(
                'app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-web/main.roc" }'
            )
            (web / "data.json").write_bytes(b"{\"rows\":true}")
            web_example = SimpleNamespace(source=Path("examples-web/demo/main.roc"))
            archive = root / release.EXAMPLES

            def files(directory):
                return tuple(path for path in directory.rglob("*") if path.is_file())

            with patch.object(release, "ROOT", root), \
                    patch.object(release, "web_examples", return_value=(web_example,)), \
                    patch.object(release, "tracked_files", side_effect=files), \
                    patch.object(release.bundle_browser, "runtime_files", return_value={"signals.mjs": b"runtime"}):
                release.write_examples(archive, "nightly-2026-09-04-c125b82", "https://release/Web.tar.zst")
            with zipfile.ZipFile(archive) as packed:
                self.assertIn('platform "https://release/Web.tar.zst"',
                              packed.read("examples-web/demo/main.roc").decode())
                self.assertEqual(packed.read("examples-web/demo/data.json"), b"{\"rows\":true}")
                self.assertEqual(packed.read("browser/signals.mjs"), b"runtime")
                page = packed.read("examples-web/demo/index.html").decode()
                self.assertIn('import { createPublicExampleFetch }', page)
                self.assertIn('fetchImpl: createPublicExampleFetch()', page)
                self.assertNotIn('taskHandler', page)

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
            release.roc_run("roc", "build", Path("example/main.roc"), "--target=x64musl")
        command = run.call_args.args[0]
        self.assertIn(f"--max-transitive-mb={release.MAX_TRANSITIVE_MB}", command)

    def test_prepare_invokes_only_the_no_build_web_bundler(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "releases").mkdir()
            (root / "releases/0.2.0-rc2.md").write_text("candidate")
            output = root / "release"
            web_lock = root / "web.lock"
            web_lock.write_text("{}")
            calls = []

            def bundle(command, **kwargs):
                calls.append(command)
                bundle_root = Path(command[command.index("--output-dir") + 1])
                bundle_root.mkdir(parents=True, exist_ok=True)
                (bundle_root / "WebHash.tar.zst").write_bytes(b"web")
                (bundle_root / "bundles.json").write_text(json.dumps({"web": "WebHash.tar.zst"}))
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
                release.prepare("0.2.0-rc2", output, "roc", web_lock)
            self.assertEqual(len(calls), 1)
            command = list(map(os.fspath, calls[0]))
            self.assertIn("--no-build", command)
            self.assertIn("--prebuilt-web-host-lock", command)
            self.assertNotIn("zig", command)
            manifest = release.read_manifest(output)
            self.assertEqual(set(manifest["assets"]), {"web", "examples"})
            self.assertEqual(set(manifest["inputs"]), {"web_hosts", "linker_inputs"})

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

    def test_example_archive_ships_the_complete_browser_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / release.EXAMPLES
            with patch.object(release, "web_examples", return_value=()):
                release.write_examples(archive, "nightly-2026-10-23-18478ff", "https://release/Web.tar.zst")
            with zipfile.ZipFile(archive) as packed:
                names = set(packed.namelist())
        for name in release.bundle_browser.runtime_files():
            self.assertIn("browser/" + name, names)

    def test_only_a_semver_prerelease_is_published_as_a_prerelease(self):
        self.assertEqual(release.channel_flags("0.2.0-rc3"), ["--prerelease", "--latest=false"])
        self.assertEqual(release.channel_flags("0.2.0"), ["--latest"])

    def test_release_notes_record_source_compiler_assets_and_inputs(self):
        lock = {"schema_version": 1, "artifacts": {"musl-x64musl": {
            "release": "deps-musl-1.2.6", "asset": "musl-x64musl.tar", "sha256": "b" * 64}}}
        notes = release.provenance_notes({
            "source_sha": "a" * 40,
            "compiler_pin": "nightly-2026-10-23-18478ff",
            "assets": {"web": {"url": "https://release/Web.tar.zst", "sha256": "c" * 64}},
            "inputs": {"linker_inputs": lock},
        })
        for expected in ("a" * 40, "nightly-2026-10-23-18478ff", "https://release/Web.tar.zst",
                         "c" * 64, "deps-musl-1.2.6", "b" * 64):
            self.assertIn(expected, notes)

    def test_workflow_has_one_publisher_and_no_host_toolchain_setup(self):
        workflow = (release.ROOT / ".github/workflows/release.yml").read_text()
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("./.github/actions/setup-roc", workflow)
        self.assertNotIn("zig", workflow.lower())
        # The release tasks run in Blueprint's release environment, which must
        # not gain Zig directly or by extending the development environment.
        self.assertIn("blueprint run release", workflow)
        blueprint = (release.ROOT / "Blueprint.roc").read_text()
        environment = next(line for line in blueprint.splitlines() if 'Environment("release"' in line)
        self.assertNotIn("zig", environment)
        self.assertNotIn('Extend("dev")', environment)


if __name__ == "__main__":
    unittest.main()
