"""Build receipts reject source drift and changed host-owned outputs."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import host_build_identity as identity


class HostBuildIdentityTests(unittest.TestCase):
    def test_mac_shader_receipt_binds_selected_gpui_outputs_and_host(self):
        from cargo_build_evidence import macos_shaders
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "gpui/src/platform/mac/shaders.metal"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"original shader")
            target = root / "target"
            out = target / "build/gpui/out"
            out.mkdir(parents=True)
            for name in ("scene.h", "shaders.air", "shaders.metallib"):
                (out / name).write_bytes(name.encode())
            metadata = {"packages": [{"name": "gpui", "version": "0.2.2", "id": "gpui-id",
                                      "manifest_path": str(root / "gpui/Cargo.toml")}]}
            messages = json.dumps({"reason": "build-script-executed", "package_id": "gpui-id", "out_dir": str(out)}).encode()
            tools = {"tools": {name: {"sha256": "1" * 64} for name in ("metal", "metallib")}}
            shader = macos_shaders(metadata, messages, target, tools, "2" * 64)
            files = {name: {"sha256": "2" * 64, "size": 1} for name in identity.HOST_FILES["arm64mac"]}
            receipt = {"schema_version": 1, "target": "arm64mac", "source_fingerprint": "source",
                       "outputs": files, "macos": shader}
            host = {"sha256": "2" * 64, "size": 1}
            identity.validate_outputs(receipt, "arm64mac", "source", host)
            shader["cargo_host_sha256"] = "3" * 64
            with self.assertRaisesRegex(ValueError, "captured host"):
                identity.validate_outputs(receipt, "arm64mac", "source", host)
            with self.assertRaisesRegex(ValueError, "fresh GPUI"):
                macos_shaders(metadata, b"", target, tools, host["sha256"])
            (out / "shaders.metallib").unlink()
            with self.assertRaises(FileNotFoundError):
                macos_shaders(metadata, messages, target, tools, host["sha256"])

    def test_every_native_output_is_bound_before_packaging(self):
        for target in ("x64glibc", "x64win"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = root / "evidence"
                evidence.mkdir()
                outputs = {name: ("original " + name).encode() for name in identity.HOST_FILES[target]}
                for name, data in outputs.items():
                    (root / name).write_bytes(data)
                host_name = identity.HOST_FILES[target][0]
                host = {"name": host_name, "sha256": hashlib.sha256(outputs[host_name]).hexdigest(),
                        "size": len(outputs[host_name])}
                (evidence / "evidence.json").write_text(json.dumps({"source_fingerprint": "built-source", "host": host}))
                with patch.object(identity, "source_fingerprint", return_value="built-source"):
                    identity.record_outputs(root, target, root, evidence, "built-source")
                receipt = json.loads((evidence / "build.json").read_text())
                identity.validate_outputs(receipt, target, "built-source", host, outputs)
                for name in outputs:
                    with self.subTest(output=name), self.assertRaisesRegex(ValueError, "captured build receipt"):
                        identity.validate_outputs(receipt, target, "built-source", host,
                                                  dict(outputs, **{name: b"replacement"}))
                with self.assertRaisesRegex(ValueError, "source or target"):
                    identity.validate_outputs(receipt, target, "later-source", host, outputs)

    def test_source_drift_leaves_no_completed_build_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(identity, "source_fingerprint", return_value="new-source"):
                with self.assertRaisesRegex(ValueError, "changed during"):
                    identity.record_outputs(root, "x64glibc", root, root, "built-source")
            self.assertFalse((root / "build.json").exists())


if __name__ == "__main__":
    unittest.main()
