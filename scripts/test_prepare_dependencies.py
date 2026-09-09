"""Web bundles admit verified dependencies, never arbitrary checkout binaries."""

from contextlib import contextmanager
from pathlib import Path
import hashlib
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
        (self.inputs / "dependencies.lock.json").write_text("locked")
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
        self.assertEqual((stage / "dependencies.lock.json").read_text(), "locked")
        self.assertEqual((stage / "dependency-manifests/musl-arm64musl.json").read_text(), "arm64musl")

    def test_missing_host_is_not_replaced_with_a_dependency_artifact(self):
        (self.source / "targets/x64mac/libhost.a").unlink()
        with patch.object(bundle_platforms, "verified_web_dependencies", self.verified):
            with self.assertRaisesRegex(ValueError, "missing or invalid web host"):
                bundle_platforms.stage_web_inputs(self.source, self.root / "stage")
        self.assertFalse((self.root / "stage").exists())

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

    def test_gui_example_package_includes_only_pinned_sources_and_rejects_drift(self):
        source = self.root / "package"
        source.mkdir()
        module = b'module []\n'
        (source / "main.roc").write_bytes(module)
        (source / "untracked.roc").write_bytes(b"untrusted")
        (source / "upstream.json").write_text(json.dumps({"files_sha256": {
            "main.roc": hashlib.sha256(module).hexdigest(),
        }}))
        destination = self.root / "download/vendor/package"
        bundle_platforms.stage_example_package(source, destination)
        bundle_platforms.stage_example_package(source, destination)
        self.assertEqual((destination / "main.roc").read_bytes(), module)
        self.assertFalse((destination / "untracked.roc").exists())
        (source / "main.roc").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "upstream pin"):
            bundle_platforms.stage_example_package(source, self.root / "refused")
        self.assertFalse((self.root / "refused").exists())


if __name__ == "__main__":
    unittest.main()
