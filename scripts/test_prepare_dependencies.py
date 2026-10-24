"""Platform bundles admit verified dependencies, never arbitrary checkout binaries."""

from contextlib import contextmanager
from pathlib import Path
import json
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bundle_platforms
import prepare_dependencies


class DependencyStagingTests(unittest.TestCase):
    def test_bundle_merges_dependency_receipts_and_rejects_conflicting_identity(self):
        stage = self.root / "merged"
        stage.mkdir()
        for identity in ("web-host-x64musl", "web-host-arm64musl"):
            (self.inputs / identity).mkdir()
            (self.inputs / "dependencies.lock.json").write_text(json.dumps({
                "schema_version": 1, "artifacts": {identity: {"sha256": identity}},
            }))
            bundle_platforms.stage_dependency_inputs(self.inputs, (identity,), stage)
        receipt = json.loads((stage / "dependencies.lock.json").read_text())
        self.assertEqual(set(receipt["artifacts"]), {"web-host-x64musl", "web-host-arm64musl"})
        original = (stage / "dependencies.lock.json").read_bytes()
        (self.inputs / "dependencies.lock.json").write_text(json.dumps({
            "schema_version": 1, "artifacts": {"web-host-x64musl": {"sha256": "different"}},
        }))
        with self.assertRaisesRegex(ValueError, "conflicting dependency receipt"):
            bundle_platforms.stage_dependency_inputs(self.inputs, ("web-host-x64musl",), stage)
        self.assertEqual((stage / "dependencies.lock.json").read_bytes(), original)

    def test_compiled_dependency_and_host_binaries_are_not_tracked(self):
        tracked = subprocess.check_output([
            "git", "ls-files", "--", "*.a", "*.lib", "*.o", "*.obj", "*.wasm",
            "*.so", "*.so.*", "*.dylib",
        ], cwd=prepare_dependencies.ROOT, text=True)
        self.assertEqual(tracked, "", "publish compiled link inputs through dependency or platform releases")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "platform"
        self.inputs = self.root / "verified"
        self.inputs.mkdir()
        (self.inputs / "dependencies.lock.json").write_text(json.dumps({"schema_version": 1, "artifacts": {}}))
        for target in ("x64mac", "arm64mac", "x64musl", "arm64musl", "wasm32"):
            directory = self.source / "targets" / target
            directory.mkdir(parents=True)
            (directory / ("host.wasm" if target == "wasm32" else "libhost.a")).write_bytes(b"current host")
        for target in ("x64musl", "arm64musl"):
            artifact = self.inputs / f"musl-{target}"
            directory = artifact / "targets" / target
            directory.mkdir(parents=True)
            (directory / "libc.a").write_bytes(b"verified libc")
            (directory / "crt1.o").write_bytes(b"verified startup")
            license_dir = artifact / "licenses/musl"
            license_dir.mkdir(parents=True)
            (license_dir / "COPYRIGHT").write_text("copyright")
            (artifact / "dependency.json").write_text(target)

    @contextmanager
    def verified(self, *args):
        yield self.inputs

    def test_bundler_ignores_stale_and_injected_checkout_libraries(self):
        targets = self.source / "targets"
        (targets / "x64musl/libc.a").write_bytes(b"untrusted local replacement")
        (targets / "x64mac/unexpected.a").write_bytes(b"injected")
        stage = self.root / "stage"
        with patch.object(bundle_platforms, "verified_web_dependencies", self.verified):
            bundle_platforms.stage_web_inputs(self.source, stage)
        self.assertEqual((stage / "targets/x64musl/libc.a").read_bytes(), b"verified libc")
        self.assertFalse((stage / "targets/x64mac/unexpected.a").exists())
        self.assertEqual(json.loads((stage / "dependencies.lock.json").read_text()),
                         {"schema_version": 1, "artifacts": {}})
        self.assertEqual((stage / "dependency-manifests/musl-arm64musl.json").read_text(), "arm64musl")

    def test_missing_host_is_not_replaced_with_a_dependency_artifact(self):
        (self.source / "targets/x64mac/libhost.a").unlink()
        with patch.object(bundle_platforms, "verified_web_dependencies", self.verified):
            with self.assertRaisesRegex(ValueError, "missing or invalid web host"):
                bundle_platforms.stage_web_inputs(self.source, self.root / "stage")
        self.assertFalse((self.root / "stage").exists())

    def test_web_bundle_uses_only_the_complete_verified_host_set_when_locked(self):
        host_inputs = self.root / "verified-hosts"
        artifacts = {}
        for target, filename in bundle_platforms.WEB_HOST_OUTPUTS.items():
            identity = "web-host-" + target
            artifacts[identity] = {"target": target, "sha256": identity}
            output = host_inputs / identity / "targets" / target / filename
            output.parent.mkdir(parents=True)
            output.write_bytes(("released " + target).encode())
            (host_inputs / identity / "dependency.json").write_text(identity)
        (host_inputs / "dependencies.lock.json").write_text(json.dumps({
            "schema_version": 1, "artifacts": artifacts,
        }))

        @contextmanager
        def verified_hosts(*args):
            yield host_inputs

        stage = self.root / "locked-stage"
        with patch.object(bundle_platforms, "verified_web_hosts", verified_hosts), \
                patch.object(bundle_platforms, "verified_web_dependencies", self.verified):
            bundle_platforms.stage_web_inputs(self.source, stage, self.root / "web-host.lock.json")
        for target, filename in bundle_platforms.WEB_HOST_OUTPUTS.items():
            self.assertEqual((stage / "targets" / target / filename).read_bytes(),
                             ("released " + target).encode())
        receipt = json.loads((stage / "dependencies.lock.json").read_text())
        self.assertEqual(set(receipt["artifacts"]), set(artifacts))

    def test_failed_verification_never_falls_back_to_checkout_libc(self):
        (self.source / "targets/x64musl/libc.a").write_bytes(b"local libc")
        with patch.object(bundle_platforms, "verified_web_dependencies", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                bundle_platforms.stage_web_inputs(self.source, self.root / "stage")
        self.assertFalse((self.root / "stage").exists())

    def test_development_install_uses_the_same_verified_inputs(self):
        with patch.object(prepare_dependencies, "verified_web_dependencies", self.verified):
            prepare_dependencies.install_web_dependencies(platform=self.source)
        self.assertEqual((self.source / "targets/arm64musl/crt1.o").read_bytes(), b"verified startup")
        self.assertEqual((self.source / "targets/arm64musl/libhost.a").read_bytes(), b"current host")


if __name__ == "__main__":
    unittest.main()
