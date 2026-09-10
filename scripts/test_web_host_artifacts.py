"""Web host releases contain exact outputs and use narrow content identities."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from dependency_artifacts import unpack_verified
import release_web_hosts
import web_host_artifacts as hosts


class WebHostArtifactTests(unittest.TestCase):
    def fixture(self, root):
        subprocess.run(["git", "init", "--quiet", root], check=True)
        subprocess.run(["git", "-C", root, "config", "user.email", "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", root, "config", "user.name", "Test"], check=True)
        for name in (*hosts.SOURCE_PATHS, "LICENSE"):
            path = root / name
            if name == "LICENSE" or Path(name).suffix:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
        subprocess.run(["git", "-C", root, "add", "."], check=True)
        subprocess.run(["git", "-C", root, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"], check=True)
        for target, filename in hosts.OUTPUTS.items():
            path = root / "platform-web/targets" / target / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())

    def test_pack_has_exact_inventory_and_narrow_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            before = hosts.source_fingerprint(root)
            archive = hosts.pack("wasm32", root / "platform-web", root / "host.tar", root)
            tree = root / "tree"
            unpack_verified(archive, {"name": "web-host", "target": "wasm32"}, tree)
            hosts.validate(tree, "wasm32", before)
            (root / "platform-web/main.roc").parent.mkdir(exist_ok=True)
            (root / "platform-web/main.roc").write_text("changed API")
            self.assertEqual(hosts.source_fingerprint(root), before)
            (root / "src/wasm_host.zig").write_text("changed host")
            with self.assertRaisesRegex(ValueError, "clean committed"):
                hosts.source_fingerprint(root)

    def test_fingerprint_rejects_non_regular_git_entries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            source = root / "src/wasm_host.zig"
            source.unlink()
            source.symlink_to("native_host.zig")
            subprocess.run(["git", "-C", root, "add", "src/wasm_host.zig"], check=True)
            subprocess.run([
                "git", "-C", root, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "symlink",
            ], check=True)
            with self.assertRaisesRegex(ValueError, "regular files"):
                hosts.source_fingerprint(root)

    def test_release_lock_records_archive_and_input_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            candidate = root / "candidate"
            candidate.mkdir()
            fingerprint = hosts.source_fingerprint(root)
            for target in hosts.OUTPUTS:
                hosts.pack(target, root / "platform-web", candidate / ("web-host-" + target + ".tar"), root)
            environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                           "GITHUB_REPOSITORY": hosts.REPOSITORY, "GITHUB_SHA": "a" * 40}
            with patch.object(release_web_hosts.subprocess, "check_output", return_value="a" * 40), \
                    patch.object(release_web_hosts, "source_fingerprint", return_value=fingerprint), \
                    patch.object(release_web_hosts, "validate"):
                release_web_hosts.prepare(candidate, "deps-web-hosts-1", environment)
            entries = json.loads((candidate / "dependencies.lock.json").read_text())["artifacts"]
            self.assertEqual(set(entries), set(hosts.IDENTITIES))
            self.assertTrue(all(entry["input_fingerprint"] == fingerprint for entry in entries.values()))
            self.assertTrue(all(entry["signer_workflow"] == hosts.WORKFLOW for entry in entries.values()))


if __name__ == "__main__":
    unittest.main()
