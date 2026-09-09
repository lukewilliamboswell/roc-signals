"""Host archives bind exact owned outputs to the source used by consumers."""

import json
from contextlib import contextmanager
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import ExitStack
import prepare_dependencies

import gui_host_artifacts
import bundle_platforms
import release_gui_hosts as release_dependencies
from dependency_archive import write_archive
from dependency_artifacts import unpack_verified
from gui_host_artifacts import pack_host, source_fingerprint, validate_host


class HostArtifactTests(unittest.TestCase):
    def test_bundle_combines_verified_host_with_external_only_local_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "platform-gui/targets/x64glibc"
            local.mkdir(parents=True)
            for name in ("crt1.o", "crti.o", "crtn.o", "libxkbcommon.so", "libxkbcommon-x11.so",
                         "libgcc_s.so", "libm.so", "libc.so", "libutil.so", "libfreetype.so"):
                (local / name).write_bytes(b"local external input")
            (root / "crates/gpui-host").mkdir(parents=True)
            (root / "crates/gpui-host/LICENSE-GPUI").write_text("license")
            (root / "examples-gui/counter").mkdir(parents=True)
            (root / "examples-gui/counter/main.roc").write_text("fixture")

            def admitted(identity, files):
                inputs = root / identity
                for name, data in files.items():
                    path = inputs / identity / "targets/x64glibc" / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                (inputs / "dependencies.lock.json").write_text(json.dumps({
                    "schema_version": 1, "artifacts": {identity: {"sha256": identity}}}))
                return inputs

            host = admitted("gui-host-x64glibc", {
                name: b"verified host" for name in gui_host_artifacts.HOST_FILES["x64glibc"]})
            freetype = admitted("freetype-x64glibc", {"libfreetype.so": b"verified FreeType"})

            keyboard = admitted("xkbcommon-x64glibc", {"libxkbcommon.so": b"verified keyboard", "libxkbcommon-x11.so": b"verified X11"})

            glibc = admitted("glibc-x64glibc", {name: b"verified CRT" for name in bundle_platforms.GLIBC_LIBRARIES})
            unwind = admitted("unwind-x64glibc", {"libunwind.a": b"verified unwinder"})

            @contextmanager
            def verified(inputs):
                yield inputs

            def bundle(command, *, cwd, **kwargs):
                self.assertEqual((cwd / "targets/x64glibc/libengine.a").read_bytes(), b"verified host")
                self.assertEqual((cwd / "targets/x64glibc/libfreetype.so").read_bytes(), b"verified FreeType")
                self.assertFalse((cwd / "targets/x64glibc/libutil.so").exists())
                receipt = json.loads((cwd / "dependencies.lock.json").read_text())
                self.assertEqual(set(receipt["artifacts"]), {"gui-host-x64glibc", "freetype-x64glibc", "xkbcommon-x64glibc", "glibc-x64glibc", "unwind-x64glibc"})
                archive = Path(command[command.index("--output-dir") + 1]) / "platform.tar.zst"
                return subprocess.CompletedProcess(command, 0, stdout=f"Created: {archive}\n")

            with patch.object(bundle_platforms, "ROOT", root), \
                    patch.object(bundle_platforms, "prepare_platform"), \
                    patch.object(bundle_platforms, "verified_hosts", side_effect=lambda *a: verified(host)), \
                    patch.object(bundle_platforms, "verified_freetype", side_effect=lambda: verified(freetype)), \
                    patch.object(bundle_platforms, "verified_xkbcommon", side_effect=lambda: verified(keyboard)), \
                    patch.object(bundle_platforms, "verified_glibc", side_effect=lambda: verified(glibc)), \
                    patch.object(bundle_platforms, "verified_unwind", side_effect=lambda: verified(unwind)), \
                    patch.object(bundle_platforms, "stage_example_package"), \
                    patch.object(bundle_platforms, "gui_examples", return_value=[]), \
                    patch.object(bundle_platforms.subprocess, "run", side_effect=bundle) as compiler, \
                    patch.object(sys, "argv", ["bundle", "--package", "gui", "--no-build",
                                              "--prebuilt-host-lock", str(root / "host.lock"),
                                              "--output-dir", str(root / "out")]):
                bundle_platforms.main()
                self.assertEqual(compiler.call_count, 1)
                (local / "libengine.a").write_bytes(b"ambiguous local host")
                with self.assertRaisesRegex(ValueError, "missing or invalid GUI host output"):
                    bundle_platforms.main()
                self.assertEqual(compiler.call_count, 1)

    def test_candidate_dependencies_are_fresh_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stale = root / "platform-gui/targets/x64glibc"
            stale.mkdir(parents=True)
            (stale / "libc.so").write_bytes(b"untrusted checkout")
            destination = root / "candidate/x64glibc"
            names = ("install_freetype", "install_glibc", "install_unwind", "install_xkbcommon")
            with ExitStack() as stack:
                mocks = [stack.enter_context(patch.object(prepare_dependencies, name,
                         return_value={"artifacts": {name: {"sha256": name}}})) for name in names]
                gui_host_artifacts.stage_candidate_dependencies("x64glibc", destination, root)
                for mock in mocks:
                    mock.assert_called_once_with(destination, lock=root / "dependencies.lock.json")
                self.assertFalse((destination / "libc.so").exists())
                receipt = json.loads((destination / "dependencies.lock.json").read_text())
                self.assertEqual(set(receipt["artifacts"]), set(names))
                with self.assertRaises(FileExistsError):
                    gui_host_artifacts.stage_candidate_dependencies("x64glibc", destination, root)
            failed = root / "failed/x64win"
            with patch.object(prepare_dependencies, "install_windows_imports", side_effect=ValueError("invalid signature")):
                with self.assertRaisesRegex(ValueError, "signature"):
                    gui_host_artifacts.stage_candidate_dependencies("x64win", failed, root)
                self.assertFalse((failed / "dependencies.lock.json").exists())

    def test_release_requires_selected_target_and_attested_source_pair(self):
        environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_REPOSITORY": release_dependencies.REPOSITORY, "GITHUB_SHA": "a" * 40}
        for target, failure in ((target, failure) for target in release_dependencies.POLICY["targets"]
                                for failure in ("missing-source", "wrong-source", "missing-license",
                                                "signature", "source-signature", None)):
            with self.subTest(target=target, failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / f"gui-host-sources-{target}.tar"
                write_archive(source, {"schema_version": 1, "name": "gui-host-sources", "target": target},
                              {"licenses/gui-host-sources/source.txt": b"original source"})
                companion = {"name": "gui-host-sources", "target": target, "asset": source.name,
                             "sha256": release_dependencies.sha256(source), "size": source.stat().st_size}
                if failure == "wrong-source":
                    companion["sha256"] = "0" * 64
                files = {f"targets/{target}/{name}": b"tested host" for name in gui_host_artifacts.HOST_FILES[target]}
                files.update({f"licenses/gui-host/{name}": b"notice fixture"
                              for name in release_dependencies.POLICY["licenses"]})
                files["licenses/gui-host/NOTICE.json"] = json.dumps({"source_companion": companion}).encode()
                if failure == "missing-license":
                    del files["licenses/gui-host/LICENSE-GPUI"]
                write_archive(root / f"gui-host-{target}.tar", {
                    "schema_version": 1, "name": "gui-host", "target": target,
                    "source_fingerprint": "expected"}, files)
                if failure == "missing-source":
                    source.unlink()
                # Composition/admission tests validate actual notice contents. Here the
                # seam is exact candidate pairing and independent signature admission.
                with patch.object(release_dependencies.subprocess, "check_output", return_value="a" * 40), \
                        patch.object(gui_host_artifacts, "source_fingerprint", return_value="expected"), \
                        patch.object(gui_host_artifacts, "validate_host"), \
                        patch.object(gui_host_artifacts, "validate_publication_notices") as admit, \
                        patch.object(release_dependencies, "verify_archive") as verifier:
                    if failure == "signature":
                        verifier.side_effect = ValueError("invalid signature")
                    elif failure == "source-signature":
                        verifier.side_effect = [None, ValueError("invalid source signature")]
                    if failure:
                        with self.assertRaises(ValueError):
                            release_dependencies.prepare(root, "deps-gui-host-1", environment, [target])
                        self.assertFalse((root / "dependencies.lock.json").exists())
                        admit.assert_not_called()
                    else:
                        release_dependencies.prepare(root, "deps-gui-host-1", environment, [target])
                        lock = json.loads((root / "dependencies.lock.json").read_text())
                        self.assertEqual(set(lock["artifacts"]), {f"gui-host-{target}", f"gui-host-sources-{target}"})
                        self.assertEqual(verifier.call_count, 2)
                        admit.assert_called_once()
                        for entry in lock["artifacts"].values():
                            self.assertEqual(entry["signer_workflow"], gui_host_artifacts.WORKFLOW)
                            self.assertEqual(entry["source_sha"], "a" * 40)
        for targets in (["unknown"], ["x64glibc", "x64glibc"], []):
            with self.assertRaisesRegex(ValueError, "eligible"):
                release_dependencies.prepare(Path("unused"), "deps-gui-host-1", environment, targets)

    def test_host_only_target_is_not_a_complete_platform(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "x64mingw"
            target.mkdir()
            for name in gui_host_artifacts.HOST_FILES["x64mingw"]:
                (target / name).write_bytes(b"host")
            with self.assertRaisesRegex(ValueError, "link dependency"):
                bundle_platforms.validate_gui_link_inputs(root)
            for name in prepare_dependencies.windows_gnu_files():
                (target / name).write_bytes(b"verified dependency")
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
