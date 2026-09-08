#!/usr/bin/env python3
"""Build a release site and preserve prior version and platform download URLs."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

import release
from release_followup import api, REPO
import serve


def previous_downloads(output: Path) -> dict[str, bytes]:
    current = release.ROOT / "releases/current.json"
    if current.exists():
        manifest = json.loads(current.read_text())
        site = manifest["site"]
        archive = output / "previous.zip"
        release.download(site["url"], archive)
        if release.digest(archive) != site["sha256"]:
            raise ValueError("previous site artifact digest mismatch")
        with zipfile.ZipFile(archive) as previous:
            return {name: previous.read(name) for name in previous.namelist()
                    if name.startswith(("versions/", "platform/")) and not name.endswith("/")}
    # First migration: retain the platform URLs from the actually deployed site.
    deployments = api(f"repos/{REPO}/deployments?environment=github-pages&per_page=100")
    deployed = None
    for deployment in deployments:
        statuses = api(deployment["statuses_url"])
        if statuses and statuses[0]["state"] == "success":
            deployed = deployment["sha"]
            break
    if deployed is None:
        if deployments:
            raise ValueError("cannot identify the deployed Pages generation")
        return {}
    artifacts = api(f"repos/{REPO}/actions/artifacts?name=github-pages-dist&per_page=100")["artifacts"]
    matching = [artifact for artifact in artifacts if not artifact["expired"] and artifact["workflow_run"]["head_sha"] == deployed]
    if not matching:
        raise ValueError("retain the deployed platform downloads before migrating: site artifact unavailable")
    archive = output / "legacy.zip"
    with archive.open("wb") as target:
        subprocess.run(["gh", "api", matching[0]["archive_download_url"]], stdout=target, check=True)
    with zipfile.ZipFile(archive) as previous:
        return {name: previous.read(name) for name in previous.namelist()
                if name.startswith("platform/") and not name.endswith("/")}


def build(directory: Path, roc: str):
    manifest = release.read_manifest(directory)
    release.verify_compiler(roc, manifest["compiler_pin"])
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if sha != manifest["source_sha"]:
        raise ValueError("site source differs from tested release source")
    serve.build_css("tailwindcss", skip=False)
    with tempfile.TemporaryDirectory(prefix="signals-site-") as scratch:
        temporary = Path(scratch)
        preserved = previous_downloads(temporary)
        sources = temporary / "starters"
        runtime = release.runtime_from_artifacts(directory, manifest, sources)
        www = temporary / "www"
        shutil.copytree(release.ROOT / "www", www)
        config = www / "config.toml"
        config.write_text(config.read_text() + f'\nrelease_version = "{manifest["version"]}"\nrelease_starters_url = "{manifest["assets"]["starters"]["url"]}"\nrelease_platform_url = "{manifest["assets"]["platform"]["url"]}"\n')
        for module in runtime.glob("*.mjs"):
            shutil.copyfile(module, www / "static" / module.name)
        built_wasm = temporary / "wasm"
        built_wasm.mkdir()
        with release.driver.BundleServer(directory) as server:
            local = f'http://127.0.0.1:{server.port}/{manifest["assets"]["platform"]["name"]}'
            for example in release.public_examples():
                original = sources / example.source
                compiled = temporary / "compile" / example.slug
                shutil.copytree(original.parent, compiled)
                source = compiled / "main.roc"
                source.write_text(release.replace_platform(source.read_text(), local))
                wasm = built_wasm / f"{example.slug}.wasm"
                release.driver.run([roc, "build", "--target=wasm32", "--opt=size", f"--output={wasm}", source])
                release.driver.run(["node", release.ROOT / "scripts/browser/mount_wasm_example.mjs", wasm, example.slug, "--runtime-dir", runtime])
        archive = directory / "signals-site.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as site:
            for name, data in sorted(preserved.items()):
                if name.startswith(f'versions/{manifest["version"]}/'):
                    raise ValueError("versioned site already exists")
                site.writestr(name, data)
            for prefix, base in [("current", serve.config_base_url()),
                                 (f'versions/{manifest["version"]}', serve.config_base_url() + f'/versions/{manifest["version"]}')]:
                rendered = temporary / prefix
                release.driver.run(["zola", "--root", www, "build", "--output-dir", rendered, "--base-url", base])
                for example in release.public_examples():
                    example_dir = rendered / "examples" / example.slug
                    shutil.copytree((sources / example.source).parent, example_dir / "source", dirs_exist_ok=True)
                    shutil.copyfile(built_wasm / f"{example.slug}.wasm", example_dir / "app.wasm")
                for path in sorted(rendered.rglob("*")):
                    if path.is_file():
                        site.write(path, prefix + "/" + path.relative_to(rendered).as_posix())
        manifest["site"] = {"name": archive.name, "url": f'{release.RELEASE_BASE}/{manifest["version"]}/{archive.name}', "sha256": release.digest(archive)}
        (directory / "signals-release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        with (directory / "release-notes.md").open("a") as notes:
            notes.write(f'\n- Site: {manifest["site"]["url"]} — SHA-256 `{manifest["site"]["sha256"]}`\n')


def assemble(directory: Path, output: Path):
    manifest = release.read_manifest(directory)
    site = manifest["site"]
    if release.digest(directory / site["name"]) != site["sha256"]:
        raise ValueError("site archive digest mismatch")
    if output.exists() and any(output.iterdir()):
        raise ValueError("site output must be empty")
    with tempfile.TemporaryDirectory(prefix="signals-pages-") as scratch:
        source = Path(scratch)
        release.extract(directory / site["name"], source)
        shutil.copytree(source / "current", output, dirs_exist_ok=True)
        for name in ("versions", "platform"):
            if (source / name).exists():
                shutil.copytree(source / name, output / name, dirs_exist_ok=True)
    if not (output / "index.html").is_file() or not (output / "versions" / manifest["version"] / "index.html").is_file():
        raise ValueError("assembled site is missing its landing page or versioned release")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "assemble"])
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=release.ROOT / "dist")
    parser.add_argument("--roc-bin", default="roc")
    args = parser.parse_args()
    if args.command == "build":
        build(args.directory.resolve(), release.driver.command_path(args.roc_bin))
    else:
        assemble(args.directory.resolve(), args.output.resolve())
