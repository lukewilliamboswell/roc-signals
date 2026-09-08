#!/usr/bin/env python3
"""Publish tested artifacts or create and validate a signed release follow-up.

Run only in explicitly dispatched release jobs. Validation runs have read-only
tokens; this reporter executes the trusted release checkout, never PR code.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import time

import release

REPO = release.REPOSITORY
CHECKS = {"Published examples", "Platform source", "Release archive"}


def api(path, payload=None, method=None, missing=False):
    command = ["gh", "api", path, "-H", "X-GitHub-Api-Version: 2026-03-10"]
    if method:
        command += ["--method", method]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if missing and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(f"GitHub operation failed for {path}: {result.stderr}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def require_release_context(manifest):
    if (os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REF") != "refs/heads/main"
            or os.environ.get("NIGHTLY_VALIDATION") != "false"
            or os.environ.get("GITHUB_SHA") != manifest["source_sha"]):
        raise ValueError("release writes require an explicit main dispatch at the tested SHA")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if head != manifest["source_sha"]:
        raise ValueError("release checkout differs from tested source")


def publish(directory):
    manifest = release.read_manifest(directory)
    require_release_context(manifest)
    version = manifest["version"]
    if api(f"repos/{REPO}/git/ref/tags/{version}", missing=True) is not None or api(f"repos/{REPO}/releases/tags/{version}", missing=True) is not None:
        raise ValueError("tag or release already exists; inspect and recover the original artifacts")
    assets = [directory / item["name"] for item in manifest["assets"].values()]
    assets += [directory / "signals-release.json", directory / "signals-site.zip"]
    if not all(path.is_file() for path in assets):
        raise ValueError("release assets are incomplete")
    command = ["gh", "release", "create", version, *map(str, assets), "--repo", REPO,
               "--target", manifest["source_sha"], "--title", version,
               "--notes-file", str(directory / "release-notes.md")]
    if "-" in version:
        command += ["--prerelease", "--latest=false"]
    subprocess.run(command, check=True)
    tag = api(f"repos/{REPO}/git/ref/tags/{version}")
    if tag["object"]["sha"] != manifest["source_sha"]:
        raise ValueError("published tag does not identify the tested commit")


def create_followup(directory):
    manifest = release.read_manifest(directory)
    require_release_context(manifest)
    base = api(f"repos/{REPO}/git/ref/heads/main")["object"]["sha"]
    if base != manifest["source_sha"]:
        raise ValueError("main moved after release validation; prepare a reviewed follow-up against current source")
    version = manifest["version"]
    branch = f"release/{version}-examples"
    if api(f"repos/{REPO}/git/ref/heads/{branch}", missing=True) is not None:
        raise ValueError("follow-up branch already exists; do not overwrite its work")
    changes = {}
    for example in release.public_examples():
        source = (release.ROOT / example.source).read_text()
        changes[str(example.source)] = release.replace_platform(source, manifest["assets"]["platform"]["url"])
    changes["releases/current.json"] = json.dumps(manifest, indent=2) + "\n"
    api(f"repos/{REPO}/git/refs", {"ref": "refs/heads/" + branch, "sha": base})
    result = api("graphql", {
        "query": "mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",
        "variables": {"input": {"branch": {"repositoryNameWithOwner": REPO, "branchName": branch},
            "expectedHeadOid": base, "message": {"headline": f"Use Roc Signals {version} in public examples"},
            "fileChanges": {"additions": [{"path": path, "contents": base64.b64encode(content.encode()).decode()}
                                           for path, content in changes.items()]}}}})
    sha = result["data"]["createCommitOnBranch"]["commit"]["oid"]
    if not api(f"repos/{REPO}/commits/{sha}")["commit"]["verification"]["verified"]:
        raise ValueError("follow-up commit is not verified signed")
    pr = api(f"repos/{REPO}/pulls", {"head": branch, "base": "main", "title": f"Use Roc Signals {version} in public examples",
              "body": f"Pin public platform URLs to the tested {version} release and record the supported site release. Compiler pins are preserved. Explicit validation is dispatched for `{sha}`; merge after its required checks pass."})
    validate(branch, sha)
    print(pr["html_url"])


def validate(branch, sha):
    runs = []
    for context in CHECKS:
        api(f"repos/{REPO}/statuses/{sha}", {"state": "pending", "context": context, "description": "Validating signed release follow-up"})
    try:
        for workflow in ("ci.yml", "release.yml"):
            run = api(f"repos/{REPO}/actions/workflows/{workflow}/dispatches", {"ref": branch, "inputs": {"nightly_validation": True}})
            runs.append(run["workflow_run_id"])
        deadline = time.monotonic() + 85 * 60
        while time.monotonic() < deadline:
            results = [api(f"repos/{REPO}/actions/runs/{run}") for run in runs]
            if any(run["head_sha"] != sha or run["head_branch"] != branch or run["event"] != "workflow_dispatch" for run in results):
                raise ValueError("follow-up run identity mismatch")
            if api(f"repos/{REPO}/git/ref/heads/{branch}")["object"]["sha"] != sha:
                raise ValueError("follow-up branch moved during validation")
            if all(run["status"] == "completed" for run in results):
                if any(run["conclusion"] != "success" for run in results):
                    raise ValueError("follow-up validation failed")
                jobs = []
                for run in runs:
                    page = 1
                    while True:
                        batch = api(f"repos/{REPO}/actions/runs/{run}/jobs?per_page=100&page={page}")["jobs"]
                        jobs.extend(batch)
                        if len(batch) < 100:
                            break
                        page += 1
                for context in CHECKS:
                    matching = [job for job in jobs if job["name"] == context]
                    if not matching or any(job["conclusion"] != "success" for job in matching):
                        raise ValueError(f"missing successful required job: {context}")
                for context in CHECKS:
                    api(f"repos/{REPO}/statuses/{sha}", {"state": "success", "context": context, "description": "Exact follow-up commit passed validation"})
                return
            time.sleep(20)
        raise TimeoutError("follow-up validation exceeded 85 minutes")
    except Exception:
        for context in CHECKS:
            api(f"repos/{REPO}/statuses/{sha}", {"state": "failure", "context": context, "description": "Follow-up validation failed; inspect release run"})
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["publish", "followup"])
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "publish":
        publish(args.directory.resolve())
    else:
        create_followup(args.directory.resolve())
