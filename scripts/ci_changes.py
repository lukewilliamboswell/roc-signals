"""Select affected CI areas; unknown paths conservatively select every area."""

import json
import os
from pathlib import Path
import subprocess
import sys

AREAS = frozenset({"source", "site"})


def verify_results(results):
    if results["changes"]["result"] != "success":
        raise ValueError("CI selection did not succeed")
    selection = results["changes"]["outputs"]
    for job in sorted(AREAS):
        enabled = selection[job]
        if enabled not in ("true", "false"):
            raise ValueError(f"invalid selection for {job}")
        expected = "success" if enabled == "true" else "skipped"
        if results[job]["result"] != expected:
            raise ValueError(f"{job}: expected {expected}, got {results[job]['result']}")
        print(f"{job}: {expected}")


def classify(paths):
    selected = set()
    for path in paths:
        if path.startswith("www/static/"):
            # The bundled browser runtime is source, not documentation.
            selected.update(AREAS)
        elif (path.startswith(("www/", "docs/", "releases/"))
              or path in {"README.md", "AGENTS.md", "design.md", "style.md", "THIRD_PARTY_LICENSES.md"}):
            selected.add("site")
        else:
            # Engine, hosts, platforms, examples, specs, tooling and unknown
            # paths all feed the hosted source tests and the published site.
            selected.update(AREAS)
    return {area: area in selected for area in sorted(AREAS)}


def changed_paths(base, head):
    # Disable rename detection so both the deleted and added locations count.
    result = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", base, head, "--",
    ])
    return [path.decode("utf-8", errors="strict") for path in result.split(b"\0") if path]


def main():
    if sys.argv[1:] == ["--verify-results"]:
        verify_results(json.loads(os.environ["RESULTS"]))
        return
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if os.environ["GITHUB_EVENT_NAME"] == "pull_request":
        pull = event["pull_request"]
        base = subprocess.check_output([
            "git", "merge-base", pull["base"]["sha"], pull["head"]["sha"],
        ], text=True).strip()
        paths = changed_paths(base, pull["head"]["sha"])
        selection = classify(paths)
    else:
        paths = []
        selection = {area: True for area in sorted(AREAS)}
    print(json.dumps({"paths": paths, "selection": selection}, indent=2))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for area, enabled in selection.items():
            output.write(f"{area}={str(enabled).lower()}\n")


if __name__ == "__main__":
    main()
