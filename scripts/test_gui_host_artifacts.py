"""Host archives bind exact owned outputs to the source used by consumers."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import gui_host_artifacts
import bundle_platforms
from dependency_artifacts import unpack_verified
from gui_host_artifacts import pack_host, source_fingerprint, validate_host


class HostArtifactTests(unittest.TestCase):
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
