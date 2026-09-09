"""Build receipts reject source drift and changed host-owned outputs."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import host_build_identity as identity


class HostBuildIdentityTests(unittest.TestCase):
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
