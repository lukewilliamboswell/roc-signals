"""Host archives bind exact owned outputs to the source used by consumers."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import gui_host_artifacts
import bundle_platforms
import release_dependencies
from dependency_archive import write_archive
from dependency_artifacts import unpack_verified
from gui_host_artifacts import pack_host, source_fingerprint, validate_host


class HostArtifactTests(unittest.TestCase):
    def test_release_requires_every_target_and_matching_source(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        for failure in ("missing-target", "wrong-source", "missing-license", "signature", None):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for target, names in gui_host_artifacts.HOST_FILES.items():
                    if failure == "missing-target" and target == "arm64mac":
                        continue
                    files = {f"targets/{target}/{name}": b"tested host" for name in names}
                    files["licenses/gui-host/LICENSE"] = b"platform license"
                    if failure != "missing-license":
                        files["licenses/gui-host/LICENSE-GPUI"] = b"GPUI license"
                    write_archive(root / f"gui-host-{target}.tar", {
                        "schema_version": 1, "name": "gui-host", "target": target,
                        "source_fingerprint": "wrong" if failure == "wrong-source" else "expected",
                    }, files)
                with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), \
                        patch.object(gui_host_artifacts, "source_fingerprint", return_value="expected"), \
                        patch.object(release_dependencies, "verify_archive") as verifier:
                    if failure == "signature":
                        verifier.side_effect = ValueError("invalid signature")
                    if failure:
                        with self.assertRaises(ValueError):
                            release_dependencies.prepare(root, "deps-gui-host-1", environment, "gui-host")
                        self.assertFalse((root / "dependencies.lock.json").exists())
                    else:
                        release_dependencies.prepare(root, "deps-gui-host-1", environment, "gui-host")
                        lock = json.loads((root / "dependencies.lock.json").read_text())
                        self.assertEqual(set(lock["artifacts"]), {
                            "gui-host-" + target for target in gui_host_artifacts.HOST_FILES})
                        self.assertEqual(verifier.call_count, 3)
                        for entry in lock["artifacts"].values():
                            self.assertEqual(entry["signer_workflow"], gui_host_artifacts.WORKFLOW)
                            self.assertEqual(entry["source_sha"], "a" * 40)

    def test_host_only_target_is_not_a_complete_platform(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "x64win"
            target.mkdir()
            for name in gui_host_artifacts.HOST_FILES["x64win"]:
                (target / name).write_bytes(b"host")
            with self.assertRaisesRegex(ValueError, "link dependency"):
                bundle_platforms.validate_gui_link_inputs(root)
            (target / "advapi32.lib").write_bytes(b"verified import")
            bundle_platforms.validate_gui_link_inputs(root)

    def test_foreign_host_producer_is_rejected_before_download(self):
        entry = {"name": "gui-host", "target": "x64glibc", "repository": "other/repository",
                 "signer_workflow": gui_host_artifacts.WORKFLOW}
        with patch.object(gui_host_artifacts, "read_lock", return_value={"artifacts": {
                "gui-host-x64glibc": entry}}), patch.object(gui_host_artifacts, "materialize") as download:
            with self.assertRaisesRegex(ValueError, "this repository's GUI host producer"):
                with gui_host_artifacts.verified_hosts(Path("unused"), Path("unused-cache")):
                    self.fail("foreign producer admitted")
        download.assert_not_called()

    def test_source_identity_and_owned_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / "crates/gpui-host").mkdir(parents=True)
            (root / "crates/gpui-host/LICENSE-GPUI").write_text("GPUI license")
            (root / "LICENSE").write_text("platform license")
            (root / "src").mkdir()
            source = root / "src/engine.zig"
            source.write_text("original engine\n")
            subprocess.run(["git", "-C", str(root), "add", "src", "crates", "LICENSE"], check=True)
            def commit():
                subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c",
                                "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                                "commit", "--quiet", "-am", "fixture"], check=True)
            commit()
            fingerprint = source_fingerprint(root)
            (root / "README.md").write_text("documentation change")
            self.assertEqual(source_fingerprint(root), fingerprint)
            subprocess.run(["git", "-C", str(root), "config", "core.autocrlf", "true"], check=True)
            source.write_bytes(b"original engine\r\n")
            self.assertEqual(source_fingerprint(root), fingerprint)
            inputs = root / "inputs"
            inputs.mkdir()
            for name in ("libsignals_gpui_host.a", "libengine.a", "libfreetype.so", "injected.a"):
                (inputs / name).write_bytes(name.encode())
            archive = pack_host("x64glibc", inputs, root / "host.tar", root)
            tree = root / "extracted"
            unpack_verified(archive, {"name": "gui-host", "target": "x64glibc"}, tree)
            validate_host(tree, "x64glibc", fingerprint)
            inventory = json.loads((tree / "dependency.json").read_text())["files"]
            self.assertNotIn("targets/x64glibc/libfreetype.so", inventory)
            self.assertNotIn("targets/x64glibc/injected.a", inventory)
            source.write_text("changed engine")
            with self.assertRaisesRegex(ValueError, "clean committed"):
                source_fingerprint(root)
            commit()
            with self.assertRaisesRegex(ValueError, "does not match"):
                validate_host(tree, "x64glibc", source_fingerprint(root))


if __name__ == "__main__":
    unittest.main()
