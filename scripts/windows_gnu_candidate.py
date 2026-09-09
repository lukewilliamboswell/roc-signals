"""Native Windows GNU candidate build evidence; never installs release dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile

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


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("cc", "c++", "ar"):
        raise SystemExit(subprocess.call([os.environ["SIGNALS_CANDIDATE_ZIG"],
                                         *compiler_args(sys.argv[1], sys.argv[2:])]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inventory", "build"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "win32":
        raise ValueError("native Windows is required for GPUI release shader compilation")
    commit = clean_commit()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
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
    inventory["loaded_module_probe"] = json.loads(subprocess.check_output([
        "pwsh", "-NoProfile", "-File", str(ROOT / "scripts/windows_fxc_inventory.ps1"),
        "-Fxc", str(fxc), "-OutputDirectory", str(output)], text=True))
    loaded = inventory["loaded_module_probe"]
    if Path(loaded["path"]).resolve() != dll.resolve() or loaded["sha256"].lower() != inventory[dll.name]["sha256"]:
        raise ValueError("FXC loaded a different compiler DLL than the inventoried SDK file")
    (output / "tools-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    if args.mode == "inventory":
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
    archive = tool_dir / "zig.zip"
    urllib.request.urlretrieve("https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip", archive)
    verify(archive, ZIG_SHA)
    with zipfile.ZipFile(archive) as source:
        source.extractall(tool_dir)
    zig = tool_dir / "zig-x86_64-windows-0.16.0/zig.exe"
    env = os.environ.copy()
    env.update(RUSTUP_TOOLCHAIN="1.95.0", CARGO_TARGET_DIR=str(output / "cargo-target"),
               GPUI_FXC_PATH=str(tool_dir / "fxc.exe"), SIGNALS_CANDIDATE_ZIG=str(zig))
    for variable, mode in (("CC", "cc"), ("CXX", "c++"), ("AR", "ar")):
        wrapper = tool_dir / (variable.lower() + ".cmd")
        wrapper.write_text('@echo off\n"' + sys.executable + '" "' + str(Path(__file__).resolve()) + '" ' + mode + ' %*\n')
        env[variable + "_x86_64_pc_windows_gnullvm"] = str(wrapper)
    versions = {"rustc": subprocess.check_output(["rustc", "-vV"], env=env, text=True),
                "cargo": subprocess.check_output(["cargo", "-V"], env=env, text=True),
                "zig": subprocess.check_output([str(zig), "version"], text=True)}
    if "release: 1.95.0\n" not in versions["rustc"] or versions["zig"].strip() != "0.16.0":
        raise ValueError("candidate toolchain version mismatch")
    with (output / "cargo.jsonl").open("w") as stream:
        run(["cargo", "build", "--locked", "--release", "--target", TRIPLE,
             "-p", "signals-gpui-host", "-j", "2", "--message-format=json-render-diagnostics"], env, stream)
    metadata = subprocess.check_output(["cargo", "metadata", "--locked", "--format-version=1",
                                        "--filter-platform", TRIPLE], cwd=ROOT, env=env)
    (output / "metadata.json").write_bytes(metadata)
    shutil.copyfile(ROOT / "Cargo.lock", output / "Cargo.lock")
    run([sys.executable, "scripts/prepare_platforms.py"], env)
    run([str(zig), "build", "build-gui-engine", "-Dtarget=x86_64-windows-gnu",
         "-Dgpui-gnu-candidate=true", "--prefix", str(output / "zig-out")], env)
    payload = output / "payload"
    payload.mkdir()
    host = output / "cargo-target" / TRIPLE / "release/libsignals_gpui_host.a"
    host_artifacts = []
    for line in (output / "cargo.jsonl").read_text().splitlines():
        event = json.loads(line)
        if event.get("reason") == "compiler-artifact" and str(host) in event.get("filenames", []):
            host_artifacts.append(event)
    if len(host_artifacts) != 1 or host_artifacts[0]["profile"]["debug_assertions"]:
        raise ValueError("raw host does not match one optimized Cargo artifact")
    shutil.copyfile(host, payload / "libsignals_gpui_host.a")
    shutil.copyfile(output / "zig-out/gui/libengine.a", payload / "libengine.a")
    shaders = output / "shaders"
    shaders.mkdir()
    for directory in (output / "cargo-target" / TRIPLE / "release/build").glob("gpui-*/out"):
        for path in directory.iterdir():
            if path.is_file():
                shutil.copyfile(path, shaders / (directory.parent.name + "-" + path.name))
    if not list(shaders.glob("*-shaders_bytes.rs")):
        raise ValueError("optimized GPUI shader evidence missing")
    if clean_commit() != commit:
        raise ValueError("candidate source changed during build")
    for original in (fxc, dll):
        verify(tool_dir / original.name, inventory[original.name]["sha256"])
    receipt = {"schema_version": 1, "candidate_only": True, "source_commit": commit,
               "target": "x64mingw", "rust_target": TRIPLE, "profile": "release",
               "versions": versions, "zig_archive_sha256": ZIG_SHA,
               "tools": inventory, "outputs": {p.name: identity(p) for p in payload.iterdir()},
               "shaders": {p.name: identity(p) for p in shaders.iterdir()},
               "cargo_stream": identity(output / "cargo.jsonl"), "cargo_host": host_artifacts[0]}
    (output / "candidate.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt["outputs"], indent=2))


if __name__ == "__main__":
    main()
