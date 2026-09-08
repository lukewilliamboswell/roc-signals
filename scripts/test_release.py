"""Release validation must distinguish downloads from local source success."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release
import release_followup
import site_release
import toolchain
from compiler_pins import replace_pin


class ReleaseTests(unittest.TestCase):
    def test_starters_include_transitive_example_runtime_imports(self):
        files = release.bundle_browser.runtime_files(("example_tasks.mjs", "service_ops_charts.mjs"))
        self.assertIn("vendor/ops_chart.mjs", files)
        self.assertIn("conduit_backend.mjs", files)
        self.assertIn("signals.mjs", files)

    def test_platform_rebinding_ignores_comments_and_module_bodies(self):
        source = '# platform "comment"\napp [main] { pf: platform "old", roc: "0.1.0" }\nmain = "platform \\\"body\\\""\n'
        self.assertEqual(toolchain.replace_platform(source, "new"), source.replace('platform "old"', 'platform "new"'))
        self.assertEqual(toolchain.replace_platform('module []\nvalue = "platform"', "new"), 'module []\nvalue = "platform"')
        with self.assertRaises(ValueError):
            toolchain.replace_platform('app [main] { a: platform "one", b: platform "two" }', "new")

    def test_compiler_pin_replacement_preserves_both_dependency_urls(self):
        source = '# header\napp [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "https://a/p.tar.zst", lib: "https://b/l.tar.zst" }\nmain = "roc: fake"\n'
        self.assertEqual(replace_pin(source, "nightly-2026-09-07-14d9829"), source.replace("nightly-2026-09-04-c125b82", "nightly-2026-09-07-14d9829"))

    def test_published_urls_reject_local_floating_and_unrelated_downloads(self):
        for url in ["../../platform/main.roc", "http://127.0.0.1/a.tar.zst", release.RELEASE_BASE + "/latest/a.tar.zst",
                    release.RELEASE_BASE + "/0.2.0-rc1/../a.tar.zst", "https://example.com/0.2.0/a.tar.zst"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                release.release_base(url)
        url = release.RELEASE_BASE + "/0.2.0-rc1/Ab123.tar.zst"
        self.assertEqual(release.release_base(url), url.rsplit("/", 1)[0])

    def test_unpublished_examples_cannot_fall_back_to_local_bundle(self):
        with patch.object(release.driver, "bundle_platform") as bundle, patch.object(release, "verify_compiler"), self.assertRaises(ValueError):
            # This remains a local URL even after the repository publishes its baseline.
            with patch.object(release, "platform_url", return_value="../../platform/main.roc"):
                release.check_published("roc")
        bundle.assert_not_called()

    def test_compiler_identity_rejects_wrong_binary(self):
        pin = "nightly-2026-09-04-c125b82"
        with patch.object(toolchain.subprocess, "check_output", return_value="Roc compiler version release-c125b82abcd"):
            toolchain.verify_compiler("roc", pin)
        with patch.object(toolchain.subprocess, "check_output", return_value="Roc compiler version debug-12345678"), self.assertRaises(ValueError):
            toolchain.verify_compiler("roc", pin)

    def test_cache_is_isolated_and_restored_after_failure(self):
        with patch.dict(os.environ, ROC_CACHE_DIR="original", XDG_CACHE_HOME="packages"):
            with self.assertRaises(RuntimeError):
                with release.fresh_cache(Path("isolated")):
                    self.assertEqual(os.environ["ROC_CACHE_DIR"], "isolated")
                    self.assertEqual(os.environ["XDG_CACHE_HOME"], "isolated")
                    raise RuntimeError()
            self.assertEqual(os.environ["ROC_CACHE_DIR"], "original")
            self.assertEqual(os.environ["XDG_CACHE_HOME"], "packages")

    def manifest_fixture(self, root):
        manifest = {"schema_version": 1, "version": "0.2.0-rc1", "source_sha": "a" * 40, "compiler_pin": "nightly-2026-09-04-c125b82", "assets": {}}
        for kind, name in {"platform": "Ab123.tar.zst", "browser": "signals-browser.zip", "starters": "signals-starters.zip"}.items():
            path = root / name
            path.write_bytes(kind.encode())
            manifest["assets"][kind] = {"name": name, "url": release.RELEASE_BASE + "/0.2.0-rc1/" + name, "sha256": release.digest(path)}
        (root / "signals-release.json").write_text(json.dumps(manifest))
        return manifest

    def test_corrupt_or_repointed_artifacts_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = self.manifest_fixture(root)
            self.assertEqual(release.read_manifest(root), original)
            (root / "Ab123.tar.zst").write_bytes(b"replacement")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                release.read_manifest(root)
            original = self.manifest_fixture(root)
            original["assets"]["platform"]["url"] = "https://example.com/another.tar.zst"
            (root / "signals-release.json").write_text(json.dumps(original))
            with self.assertRaisesRegex(ValueError, "URL disagrees"):
                release.read_manifest(root)

    def test_archive_escape_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../escaped", "no")
            with self.assertRaisesRegex(ValueError, "unsafe archive"):
                release.extract(archive, root / "out")
            self.assertFalse((root / "escaped").exists())

    def test_explicit_runtime_never_falls_back_to_checkout_executor(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["node", "scripts/browser/mount_wasm_example.mjs", "missing.wasm", "--runtime-dir", directory], cwd=release.ROOT, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(str(Path(directory) / "example_tasks.mjs"), result.stderr)

    def test_selected_roots_cover_every_public_example(self):
        self.assertEqual(toolchain.validate_roots(), toolchain.development_pin())

    def test_release_writes_require_explicit_tested_main_dispatch(self):
        sha = "a" * 40
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "NIGHTLY_VALIDATION": "false", "GITHUB_SHA": sha}
        with patch.dict(os.environ, environment), patch.object(release_followup.subprocess, "check_output", return_value=sha):
            release_followup.require_release_context({"source_sha": sha})
            for key, value in [("GITHUB_EVENT_NAME", "pull_request"), ("NIGHTLY_VALIDATION", "true"),
                               ("GITHUB_REF", "refs/heads/automation/roc-nightly"), ("GITHUB_SHA", "b" * 40)]:
                with self.subTest(key=key), patch.dict(os.environ, {key: value}), self.assertRaises(ValueError):
                    release_followup.require_release_context({"source_sha": sha})

    def test_followup_requires_current_sha_and_every_required_job(self):
        for stale, missing_job in [(True, False), (False, True), (False, False)]:
            statuses = []
            def api(path, payload=None):
                if "/statuses/" in path:
                    statuses.append(payload)
                    return {}
                if path.endswith("/dispatches"):
                    return {"workflow_run_id": 1 if "ci.yml" in path else 2}
                if "/git/ref/heads/" in path:
                    return {"object": {"sha": "moved" if stale else "candidate"}}
                if "/jobs?" in path:
                    names = release_followup.CHECKS - ({"Published examples"} if missing_job else set())
                    return {"jobs": [{"name": name, "conclusion": "success"} for name in names]}
                return {"head_sha": "candidate", "head_branch": "release/examples", "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}
            with patch.object(release_followup, "api", side_effect=api):
                if stale or missing_job:
                    with self.assertRaises(ValueError):
                        release_followup.validate("release/examples", "candidate")
                    self.assertNotIn("success", [status["state"] for status in statuses])
                else:
                    release_followup.validate("release/examples", "candidate")
                    self.assertEqual({status["context"] for status in statuses if status["state"] == "success"}, release_followup.CHECKS)

    def test_site_assembly_preserves_versioned_pages_and_platform_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.manifest_fixture(root)
            archive = root / "signals-site.zip"
            with zipfile.ZipFile(archive, "w") as site:
                site.writestr("current/index.html", "landing")
                site.writestr("versions/0.2.0-rc1/index.html", "new")
                site.writestr("versions/0.1.1/index.html", "old")
                site.writestr("platform/OldHash.tar.zst", "old archive")
            manifest["site"] = {"name": archive.name, "url": release.RELEASE_BASE + "/0.2.0-rc1/" + archive.name, "sha256": release.digest(archive)}
            (root / "signals-release.json").write_text(json.dumps(manifest))
            output = root / "dist"
            site_release.assemble(root, output)
            self.assertEqual((output / "index.html").read_text(), "landing")
            self.assertEqual((output / "versions/0.1.1/index.html").read_text(), "old")
            self.assertEqual((output / "platform/OldHash.tar.zst").read_text(), "old archive")


if __name__ == "__main__":
    unittest.main()
