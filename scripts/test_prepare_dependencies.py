"""Platform bundles admit verified dependencies, never arbitrary checkout binaries."""

from contextlib import contextmanager
from pathlib import Path
import hashlib
import json
import shutil
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bundle_platforms
import build_gui
import prepare_dependencies


class DependencyStagingTests(unittest.TestCase):
    def test_windows_gnu_header_preserves_complete_provider_order(self):
        import re
        header = (prepare_dependencies.ROOT / "platform-gui/main.roc").read_text()
        block = re.search(r'x64mingw:\s*\{\s*inputs:\s*\[(.*?)\]', header, re.S).group(1)
        inputs = re.findall(r'"([^"\n]+)"|\b(app)\b', block)
        observed = [left or right for left, right in inputs]
        files = prepare_dependencies.windows_gnu_files()
        expected = [files[0], "libsignals_gpui_host.a", "libengine.a", "signals.res", "app", *files[1:]]
        self.assertEqual(observed, expected)
        self.assertEqual(len(files), 361)
        self.assertEqual(files[21], "ole32.lib")

    def test_windows_gnu_release_admission_requires_source_inventory(self):
        from build_windows_system_imports import REPRODUCTION as imports
        from build_windows_gnu_runtime import REPRODUCTION as runtime
        inventories = {}
        for identity, sources, extras in (
                (prepare_dependencies.WINDOWS_SYSTEM_IMPORTS, imports, ("source.tar.xz", "coverage.json")),
                (prepare_dependencies.WINDOWS_GNU_RUNTIME, runtime, ("source.tar.xz",))):
            kind = identity.removesuffix("-x64mingw")
            recipe = json.loads((prepare_dependencies.ROOT / "dependencies" / (kind + ".json")).read_bytes())
            names = recipe.get("files") or [dll.rsplit(".", 1)[0] + ".lib" for dll in recipe["dlls"]]
            paths = {"targets/x64mingw/" + name for name in names}
            paths.update("licenses/" + kind + "/" + name for name in recipe["notices_sha256"])
            paths.update("sources/" + kind + "/" + name for name in (*sources, *extras))
            inventories[identity] = {"source": recipe, "files": dict.fromkeys(paths, {})}
        def materialize(lock, identities, cache, destination):
            self.assertEqual(identities, prepare_dependencies.WINDOWS_GNU_ARTIFACTS)
            for identity, manifest in inventories.items():
                tree = destination / identity
                tree.mkdir(parents=True)
                (tree / "dependency.json").write_text(json.dumps(manifest))
            inventory = destination / prepare_dependencies.WINDOWS_SYSTEM_IMPORTS / prepare_dependencies.WINDOWS_GNU_INVENTORY
            inventory.parent.mkdir(parents=True)
            inventory.write_bytes((prepare_dependencies.ROOT / "dependencies/windows-system-imports/inventory.json").read_bytes())
        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_windows_gnu() as inputs:
                self.assertEqual(len(prepare_dependencies.windows_gnu_inventory(inputs)), 340)
            files = inventories[prepare_dependencies.WINDOWS_GNU_RUNTIME]["files"]
            for missing in ("targets/x64mingw/unwind.lib", "licenses/windows-gnu-runtime/LICENSE-LLVM",
                            "sources/windows-gnu-runtime/source.tar.xz"):
                entry = files.pop(missing)
                with self.assertRaisesRegex(ValueError, "incomplete or unexpected"):
                    with prepare_dependencies.verified_windows_gnu():
                        pass
                files[missing] = entry

    def test_windows_gnu_bundle_ignores_mutable_dependencies_and_retains_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, inputs, stage = root / "local", root / "verified", root / "bundle"
            source.mkdir()
            inputs.mkdir()
            stage.mkdir()
            host_names = ("libsignals_gpui_host.a", "libengine.a", "signals.res")
            for name in host_names:
                (source / name).write_bytes(name.encode())
            (source / "kernel32.lib").write_bytes(b"untrusted local stub")
            (source / "unknown.lib").write_bytes(b"untracked library")
            receipt = {"schema_version": 1, "artifacts": {identity: {"verified": identity}
                       for identity in prepare_dependencies.WINDOWS_GNU_ARTIFACTS}}
            (inputs / "dependencies.lock.json").write_text(json.dumps(receipt))
            runtime = set(json.loads((prepare_dependencies.ROOT / "dependencies/windows-gnu-runtime.json").read_bytes())["files"])
            for identity in prepare_dependencies.WINDOWS_GNU_ARTIFACTS:
                target = inputs / identity / "targets/x64mingw"
                target.mkdir(parents=True)
                for name in prepare_dependencies.windows_gnu_files():
                    if (name in runtime) == (identity == prepare_dependencies.WINDOWS_GNU_RUNTIME):
                        (target / name).write_bytes(b"verified " + name.encode())
                (inputs / identity / "dependency.json").write_text(json.dumps({"identity": identity}))
                notice = inputs / identity / "licenses" / identity / "LICENSE"
                notice.parent.mkdir(parents=True)
                notice.write_bytes(b"original notice")
            @contextmanager
            def verified():
                yield inputs
            with patch.object(bundle_platforms, "verified_windows_gnu", verified):
                bundle_platforms.stage_windows_gnu_inputs(source, stage)
            target = stage / "targets/x64mingw"
            self.assertEqual({path.name for path in target.iterdir()}, set(host_names) | set(prepare_dependencies.windows_gnu_files()))
            self.assertEqual((target / "kernel32.lib").read_bytes(), b"verified kernel32.lib")
            self.assertEqual(json.loads((stage / "dependencies.lock.json").read_bytes()), receipt)
            for identity in prepare_dependencies.WINDOWS_GNU_ARTIFACTS:
                self.assertTrue((stage / "dependency-manifests" / (identity + ".json")).is_file())
                self.assertEqual((stage / "licenses" / identity / "LICENSE").read_bytes(), b"original notice")
            bundle_platforms.validate_gui_link_inputs(stage / "targets")
            (target / "unwind.lib").unlink()
            with self.assertRaisesRegex(ValueError, "link dependency"):
                bundle_platforms.validate_gui_link_inputs(stage / "targets")

    def test_windows_gnu_installer_verifies_before_changing_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "target"
            destination.mkdir()
            (destination / "crt2.obj").write_bytes(b"original")
            with patch.object(prepare_dependencies, "verified_windows_gnu", side_effect=ValueError("untrusted signer")):
                with self.assertRaisesRegex(ValueError, "untrusted signer"):
                    prepare_dependencies.install_windows_gnu(destination)
            self.assertEqual((destination / "crt2.obj").read_bytes(), b"original")

    def test_runtime_consumer_inventory_matches_corrected_producer_contract(self):
        import release_dependencies
        for kind, libraries, licenses, sources in (
            ("glibc", prepare_dependencies.GLIBC_LIBRARIES, prepare_dependencies.GLIBC_LICENSES,
             prepare_dependencies.GLIBC_SOURCE_FILES),
            ("unwind", ("libunwind.a",), ("LICENSE.TXT", "LICENSE-ZIG"), prepare_dependencies.UNWIND_SOURCE_FILES),
        ):
            with self.subTest(kind=kind):
                policy = release_dependencies.KINDS[kind]
                self.assertEqual(set(libraries), set(policy["files"]))
                self.assertEqual(set(licenses), set(policy["licenses"]))
                self.assertEqual({"sources/" + kind + "/" + name for name in sources}, set(policy["extra_files"]))

    def test_unwind_admission_requires_complete_release_inventory(self):
        expected = {"targets/x64glibc/libunwind.a", "licenses/unwind/LICENSE.TXT", "licenses/unwind/LICENSE-ZIG"}
        expected.update("sources/unwind/" + name for name in prepare_dependencies.UNWIND_SOURCE_FILES)
        files = dict.fromkeys(expected, {})

        def materialize(lock, identities, cache, destination):
            self.assertEqual(identities, (prepare_dependencies.UNWIND,))
            artifact = destination / prepare_dependencies.UNWIND
            artifact.mkdir(parents=True)
            (artifact / "dependency.json").write_text(json.dumps({"files": files}))

        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_unwind() as admitted:
                self.assertTrue(admitted.is_dir())
            for missing in sorted(expected):
                with self.subTest(missing=missing):
                    files = dict.fromkeys(expected - {missing}, {})
                    with self.assertRaisesRegex(ValueError, "incomplete or unexpected LLVM"):
                        with prepare_dependencies.verified_unwind():
                            self.fail("incomplete inventory admitted")
            files = dict.fromkeys(expected | {"targets/x64glibc/libgcc_s.so"}, {})
            with self.assertRaisesRegex(ValueError, "incomplete or unexpected LLVM"):
                with prepare_dependencies.verified_unwind():
                    self.fail("unexpected library admitted")

    def test_unwind_admission_failure_preserves_existing_library_and_prevents_build(self):
        destination = self.root / "linux"
        destination.mkdir()
        library = destination / "libunwind.a"
        library.write_bytes(b"previous")
        with patch.object(prepare_dependencies, "verified_unwind", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                prepare_dependencies.install_unwind(destination)
        self.assertEqual(library.read_bytes(), b"previous")
        with patch.object(build_gui, "host_target", return_value="x64glibc"), patch.object(
                build_gui, "install_freetype", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_glibc", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_unwind", side_effect=ValueError("untrusted signer")), patch.object(
                build_gui.subprocess, "run") as compiler:
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                build_gui.build()
        compiler.assert_not_called()

    def test_unwind_copy_failure_preserves_existing_library_and_cleans_temporary(self):
        destination = self.root / "linux"
        destination.mkdir()
        library = destination / "libunwind.a"
        library.write_bytes(b"previous")
        with patch.object(prepare_dependencies, "verified_unwind", self.verified):
            with self.assertRaises(FileNotFoundError):
                prepare_dependencies.install_unwind(destination)
            self.assertEqual(library.read_bytes(), b"previous")
            self.assertEqual(list(destination.iterdir()), [library])
            target = self.inputs / prepare_dependencies.UNWIND / "targets/x64glibc"
            target.mkdir(parents=True)
            (target / "libunwind.a").write_bytes(b"verified")
            receipt = prepare_dependencies.install_unwind(destination)
        self.assertEqual(library.read_bytes(), b"verified")
        self.assertEqual(list(destination.iterdir()), [library])
        self.assertEqual(receipt, {"schema_version": 1, "artifacts": {}})

    def test_glibc_admission_requires_all_link_inputs_notices_and_sources(self):
        expected = {"targets/x64glibc/" + name for name in prepare_dependencies.GLIBC_LIBRARIES}
        expected.update("licenses/glibc/" + name for name in prepare_dependencies.GLIBC_LICENSES)
        expected.update("sources/glibc/" + name for name in prepare_dependencies.GLIBC_SOURCE_FILES)
        files = dict.fromkeys(expected, {})

        def materialize(lock, identities, cache, destination):
            self.assertEqual(identities, (prepare_dependencies.GLIBC,))
            artifact = destination / prepare_dependencies.GLIBC
            artifact.mkdir(parents=True)
            (artifact / "dependency.json").write_text(json.dumps({"files": files}))

        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_glibc() as admitted:
                self.assertTrue(admitted.is_dir())
            for missing in sorted(expected):
                with self.subTest(missing=missing):
                    files = dict.fromkeys(expected - {missing}, {})
                    with self.assertRaisesRegex(ValueError, "incomplete or unexpected glibc"):
                        with prepare_dependencies.verified_glibc():
                            self.fail("incomplete inventory was admitted")

    def test_glibc_verification_failure_preserves_inputs_and_prevents_build(self):
        destination = self.root / "linux"
        destination.mkdir()
        for name in prepare_dependencies.GLIBC_LIBRARIES:
            (destination / name).write_bytes(b"previous verified bytes")
        with patch.object(prepare_dependencies, "verified_glibc", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                prepare_dependencies.install_glibc(destination)
        for name in prepare_dependencies.GLIBC_LIBRARIES:
            self.assertEqual((destination / name).read_bytes(), b"previous verified bytes")
        with patch.object(build_gui, "host_target", return_value="x64glibc"), patch.object(
                build_gui, "install_freetype", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_glibc", side_effect=ValueError("untrusted signer")), patch.object(
                build_gui.subprocess, "run") as compiler:
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                build_gui.build()
        compiler.assert_not_called()

    def test_glibc_install_stages_all_files_before_replacing_any(self):
        target = self.inputs / prepare_dependencies.GLIBC / "targets/x64glibc"
        target.mkdir(parents=True)
        destination = self.root / "linux"
        destination.mkdir()
        for name in prepare_dependencies.GLIBC_LIBRARIES:
            (destination / name).write_bytes(b"previous")
        for name in prepare_dependencies.GLIBC_LIBRARIES[:-1]:
            (target / name).write_bytes(b"verified CRT")
        with patch.object(prepare_dependencies, "verified_glibc", self.verified):
            with self.assertRaises(FileNotFoundError):
                prepare_dependencies.install_glibc(destination)
            for name in prepare_dependencies.GLIBC_LIBRARIES:
                self.assertEqual((destination / name).read_bytes(), b"previous")
            (target / prepare_dependencies.GLIBC_LIBRARIES[-1]).write_bytes(b"verified CRT")
            prepare_dependencies.install_glibc(destination)
        for name in prepare_dependencies.GLIBC_LIBRARIES:
            self.assertEqual((destination / name).read_bytes(), b"verified CRT")
        self.assertEqual({p.name for p in destination.iterdir()}, set(prepare_dependencies.GLIBC_LIBRARIES))

    def test_xkbcommon_admission_requires_both_libraries_and_license(self):
        expected = {"targets/x64glibc/" + name for name in prepare_dependencies.XKBCOMMON_LIBRARIES}
        expected.add("licenses/xkbcommon/LICENSE")
        files = dict.fromkeys(expected, {})

        def materialize(lock, identities, cache, destination):
            self.assertEqual(identities, (prepare_dependencies.XKBCOMMON,))
            artifact = destination / prepare_dependencies.XKBCOMMON
            artifact.mkdir(parents=True)
            (artifact / "dependency.json").write_text(json.dumps({"files": files}))

        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_xkbcommon() as admitted:
                self.assertTrue(admitted.is_dir())
            for missing in sorted(expected):
                with self.subTest(missing=missing):
                    files = dict.fromkeys(expected - {missing}, {})
                    with self.assertRaisesRegex(ValueError, "incomplete or unexpected xkbcommon"):
                        with prepare_dependencies.verified_xkbcommon():
                            self.fail("incomplete inventory was admitted")

    def test_xkbcommon_verification_failure_preserves_inputs_and_prevents_build(self):
        destination = self.root / "linux"
        destination.mkdir()
        for name in prepare_dependencies.XKBCOMMON_LIBRARIES:
            (destination / name).write_bytes(b"previous verified bytes")
        with patch.object(prepare_dependencies, "verified_xkbcommon", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                prepare_dependencies.install_xkbcommon(destination)
        for name in prepare_dependencies.XKBCOMMON_LIBRARIES:
            self.assertEqual((destination / name).read_bytes(), b"previous verified bytes")
        with patch.object(build_gui, "host_target", return_value="x64glibc"), patch.object(
                build_gui, "install_freetype", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_glibc", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_unwind", return_value={"artifacts": {}}), patch.object(
                build_gui, "install_xkbcommon", side_effect=ValueError("untrusted signer")), patch.object(
                build_gui.subprocess, "run") as compiler:
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                build_gui.build()
        compiler.assert_not_called()

    def test_xkbcommon_install_stages_both_files_before_replacing_either(self):
        target = self.inputs / prepare_dependencies.XKBCOMMON / "targets/x64glibc"
        target.mkdir(parents=True)
        destination = self.root / "linux"
        destination.mkdir()
        for name in prepare_dependencies.XKBCOMMON_LIBRARIES:
            (destination / name).write_bytes(b"previous")
        (target / "libxkbcommon.so").write_bytes(b"verified core")
        with patch.object(prepare_dependencies, "verified_xkbcommon", self.verified):
            with self.assertRaises(FileNotFoundError):
                prepare_dependencies.install_xkbcommon(destination)
            for name in prepare_dependencies.XKBCOMMON_LIBRARIES:
                self.assertEqual((destination / name).read_bytes(), b"previous")
            (target / "libxkbcommon-x11.so").write_bytes(b"verified x11")
            prepare_dependencies.install_xkbcommon(destination)
        self.assertEqual((destination / "libxkbcommon.so").read_bytes(), b"verified core")
        self.assertEqual((destination / "libxkbcommon-x11.so").read_bytes(), b"verified x11")
        self.assertEqual({p.name for p in destination.iterdir()}, set(prepare_dependencies.XKBCOMMON_LIBRARIES))

    def test_gui_bundle_replaces_stale_keyboard_libraries_with_verified_release(self):
        source = self.root / "platform-gui/targets/x64glibc"
        source.mkdir(parents=True)
        for name in ("libsignals_gpui_host.a", "libengine.a", "libfreetype.so", *prepare_dependencies.XKBCOMMON_LIBRARIES, *prepare_dependencies.GLIBC_LIBRARIES, "crti.o", "crtn.o", "libdl.so", "injected.a", "libunwind.a", "libgcc_s.so"):
            (source / name).write_bytes(b"checkout bytes")

        @contextmanager
        def verified(identity, files):
            directory = self.root / identity
            artifact = directory / identity
            artifact.mkdir(parents=True)
            for name, contents in files.items():
                path = artifact / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            (artifact / "dependency.json").write_text(json.dumps({"files": list(files)}))
            (directory / "dependencies.lock.json").write_text(json.dumps({
                "schema_version": 1, "artifacts": {identity: {"sha256": identity}},
            }))
            yield directory

        def inspect_bundle(command, cwd, **kwargs):
            stage = Path(cwd)
            for name in prepare_dependencies.XKBCOMMON_LIBRARIES:
                self.assertEqual((stage / "targets/x64glibc" / name).read_bytes(), b"verified " + name.encode())
            self.assertEqual((stage / "licenses/xkbcommon/LICENSE").read_bytes(), b"upstream notice")
            for name in prepare_dependencies.GLIBC_LIBRARIES:
                self.assertEqual((stage / "targets/x64glibc" / name).read_bytes(), b"verified CRT " + name.encode())
            self.assertEqual((stage / "sources/glibc/source.tar.xz").read_bytes(), b"corresponding sources")
            for name in ("crti.o", "crtn.o", "libdl.so", "injected.a", "libgcc_s.so"):
                self.assertFalse((stage / "targets/x64glibc" / name).exists())
            receipt = json.loads((stage / "dependencies.lock.json").read_text())
            self.assertEqual(set(receipt["artifacts"]), {prepare_dependencies.FREETYPE, prepare_dependencies.XKBCOMMON, prepare_dependencies.GLIBC, prepare_dependencies.UNWIND})
            self.assertEqual((stage / "targets/x64glibc/libunwind.a").read_bytes(), b"verified unwinder")
            self.assertEqual((stage / "licenses/unwind/LICENSE.TXT").read_bytes(), b"LLVM terms")
            self.assertEqual((stage / "sources/unwind/source.tar.xz").read_bytes(), b"unwinder sources")
            for name in prepare_dependencies.GLIBC_LICENSES:
                self.assertEqual((stage / "licenses/glibc" / name).read_bytes(), b"original notice " + name.encode())
            self.assertTrue((stage / "dependency-manifests/xkbcommon-x64glibc.json").is_file())
            raise RuntimeError("bundle inputs inspected")

        crt = {"targets/x64glibc/" + name: b"verified CRT " + name.encode()
               for name in prepare_dependencies.GLIBC_LIBRARIES}
        crt["sources/glibc/source.tar.xz"] = b"corresponding sources"
        crt.update({"licenses/glibc/" + name: b"original notice " + name.encode() for name in prepare_dependencies.GLIBC_LICENSES})
        keyboard = {"targets/x64glibc/" + name: b"verified " + name.encode()
                    for name in prepare_dependencies.XKBCOMMON_LIBRARIES}
        keyboard["licenses/xkbcommon/LICENSE"] = b"upstream notice"
        with patch.object(bundle_platforms, "ROOT", self.root), patch.object(
                bundle_platforms, "prepare_platform"), patch.object(
                bundle_platforms, "verified_freetype", side_effect=lambda: verified(
                    prepare_dependencies.FREETYPE, {"targets/x64glibc/libfreetype.so": b"verified font"})), patch.object(
                bundle_platforms, "verified_glibc", side_effect=lambda: verified(
                    prepare_dependencies.GLIBC, crt)), patch.object(
                bundle_platforms, "verified_unwind", side_effect=lambda: verified(
                    prepare_dependencies.UNWIND, {"targets/x64glibc/libunwind.a": b"verified unwinder",
                    "licenses/unwind/LICENSE.TXT": b"LLVM terms", "sources/unwind/source.tar.xz": b"unwinder sources"})), patch.object(
                bundle_platforms, "verified_xkbcommon", side_effect=lambda: verified(
                    prepare_dependencies.XKBCOMMON, keyboard)), patch.object(
                bundle_platforms.shutil, "copyfile", wraps=shutil.copyfile) as copy_file, patch.object(
                bundle_platforms.subprocess, "run", side_effect=inspect_bundle), patch.object(
                sys, "argv", ["bundle_platforms.py", "--package", "gui", "--no-build", "--output-dir", str(self.root / "out")]):
            # Supply the host's own license, which normal source preparation preserves.
            license_file = self.root / "crates/gpui-host/LICENSE-GPUI"
            license_file.parent.mkdir(parents=True)
            license_file.write_text("GPUI")
            with self.assertRaisesRegex(RuntimeError, "bundle inputs inspected"):
                bundle_platforms.main()
            copied_sources = {Path(call.args[0]) for call in copy_file.call_args_list}
            for name in (*prepare_dependencies.XKBCOMMON_LIBRARIES, *prepare_dependencies.GLIBC_LIBRARIES, "crti.o", "crtn.o", "libdl.so", "injected.a", "libunwind.a", "libgcc_s.so"):
                self.assertNotIn(source / name, copied_sources)

    def test_freetype_admission_requires_complete_license_inventory(self):
        files = {"targets/x64glibc/libfreetype.so": {}}
        files.update({"licenses/freetype/" + name: {} for name in
                      ("LICENSE.TXT", "FTL.TXT", "GPLv2.TXT", "NOTICE")})

        def materialize(lock, identities, cache, destination):
            artifact = destination / prepare_dependencies.FREETYPE
            artifact.mkdir(parents=True)
            (artifact / "dependency.json").write_text(json.dumps({"files": files}))

        with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
            with prepare_dependencies.verified_freetype() as admitted:
                self.assertTrue(admitted.is_dir())
            files.pop("licenses/freetype/NOTICE")
            with self.assertRaisesRegex(ValueError, "incomplete or unexpected FreeType inputs"):
                with prepare_dependencies.verified_freetype():
                    self.fail("incomplete inventory was admitted")

    def test_bundle_merges_dependency_receipts_and_rejects_conflicting_identity(self):
        stage = self.root / "combined"
        stage.mkdir()
        for identity in ("freetype-x64glibc", "windows-imports-x64win"):
            (self.inputs / identity).mkdir()
            (self.inputs / "dependencies.lock.json").write_text(json.dumps({
                "schema_version": 1, "artifacts": {identity: {"sha256": identity}},
            }))
            bundle_platforms.stage_dependency_inputs(self.inputs, (identity,), stage)
        receipt = json.loads((stage / "dependencies.lock.json").read_text())
        self.assertEqual(set(receipt["artifacts"]), {"freetype-x64glibc", "windows-imports-x64win"})
        original = (stage / "dependencies.lock.json").read_bytes()
        (self.inputs / "dependencies.lock.json").write_text(json.dumps({
            "schema_version": 1, "artifacts": {"freetype-x64glibc": {"sha256": "different"}},
        }))
        with self.assertRaisesRegex(ValueError, "conflicting dependency receipt"):
            bundle_platforms.stage_dependency_inputs(self.inputs, ("freetype-x64glibc",), stage)
        self.assertEqual((stage / "dependencies.lock.json").read_bytes(), original)

    def test_freetype_verification_failure_preserves_existing_input_and_prevents_build(self):
        destination = self.root / "linux"
        destination.mkdir()
        library = destination / "libfreetype.so"
        library.write_bytes(b"previous verified bytes")
        with patch.object(prepare_dependencies, "verified_freetype", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                prepare_dependencies.install_freetype(destination)
        self.assertEqual(library.read_bytes(), b"previous verified bytes")
        self.assertEqual(list(destination.iterdir()), [library])
        with patch.object(build_gui, "host_target", return_value="x64glibc"), patch.object(
                build_gui, "install_freetype", side_effect=ValueError("untrusted signer")), patch.object(
                build_gui.subprocess, "run") as compiler:
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                build_gui.build()
        compiler.assert_not_called()

    def test_windows_checkout_preserves_vendored_upstream_bytes(self):
        source = prepare_dependencies.ROOT / "vendor/unicode"
        inventory = json.loads((source / "upstream.json").read_bytes())["files_sha256"]
        checkout = self.root / "checkout"
        paths = ["vendor/unicode/" + name for name in inventory]
        subprocess.run([
            "git", "-c", "core.autocrlf=true", "checkout-index",
            "--prefix=" + checkout.as_posix() + "/", "--", *paths,
        ], cwd=prepare_dependencies.ROOT, check=True)
        for name, expected in inventory.items():
            data = (checkout / "vendor/unicode" / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected, name)

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

    def test_windows_install_replaces_only_the_external_import_and_returns_its_lock(self):
        target = self.inputs / prepare_dependencies.WINDOWS_IMPORTS / "targets/x64win"
        target.mkdir(parents=True)
        (target / "advapi32.lib").write_bytes(b"verified import")
        lock = {"schema_version": 1, "artifacts": {"windows-imports-x64win": "reviewed entry"}}
        (self.inputs / "dependencies.lock.json").write_text(json.dumps(lock))
        destination = self.source / "targets/x64win"
        destination.mkdir()
        (destination / "host.lib").write_bytes(b"own host")
        (destination / "advapi32.lib").write_bytes(b"stale import")
        with patch.object(prepare_dependencies, "verified_windows_imports", self.verified):
            actual = prepare_dependencies.install_windows_imports(destination)
        self.assertEqual(actual, lock)
        self.assertEqual((destination / "host.lib").read_bytes(), b"own host")
        self.assertEqual((destination / "advapi32.lib").read_bytes(), b"verified import")

    def test_windows_verification_failure_prevents_compilation(self):
        with patch.object(build_gui, "host_target", return_value="x64win"), patch.object(
                build_gui, "install_windows_imports", side_effect=ValueError("untrusted signer")), patch.object(
                build_gui.subprocess, "run") as compiler:
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                build_gui.build()
        compiler.assert_not_called()

    def test_gui_bundle_rejects_combined_only_and_missing_engine_layouts(self):
        for target in ("x64glibc", "arm64mac", "x64mingw"):
            tree = self.root / target
            directory = tree / target
            directory.mkdir(parents=True)
            (directory / "libhost.a").write_bytes(b"old")
            with self.assertRaisesRegex(ValueError, "missing or invalid GUI archive"):
                bundle_platforms.validate_gui_archives(tree)
            rust, engine = ("libsignals_gpui_host.a", "libengine.a")
            (directory / rust).write_bytes(b"rust")
            with self.assertRaisesRegex(ValueError, "missing or invalid GUI archive"):
                bundle_platforms.validate_gui_archives(tree)
            (directory / engine).write_bytes(b"engine")
            bundle_platforms.validate_gui_archives(tree)

    def test_gui_bundle_rejects_obsolete_windows_target_even_with_complete_archives(self):
        tree = self.root / "obsolete"
        target = tree / "x64win"
        target.mkdir(parents=True)
        for name in ("signals_gpui_host.lib", "engine.lib", "signals.res", "advapi32.lib"):
            (target / name).write_bytes(b"old complete target")
        with self.assertRaisesRegex(ValueError, "obsolete x64win"):
            bundle_platforms.validate_gui_link_inputs(tree)

    def test_windows_bundle_has_no_unsigned_fallback(self):
        source = self.source / "targets/x64mingw"
        source.mkdir()
        for name in ("libsignals_gpui_host.a", "libengine.a", "signals.res"):
            (source / name).write_bytes(b"local")
        stage = self.root / "refused-windows-bundle"
        with patch.object(bundle_platforms, "verified_windows_gnu", side_effect=ValueError("untrusted signer")):
            with self.assertRaisesRegex(ValueError, "untrusted signer"):
                bundle_platforms.stage_windows_gnu_inputs(source, stage)
        self.assertFalse(stage.exists())

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
