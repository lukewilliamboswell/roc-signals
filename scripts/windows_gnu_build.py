"""Pinned native Windows GNU host, engine, resource and shader build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

from cargo_build_evidence import derive
from host_build_identity import record_outputs, source_fingerprint

ROOT = Path(__file__).resolve().parents[1]
TRIPLE = "x86_64-pc-windows-gnullvm"
SDK = "10.0.26100.0"
# Reviewed inventory run 34343278660: Microsoft-signed 10.0.26100.8249.
FXC_SHA = "005eff830845789c7efb2831a0b41950ee6954e9bcd93baf50de67ad537728b2"
COMPILER_SHA = "1557adab24404308657d7902fdac82ce07a120987a849acab690ab402fecf449"
SIGNER = "F6EECCC7FF116889C2D5466AE7243D7AA7698689"
ZIG_SHA = "68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e"


def identity(path):
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {"sha256": digest, "size": path.stat().st_size}


def verify(path, expected):
    if len(expected) != 64 or identity(path)["sha256"] != expected.lower():
        raise ValueError(f"unreviewed tool identity: {path.name}")


def probe_fxc(mode, fxc, dll, signatures, output):
    """Reject unreviewed build tools before executing the loaded-DLL probe."""
    if mode == "build":
        if (len(signatures) != 2
                or {Path(record["Path"]).resolve() for record in signatures} != {fxc.resolve(), dll.resolve()}
                or any(record["Status"] != 0 or record["Thumbprint"] != SIGNER for record in signatures)):
            raise ValueError("Windows shader tools require reviewed valid Authenticode signatures")
        verify(fxc, FXC_SHA)
        verify(dll, COMPILER_SHA)
    return json.loads(subprocess.check_output([
        "pwsh", "-NoProfile", "-File", str(ROOT / "scripts/windows_fxc_inventory.ps1"),
        "-Fxc", str(fxc), "-OutputDirectory", str(output)], text=True))


def compiler_args(mode, args):
    if mode == "ar":
        return ["ar", *args]
    return [mode, "-target", "x86_64-windows-gnu", "-mcpu=baseline",
            *(a for a in args if a != "--target=x86_64-pc-windows-gnu")]


def clean_commit():
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT):
        raise ValueError("candidate requires a pristine committed checkout")
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def run(args, env=None, output=None):
    return subprocess.run(args, cwd=ROOT, env=env, check=True, stdout=output)


def execute(mode, output, *, jobs=2, cargo_target=None, debug=False, capture_evidence=True):
    """Build host-owned outputs; native dependency releases are installed separately."""
    if jobs < 1 or (debug and capture_evidence):
        raise ValueError("release evidence requires an optimized build and positive jobs")
    if sys.platform != "win32":
        raise ValueError("native Windows is required for GPUI release shader compilation")
    commit = clean_commit() if capture_evidence else subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    fingerprint = source_fingerprint(ROOT) if capture_evidence else None
    lock = (ROOT / "Cargo.lock").read_bytes()
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    profile = "debug" if debug else "release"
    cargo_target = (cargo_target or output / "cargo-target").resolve()
    sdk = Path(os.environ["ProgramFiles(x86)"]) / "Windows Kits/10/bin" / SDK / "x64"
    fxc, dll = sdk / "fxc.exe", sdk / "d3dcompiler_47.dll"
    inventory = {p.name: identity(p) for p in (fxc, dll)}
    inventory["sdk_version"] = SDK
    inventory["source_commit"] = commit
    inventory["runner_image"] = os.environ.get("ImageVersion")
    versions = subprocess.check_output(["pwsh", "-NoProfile", "-Command",
        "$ErrorActionPreference='Stop'; Get-Item -LiteralPath '" + str(fxc) + "','" + str(dll)
        + "' | ForEach-Object { $_.VersionInfo | Select-Object FileName,FileVersion,ProductVersion } | ConvertTo-Json"], text=True)
    inventory["file_versions"] = json.loads(versions)
    signatures = subprocess.check_output(["pwsh", "-NoProfile", "-Command",
        "$ErrorActionPreference='Stop'; Get-AuthenticodeSignature -LiteralPath '" + str(fxc) + "','" + str(dll)
        + "' | Select-Object Path,Status,@{n='Subject';e={$_.SignerCertificate.Subject}},"
        + "@{n='Thumbprint';e={$_.SignerCertificate.Thumbprint}} | ConvertTo-Json"], text=True)
    inventory["authenticode"] = json.loads(signatures)
    inventory["fxc_path"] = str(fxc)
    inventory["compiler_dll_path"] = str(dll)
    inventory["loaded_module_probe"] = probe_fxc(mode, fxc, dll, inventory["authenticode"], output)
    loaded = inventory["loaded_module_probe"]
    if Path(loaded["path"]).resolve() != dll.resolve() or loaded["sha256"].lower() != inventory[dll.name]["sha256"]:
        raise ValueError("FXC loaded a different compiler DLL than the inventoried SDK file")
    (output / "tools-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    if mode == "inventory":
        return
    if any(record["Status"] != 0 or record["Thumbprint"] != SIGNER
           for record in inventory["authenticode"]):
        raise ValueError("candidate FXC tools require valid Authenticode signatures")
    verify(fxc, FXC_SHA)
    verify(dll, COMPILER_SHA)
    # Fixed copies prevent GPUI's PATH/SDK fallback selecting another compiler.
    tool_dir = output / "tools"
    tool_dir.mkdir()
    for path in (fxc, dll):
        shutil.copyfile(path, tool_dir / path.name)
    from prepare_gui_host_release import verified_download
    archive = verified_download(
        "https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip", ZIG_SHA,
        Path.home() / ".cache/roc-signals/toolchains" / (ZIG_SHA + ".zip"), 97217739)
    with zipfile.ZipFile(archive) as source:
        source.extractall(tool_dir)
    zig = tool_dir / "zig-x86_64-windows-0.16.0/zig.exe"
    env = os.environ.copy()
    env.update(RUSTUP_TOOLCHAIN="1.95.0", CARGO_TARGET_DIR=str(cargo_target),
               GPUI_FXC_PATH=str(tool_dir / "fxc.exe"), SIGNALS_WINDOWS_ZIG=str(zig))
    for variable, mode in (("CC", "cc"), ("CXX", "c++"), ("AR", "ar")):
        wrapper = tool_dir / (variable.lower() + ".cmd")
        wrapper.write_text('@echo off\n"' + sys.executable + '" "' + str(Path(__file__).resolve()) + '" ' + mode + ' %*\n')
        env[variable + "_x86_64_pc_windows_gnullvm"] = str(wrapper)
    versions = {"rustc": subprocess.check_output(["rustc", "-vV"], env=env, text=True),
                "cargo": subprocess.check_output(["cargo", "-V"], env=env, text=True),
                "zig": subprocess.check_output([str(zig), "version"], text=True)}
    if "release: 1.95.0\n" not in versions["rustc"] or versions["zig"].strip() != "0.16.0":
        raise ValueError("candidate toolchain version mismatch")
    rust_host = next(line.removeprefix("host: ") for line in versions["rustc"].splitlines() if line.startswith("host: "))
    if rust_host != "x86_64-pc-windows-msvc":
        raise ValueError("unreviewed native Rust build-host target")
    with (output / "cargo.jsonl").open("w") as stream:
        run(["cargo", "build", "--locked", *([] if debug else ["--release"]), "--target", TRIPLE,
             "-p", "signals-gpui-host", "-j", str(jobs), "--message-format=json-render-diagnostics"], env, stream)
    metadata = subprocess.check_output(["cargo", "metadata", "--locked", "--format-version=1",
                                        "--filter-platform", TRIPLE], cwd=ROOT, env=env)
    (output / "metadata.json").write_bytes(metadata)
    host_metadata = subprocess.check_output([
        "cargo", "metadata", "--locked", "--format-version=1", "--filter-platform", rust_host,
    ], cwd=ROOT, env=env)
    (output / "metadata-host.json").write_bytes(host_metadata)
    if (ROOT / "Cargo.lock").read_bytes() != lock:
        raise ValueError("Cargo.lock changed during candidate build")
    (output / "Cargo.lock").write_bytes(lock)
    run([sys.executable, "scripts/prepare_platforms.py"], env)
    run([str(zig), "build", "build-gui-engine", "-Dtarget=x86_64-windows-gnu",
         "--prefix", str(output / "zig-out")], env)
    payload = output / "payload"
    payload.mkdir()
    host = cargo_target / TRIPLE / profile / "libsignals_gpui_host.a"
    host_artifacts = []
    for line in (output / "cargo.jsonl").read_text().splitlines():
        event = json.loads(line)
        if event.get("reason") == "compiler-artifact" and str(host) in event.get("filenames", []):
            host_artifacts.append(event)
    if len(host_artifacts) != 1 or host_artifacts[0]["profile"]["debug_assertions"] != debug:
        raise ValueError("raw host does not match one optimized Cargo artifact")
    shutil.copyfile(host, payload / "libsignals_gpui_host.a")
    shutil.copyfile(output / "zig-out/gui/libengine.a", payload / "libengine.a")
    subprocess.run([str(zig), "rc", "signals.rc", str(payload / "signals.res")],
                   cwd=ROOT / "crates/gpui-host/windows", check=True)
    shaders = output / "shaders"
    shaders.mkdir()
    for directory in (cargo_target / TRIPLE / profile / "build").glob("gpui-*/out"):
        for path in directory.iterdir():
            if path.is_file():
                shutil.copyfile(path, shaders / (directory.parent.name + "-" + path.name))
    if not debug and not list(shaders.glob("*-shaders_bytes.rs")):
        raise ValueError("optimized GPUI shader evidence missing")
    if capture_evidence and clean_commit() != commit:
        raise ValueError("candidate source changed during build")
    if capture_evidence:
        evidence, selection = derive(
            metadata, (output / "cargo.jsonl").read_bytes(), lock, "x64mingw",
            (payload / "libsignals_gpui_host.a").read_bytes(), fingerprint=fingerprint,
            host_metadata_bytes=host_metadata, compiler_host=rust_host,
        )
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        (output / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
        record_outputs(ROOT, "x64mingw", payload, output, fingerprint)
    for original in (fxc, dll):
        verify(tool_dir / original.name, inventory[original.name]["sha256"])
    receipt = {"schema_version": 1, "candidate_only": True, "source_commit": commit,
               "target": "x64mingw", "rust_target": TRIPLE, "rust_host": rust_host, "profile": profile,
               "metadata": identity(output / "metadata.json"),
               "metadata_host": identity(output / "metadata-host.json"),
               "versions": versions, "zig_archive_sha256": ZIG_SHA,
               "tools": inventory, "outputs": {p.name: identity(p) for p in payload.iterdir()},
               "shaders": {p.name: identity(p) for p in shaders.iterdir()},
               "cargo_stream": identity(output / "cargo.jsonl"), "cargo_host": host_artifacts[0]}
    (output / "candidate.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt["outputs"], indent=2))

    return payload


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("cc", "c++", "ar"):
        raise SystemExit(subprocess.call([os.environ["SIGNALS_WINDOWS_ZIG"],
                                         *compiler_args(sys.argv[1], sys.argv[2:])]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inventory", "build"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    execute(args.mode, args.output)


if __name__ == "__main__":
    main()
