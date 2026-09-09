"""Complete notice payloads follow the compiled package set and original bytes."""

import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import subprocess
import unittest
from unittest.mock import patch

from prepare_gui_host_release import verified_download

import cargo_build_evidence as cargo
import host_notice_payload as payload
import rust_license_inventory as crates
import toolchain_license_inventory as toolchains
from dependency_artifacts import unpack_verified


class NoticePayloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.policy = self.root / "policy"
        self.policy.mkdir()
        self.host = b"actual host output"
        self.root_id = "path+file:///source#signals-gpui-host@1.0.0"
        self.dep_id = crates.REGISTRY + "#example@1.0.0"
        archive = self.root / "example-1.0.0.crate"
        original = b'[package]\nname="example"\nversion="1.0.0"\nlicense="MIT"\n'
        self.tar(archive, {"example-1.0.0/Cargo.toml": original,
                           "example-1.0.0/src/lib.rs": b"// Copyright: original author\npub fn example() {}\n"}, "w:gz")
        checksum = payload.digest(archive.read_bytes())
        self.lock = (f'[[package]]\nname="signals-gpui-host"\nversion="1.0.0"\n'
                     f'[[package]]\nname="example"\nversion="1.0.0"\nsource="{crates.REGISTRY}"\nchecksum="{checksum}"\n').encode()
        self.metadata = {"packages": [
            {"id": self.root_id, "name": "signals-gpui-host", "version": "1.0.0", "source": None, "license": None},
            {"id": self.dep_id, "name": "example", "version": "1.0.0", "source": crates.REGISTRY, "license": "MIT"}],
            "workspace_members": [self.root_id], "resolve": {"nodes": [
                {"id": self.root_id, "deps": [{"pkg": self.dep_id, "dep_kinds": [{"kind": None}]}]},
                {"id": self.dep_id, "deps": []}]}}
        self.messages = [
            {"reason": "compiler-artifact", "package_id": self.dep_id, "target": {"kind": ["rlib"]}},
            {"reason": "compiler-artifact", "package_id": self.root_id, "target": {"kind": ["staticlib"]},
             "profile": {"test": False, "opt_level": "3"}, "filenames": ["/target/release/libsignals_gpui_host.a"]},
            {"reason": "build-finished", "success": True}]
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        metadata_bytes = json.dumps(self.metadata).encode()
        messages_bytes = self.stream()
        evidence, selection = cargo.derive(metadata_bytes, messages_bytes, self.lock, "x64glibc", self.host, fingerprint="source-fingerprint")
        for name, data in {"metadata.json": metadata_bytes, "cargo.jsonl": messages_bytes, "Cargo.lock": self.lock,
                           "evidence.json": json.dumps(evidence).encode(), "selection.json": json.dumps(selection).encode()}.items():
            (self.evidence / name).write_bytes(data)
        (self.evidence / "build.json").write_text(json.dumps({
            "schema_version": 1, "target": "x64glibc", "source_fingerprint": "source-fingerprint",
            "outputs": {"libsignals_gpui_host.a": {"sha256": payload.digest(self.host), "size": len(self.host)},
                        "libengine.a": {"sha256": payload.digest(b"engine"), "size": 6}}}))
        for name in ("manifest.json", "review.json"):
            (self.policy / name).write_text(json.dumps({"schema_version": 1, "packages": {}}))
        self.crates = self.root / "crates"
        crates.collect(self.evidence / "selection.json", self.evidence / "Cargo.lock", self.root, self.crates,
                       self.policy / "manifest.json", True, self.policy / "review.json", True)
        terms = b"Standard reference terms with template attribution: <copyright holder>"
        (self.policy / "MIT.txt").write_bytes(terms)
        self.term_policy = {"schema_version": 1, "expressions": {"MIT": ["MIT"]},
                            "terms": {"MIT": {"path": "MIT.txt", "sha256": payload.digest(terms)}},
                            "excluded_targets": {"arm64mac": "Apple SDK scope requires separate review"}}
        (self.policy / "standard-terms.json").write_text(json.dumps(self.term_policy))
        rust = self.root / "rust.tar.xz"
        zig = self.root / "zig.tar.xz"
        self.tar(rust, {"rust-1/COPYRIGHT": b"original Rust runtime notice"}, "w:xz")
        self.tar(zig, {"zig-1/LICENSE": b"original Zig license", "zig-1/lib/std/example.zig": b"// Copyright: runtime author"}, "w:xz")
        recipe = {"schema_version": 1,
                  "rust": {"version": "1", "targets": {"x64glibc": {
                      "prefix": "rust-1", "notices": ["COPYRIGHT"], "source_url": "https://example.invalid/rust",
                      "sha256": payload.digest(rust.read_bytes())}}},
                  "zig": {"version": "1", "prefix": "zig-1", "notices": ["LICENSE"],
                          "source_url": "https://example.invalid/zig", "sha256": payload.digest(zig.read_bytes())}}
        (self.policy / "toolchains.json").write_text(json.dumps(recipe))
        self.toolchains = self.root / "toolchains"
        toolchains.collect(self.policy / "toolchains.json", "x64glibc", rust, zig, self.toolchains)

    @staticmethod
    def tar(path, files, mode):
        with tarfile.open(path, mode) as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))

    def stream(self):
        return b"\n".join(json.dumps(m).encode() for m in self.messages) + b"\n"

    def compose(self, target="x64glibc"):
        return payload.compose(target, self.evidence, self.crates, self.toolchains, self.policy,
                               self.host, self.root / "gui-host-sources-x64glibc.tar", "source-fingerprint")

    def test_complete_payload_preserves_original_and_reference_texts_separately(self):
        result = self.compose()
        index = payload.validate_notice_archive(result["third-party-notices.tar.xz"])
        self.assertIn("crates/example-1.0.0/embedded_notice_files/src/lib.rs", index)
        self.assertIn("crates/example-1.0.0/declaration_files/Cargo.toml", index)
        self.assertIn("toolchains/zig-runtime-source-notices/lib/std/example.zig", index)
        self.assertEqual(index["referenced-standard-terms/MIT.txt"]["sha256"], payload.digest((self.policy / "MIT.txt").read_bytes()))
        manifest = json.loads(result["NOTICE.json"])
        self.assertEqual(manifest["source_companion"]["sha256"], payload.digest((self.root / "gui-host-sources-x64glibc.tar").read_bytes()))
        self.assertEqual(manifest["host"]["sha256"], payload.digest(self.host))
        self.assertIn(b"not fabricated crate-specific", result["NOTICE.md"])
        notice_root = self.root / "composed"
        notice_root.mkdir()
        for name, data in result.items():
            (notice_root / name).write_bytes(data)
        manifest, notice_data = payload.validate_notices(notice_root, "x64glibc", self.host, "source-fingerprint", self.policy)
        source_root = self.root / "source-tree"
        unpack_verified(self.root / "gui-host-sources-x64glibc.tar", {"name": "gui-host-sources", "target": "x64glibc"}, source_root)
        payload.validate_sources(source_root, manifest, notice_data, self.host, self.lock)
        (source_root / "licenses/gui-host-sources/sources/example-1.0.0.crate").write_bytes(b"changed source")
        with self.assertRaisesRegex(ValueError, "differs from its inventory"):
            payload.validate_sources(source_root, manifest, notice_data, self.host, self.lock)

    def test_cross_target_selection_retains_actual_compiler_host_packages(self):
        self.messages[1]["filenames"] = ["/target/x86_64-pc-windows-gnullvm/release/libsignals_gpui_host.a"]
        target_metadata = json.dumps(self.metadata).encode()
        host_metadata = json.loads(target_metadata)
        identity = crates.REGISTRY + "#host-tool@1.0.0"
        host_metadata["packages"].append({"id": identity, "name": "host-tool", "version": "1.0.0",
                                          "source": crates.REGISTRY, "license": "MIT"})
        host_metadata["resolve"]["nodes"][0]["deps"].append({"pkg": identity, "dep_kinds": [{"kind": "build"}]})
        host_metadata["resolve"]["nodes"].append({"id": identity, "deps": []})
        host_bytes = json.dumps(host_metadata).encode()
        self.messages.insert(0, {"reason": "compiler-artifact", "package_id": identity, "target": {"kind": ["bin"]}})
        lock = self.lock + ('[[package]]\nname="host-tool"\nversion="1.0.0"\nsource="' + crates.REGISTRY
                            + '"\nchecksum="' + 'a' * 64 + '"\n').encode()
        evidence, _ = cargo.derive(target_metadata, self.stream(), lock, "x64mingw", self.host,
                                  fingerprint="source", host_metadata_bytes=host_bytes,
                                  compiler_host="x86_64-pc-windows-msvc")
        self.assertEqual(evidence["schema_version"], 2)
        self.assertEqual(evidence["rust_target"], "x86_64-pc-windows-gnullvm")
        self.assertEqual(evidence["rust_host"], "x86_64-pc-windows-msvc")
        self.assertEqual(evidence["metadata_host_sha256"], payload.digest(host_bytes))
        self.assertIn("host-tool", {package["name"] for package in evidence["packages"]})
        with self.assertRaisesRegex(ValueError, "compiler-host metadata"):
            cargo.derive(target_metadata, self.stream(), lock, "x64mingw", self.host, fingerprint="source")
        with self.assertRaisesRegex(ValueError, "outside the host metadata graph"):
            cargo.derive(target_metadata, self.stream(), lock, "x64mingw", self.host, fingerprint="source",
                         host_metadata_bytes=target_metadata, compiler_host="x86_64-pc-windows-msvc")
        host_metadata["packages"][1]["license"] = "invented"
        with self.assertRaisesRegex(ValueError, "disagree on a package"):
            cargo.derive(target_metadata, self.stream(), lock, "x64mingw", self.host, fingerprint="source",
                         host_metadata_bytes=json.dumps(host_metadata).encode(), compiler_host="x86_64-pc-windows-msvc")

    def test_gnu_notice_companion_retains_both_metadata_graphs_and_std_component(self):
        target = "x64mingw"
        self.messages[1]["filenames"] = ["/target/x86_64-pc-windows-gnullvm/release/libsignals_gpui_host.a"]
        metadata = (self.evidence / "metadata.json").read_bytes()
        evidence, selection = cargo.derive(metadata, self.stream(), self.lock, target, self.host,
                                          fingerprint="source-fingerprint", host_metadata_bytes=metadata,
                                          compiler_host="x86_64-pc-windows-msvc")
        (self.evidence / "metadata-host.json").write_bytes(metadata)
        (self.evidence / "cargo.jsonl").write_bytes(self.stream())
        (self.evidence / "evidence.json").write_text(json.dumps(evidence))
        self.assertEqual(selection, json.loads((self.evidence / "selection.json").read_text()))
        build = json.loads((self.evidence / "build.json").read_text())
        build["target"] = target
        build["outputs"]["signals.res"] = {"sha256": payload.digest(b"resource"), "size": 8}
        (self.evidence / "build.json").write_text(json.dumps(build))
        recipe = json.loads((self.policy / "toolchains.json").read_text())
        pin = dict(recipe["rust"]["targets"]["x64glibc"])
        std = self.root / "std.tar.xz"
        self.tar(std, {"std-1/LICENSE": b"original target std license"}, "w:xz")
        pin.update(compiler_host="x86_64-pc-windows-msvc", rust_target="x86_64-pc-windows-gnullvm",
                   target_component={"prefix": "std-1", "notices": ["LICENSE"],
                                     "source_url": "https://example.invalid/std", "sha256": payload.digest(std.read_bytes())})
        recipe["rust"]["targets"][target] = pin
        (self.policy / "toolchains.json").write_text(json.dumps(recipe))
        tools = self.root / "gnu-tools"
        toolchains.collect(self.policy / "toolchains.json", target, self.root / "rust.tar.xz", self.root / "zig.tar.xz", tools, std)
        source = self.root / "gui-host-sources-x64mingw.tar"
        result = payload.compose(target, self.evidence, self.crates, tools, self.policy,
                                 self.host, source, "source-fingerprint")
        notice_root = self.root / "gnu-notices"
        notice_root.mkdir()
        for name, data in result.items():
            (notice_root / name).write_bytes(data)
        outputs = {"libsignals_gpui_host.a": self.host, "libengine.a": b"engine", "signals.res": b"resource"}
        manifest, data = payload.validate_notices(notice_root, target, self.host, "source-fingerprint", self.policy, outputs)
        self.assertIn("rust-target", manifest["toolchains"])
        source_tree = self.root / "gnu-source-tree"
        unpack_verified(source, {"name": "gui-host-sources", "target": target}, source_tree)
        payload.validate_sources(source_tree, manifest, data, self.host, self.lock)
        payload.validate_sources(source_tree, manifest, data, self.host, self.lock.replace(b"\n", b"\r\n"))
        for changed in (self.lock + b"# comment\n", self.lock.replace(b'1.0.0', b'2.0.0')):
            with self.assertRaisesRegex(ValueError, "different Cargo.lock"):
                payload.validate_sources(source_tree, manifest, data, self.host, changed)
        (source_tree / "licenses/gui-host-sources/evidence/metadata-host.json").write_bytes(b"{}")
        with self.assertRaises((ValueError, KeyError)):
            payload.validate_sources(source_tree, manifest, data, self.host, self.lock)

    def test_normalization_does_not_relabel_raw_cargo_or_replace_engine(self):
        final = b"transformed host"
        original = {"name": "libsignals_gpui_host.a", "sha256": payload.digest(self.host), "size": len(self.host)}
        build = json.loads((self.evidence / "build.json").read_text())
        receipt = {"schema_version": 1, "target": "x64glibc",
                   "tools": {"reviewed": {"sha256": "a" * 64, "version": "1"}},
                   "archives": {original["name"]: {
                       "input": {k: original[k] for k in ("sha256", "size")},
                       "output": {"sha256": payload.digest(final), "size": len(final)},
                       "steps": [{"tool": "reviewed", "args": ["checked transformation"]}]}}}
        outputs = {"libsignals_gpui_host.a": final, "libengine.a": b"engine"}
        payload.validate_packaged_outputs(build, "x64glibc", "source-fingerprint", original, outputs, receipt)
        with self.assertRaisesRegex(ValueError, "captured build receipt"):
            payload.validate_packaged_outputs(build, "x64glibc", "source-fingerprint", original,
                                              dict(outputs, **{"libengine.a": b"replacement"}), receipt)
        with self.assertRaisesRegex(ValueError, "captured build receipt"):
            payload.validate_packaged_outputs(build, "x64glibc", "source-fingerprint", original, outputs)

    def test_gnu_separation_binds_structural_ledger_and_raw_build(self):
        from test_windows_gnu_coff import null_descriptor, StructuralTests
        from windows_gnu_coff import separate, identity
        code = bytearray(null_descriptor())
        code[20:28] = b".text\0\0\0"
        archive = bytearray(b"!<arch>\n")
        for index, body in enumerate((bytes(code), null_descriptor())):
            archive.extend((str(index) + ".o/").encode().ljust(16) + b"0".ljust(12)
                           + b"0".ljust(6) + b"0".ljust(6) + b"644".ljust(8)
                           + str(len(body)).encode().ljust(10) + b"`\n" + body)
            if len(body) % 2:
                archive.extend(b"\n")
        raw, final = self.root / "raw.a", self.root / "final.a"
        raw.write_bytes(archive)
        with patch("windows_gnu_coff.subprocess.run"):
            separation = separate(raw, final, StructuralTests.inventory, Path(__file__))
        name = "libsignals_gpui_host.a"
        original = dict(identity(archive), name=name)
        outputs = {name: final.read_bytes(), "libengine.a": b"engine", "signals.res": b"resource"}
        build = {"schema_version": 1, "target": "x64mingw", "source_fingerprint": "source-fingerprint",
                 "outputs": {key: identity(value) for key, value in outputs.items()}}
        build["outputs"][name] = identity(archive)
        receipt = {"schema_version": 1, "target": "x64mingw",
                   "tools": {"zig": {"sha256": separation["index_tool"]["sha256"], "version": "test"}},
                   "archives": {name: {"input": separation["input"], "output": separation["output"],
                                       "operation": separation["operation"], "separation": separation,
                                       "steps": [{"tool": "zig", "args": ["ar", "s"]}]}}}
        def validate(value=receipt, packaged=outputs):
            payload.validate_packaged_outputs(build, "x64mingw", "source-fingerprint", original, packaged, value)
        validate()
        for changed in ("libengine.a", "signals.res"):
            with self.assertRaisesRegex(ValueError, "captured build receipt"):
                validate(packaged=dict(outputs, **{changed: b"replacement"}))
        for field, value in (("operation", "arbitrary-rewrite"), ("input", identity(b"other raw host"))):
            altered = json.loads(json.dumps(receipt))
            altered["archives"][name][field] = value
            with self.assertRaises(ValueError):
                validate(altered)
        altered = json.loads(json.dumps(receipt))
        altered["archives"][name]["separation"]["retained"][0]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            validate(altered)

    def test_capture_refuses_source_drift_across_cargo_execution(self):
        (self.root / "Cargo.lock").write_bytes(self.lock)
        target = self.root / "target"
        host = target / "release/libsignals_gpui_host.a"
        host.parent.mkdir(parents=True)
        host.write_bytes(self.host)
        self.metadata["target_directory"] = str(target)
        self.messages[1]["target"]["name"] = "signals_gpui_host"
        self.messages[1]["filenames"] = [str(host)]

        def checked(command, **kwargs):
            if command[0] == "rustc":
                return "rustc 1.95.0 (test)\nhost: x86_64-unknown-linux-gnu\n"
            return json.dumps(self.metadata).encode()

        def build(command, **kwargs):
            kwargs["stdout"].write(self.stream())
            return subprocess.CompletedProcess(command, 0)

        output = self.root / "capture"
        with patch.object(cargo, "source_fingerprint", side_effect=["old", "new"]), \
                patch.object(cargo.subprocess, "check_output", side_effect=checked), \
                patch.object(cargo.subprocess, "run", side_effect=build):
            with self.assertRaisesRegex(ValueError, "changed during Cargo"):
                cargo.capture(self.root, "x64glibc", output, 2, {}, "old")
        self.assertFalse(output.exists())
        with patch.object(cargo, "source_fingerprint", return_value="new"), \
                patch.object(cargo.subprocess, "run") as process:
            with self.assertRaisesRegex(ValueError, "changed before Cargo"):
                cargo.capture(self.root, "x64glibc", output, 2, {}, "old")
            process.assert_not_called()

    def test_old_build_cannot_be_relabelled_as_new_source(self):
        with self.assertRaisesRegex(ValueError, "different source inputs"):
            payload.compose("x64glibc", self.evidence, self.crates, self.toolchains, self.policy,
                            self.host, self.root / "gui-host-sources-x64glibc.tar", "new-source-fingerprint")

    def test_replacement_engine_rejected_at_notice_admission(self):
        result = self.compose()
        notice_root = self.root / "composed"
        notice_root.mkdir()
        for name, data in result.items():
            (notice_root / name).write_bytes(data)
        with self.assertRaisesRegex(ValueError, "captured build receipt"):
            payload.validate_notices(notice_root, "x64glibc", self.host, "source-fingerprint", self.policy,
                                     {"libsignals_gpui_host.a": self.host, "libengine.a": b"replacement"})

    def test_cached_notice_downloads_are_verified_and_failed_downloads_leave_no_input(self):
        destination = self.root / "download"
        content = b"pinned original"
        with patch("urllib.request.urlopen", return_value=io.BytesIO(content)) as fetch:
            verified_download("https://example.invalid/source", payload.digest(content), destination, len(content))
            verified_download("https://example.invalid/source", payload.digest(content), destination, len(content))
            self.assertEqual(fetch.call_count, 1)
        destination.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "cached"):
            verified_download("https://example.invalid/source", payload.digest(content), destination)
        destination.unlink()
        with patch("urllib.request.urlopen", return_value=io.BytesIO(content)), self.assertRaisesRegex(ValueError, "size limit"):
            verified_download("https://example.invalid/source", payload.digest(content), destination, 2)
        self.assertFalse(destination.exists())

    def test_committed_reference_terms_and_expression_choices(self):
        root = Path(__file__).resolve().parents[1] / "dependencies/gui-host-notices"
        policy = json.loads((root / "standard-terms.json").read_text())
        for record in policy["terms"].values():
            self.assertEqual(payload.digest((root / record["path"]).read_bytes()), record["sha256"])
        self.assertEqual(set(policy["expressions"]["(Apache-2.0 OR MIT) AND BSD-3-Clause"]), {"MIT", "BSD-3-Clause"})
        self.assertEqual(policy["expressions"]["CC0-1.0 OR MIT-0 OR Apache-2.0"], ["CC0-1.0"])

    def test_failed_or_incomplete_build_cannot_select_notices(self):
        self.messages.pop()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            cargo.derive(json.dumps(self.metadata).encode(), self.stream(), self.lock, "x64glibc", self.host, fingerprint="source-fingerprint")
        self.messages.append({"reason": "build-finished", "success": False})
        with self.assertRaisesRegex(ValueError, "unsuccessful"):
            cargo.derive(json.dumps(self.metadata).encode(), self.stream(), self.lock, "x64glibc", self.host, fingerprint="source-fingerprint")

    def test_wrong_host_or_changed_notice_refuses_source_publication(self):
        self.host = b"different host"
        with self.assertRaisesRegex(ValueError, "evidence changed"):
            self.compose()
        self.assertFalse((self.root / "gui-host-sources-x64glibc.tar").exists())
        self.host = b"actual host output"
        (self.policy / "MIT.txt").write_bytes(b"modified standard terms")
        with self.assertRaisesRegex(ValueError, "differs from its inventory"):
            self.compose()
        self.assertFalse((self.root / "gui-host-sources-x64glibc.tar").exists())

    def test_missing_compiled_package_and_unknown_terms_are_rejected(self):
        inventory_path = self.crates / "inventory.json"
        original = inventory_path.read_bytes()
        inventory = json.loads(original)
        inventory["packages"] = []
        inventory_path.write_text(json.dumps(inventory))
        with self.assertRaisesRegex(ValueError, "compiled package set"):
            self.compose()
        inventory_path.write_bytes(original)
        self.term_policy["expressions"] = {}
        (self.policy / "standard-terms.json").write_text(json.dumps(self.term_policy))
        with self.assertRaisesRegex(ValueError, "unreviewed Cargo license"):
            self.compose()
        self.assertFalse((self.root / "gui-host-sources-x64glibc.tar").exists())

    def test_mac_policy_is_separate_from_linux_payload_eligibility(self):
        with self.assertRaisesRegex(ValueError, "Apple SDK"):
            self.compose("arm64mac")
        self.assertFalse((self.root / "gui-host-sources-x64glibc.tar").exists())
        self.compose()

    def test_inner_notice_inventory_rejects_missing_and_unsafe_files(self):
        with self.assertRaises(ValueError):
            payload.validate_notice_archive(payload.pack_notices({"../escape": b"notice"}))
        archive = self.root / "bad.tar.xz"
        self.tar(archive, {"notice.txt": b"changed", "inventory.json": json.dumps({
            "notice.txt": {"sha256": "a" * 64, "size": 7}}).encode()}, "w:xz")
        with self.assertRaisesRegex(ValueError, "differs from its index"):
            payload.validate_notice_archive(archive.read_bytes())


if __name__ == "__main__":
    unittest.main()
