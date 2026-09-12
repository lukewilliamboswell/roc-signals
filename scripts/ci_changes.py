"""Select affected CI areas; unknown paths conservatively select every area."""

import json
import os
from pathlib import Path
import subprocess
import sys

AREAS = frozenset({"source", "gui", "site"})
WEB = frozenset({"source", "site"})
SHARED = WEB


def verify_results(results):
    if results["changes"]["result"] != "success":
        raise ValueError("CI selection did not succeed")
    selection = results["changes"]["outputs"]
    for job in ("source", "gui", "gui-windows", "gui-macos", "site"):
        area = "gui" if job.startswith("gui") else job
        enabled = selection[area]
        if enabled not in ("true", "false"):
            raise ValueError(f"invalid selection for {area}")
        expected = "success" if enabled == "true" else "skipped"
        if results[job]["result"] != expected:
            raise ValueError(f"{job}: expected {expected}, got {results[job]['result']}")
        print(f"{job}: {expected}")


def classify(paths):
    selected = set()
    for path in paths:
        if path.startswith(("platform-shared/", "src/signals/")):
            # Shared semantics run through both platform suites. GUI CI reuses
            # matching released hosts and otherwise builds the current sources.
            selected.update(SHARED)
            selected.add("gui")
        elif path.startswith(("src/spec/", "src/sim_dom", "protocol/")):
            # The spec parser, runner, simulated DOM and protocol manifest are
            # shared by every spec on every host.
            selected.update(AREAS)
        elif path.startswith(("platform-gui/", "crates/gpui-host/")):
            selected.add("gui")
        elif path.startswith(("examples-gui/", "test/gui/")):
            selected.add("gui")
        elif path.startswith("src/native_host"):
            # The native host is the display-free spec host for GUI apps too.
            selected.update(WEB)
            selected.add("gui")
        elif path.startswith(("platform-web/", "examples-web/", "src/wasm")):
            selected.update(WEB)
        elif path.startswith("www/static/"):
            selected.update(WEB)
        elif (path.startswith(("www/", "docs/", "releases/"))
              or path in {"README.md", "AGENTS.md", "design.md", "style.md", "THIRD_PARTY_LICENSES.md"}):
            selected.add("site")
        else:
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
