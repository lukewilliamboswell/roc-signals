#!/usr/bin/env python3
"""Drive scripted interaction and capture checks against the built GUI examples.

`gui_smoke.py` answers one question — did the application mount and render — and
that is what let a real editing-history defect survive both the semantic specs
and a screenshot of the first frame. This driver runs the scenarios stored beside
each example in `examples-gui/<app>/regression/*.script`: initial, populated,
selected, focused, disabled, modal, error/loading and resized states, chosen by
risk rather than by enumeration.

The scripts name controls by the application's own `test_id` or by the label a
person reads, never by pixel coordinates, so they survive layout work. Each run
writes a JSON report of every observation, and on macOS also photographs the
application's own window at the state the script finished in — its own window,
by the process id this driver started, never a region of the reviewer's desktop.

A script whose front matter carries `# diagnostic:` documents a defect that is
open elsewhere. It is executed, and its failure is reported, but it does not fail
the run; a diagnostic that starts passing does fail the run, so a fix cannot
quietly leave a stale exclusion behind.
"""

import argparse
import os
from pathlib import Path
import subprocess
import sys

from build_gui import executable_name
from gui_suite import ROOT, examples

DEFAULT_SIZE = "1200x820"


class Scenario:
    """One script, its window size, assets root, and any open defect it documents."""

    def __init__(self, app: Path, path: Path):
        self.app = app
        self.path = path
        self.name = path.stem
        self.size = DEFAULT_SIZE
        # Most scenarios run against the example's shipped assets. A scenario
        # about damaged assets names a prepared root instead, because a script
        # cannot damage the working tree and put it back.
        self.assets = app / "assets"
        self.diagnostic = None
        note = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.startswith("#"):
                break
            comment = line[1:].strip()
            if comment.startswith("size:"):
                self.size = comment[len("size:"):].strip()
            elif comment.startswith("assets:"):
                self.assets = app / comment[len("assets:"):].strip()
                if not self.assets.is_dir():
                    raise SystemExit(f"{path}: '# assets:' names no directory: {self.assets}")
            elif comment.startswith("diagnostic:"):
                note = [comment[len("diagnostic:"):].strip()]
            elif note:
                note.append(comment)
        if note:
            self.diagnostic = " ".join(word for word in note if word)
        if "x" not in self.size.lower():
            raise SystemExit(f"{path}: '# size:' expects WIDTHxHEIGHT")

    def __str__(self) -> str:
        return f"{self.app.name}/{self.name}"


def scenarios(apps, patterns=()) -> list[Scenario]:
    """Collects every scenario, refusing an example that has none.

    An example with no scenarios is the state this work exists to end, so the
    absence is an error here rather than a silently shorter run.
    """
    found = []
    for app in apps:
        directory = app / "regression"
        scripts = sorted(directory.glob("*.script")) if directory.is_dir() else []
        if not scripts:
            raise SystemExit(f"{app.name} has no regression scenarios in {directory}")
        for path in scripts:
            scenario = Scenario(app, path)
            if not patterns or any(pattern in str(scenario) for pattern in patterns):
                found.append(scenario)
    if not found:
        raise SystemExit("no GUI regression scenarios matched the requested filters")
    return found


def arguments_for(scenario: Scenario, report: Path) -> list[str]:
    """The host flags one scenario needs, including the assets root it chose."""
    # The window size is the capture harness's argument to give, so it is not
    # repeated here; a script run without a capture supplies it separately.
    arguments = ["--script", str(scenario.path.resolve()),
                 "--script-report", str(report.resolve())]
    if scenario.assets.is_dir():
        arguments += ["--assets-root", str(scenario.assets.resolve())]
    return arguments


def run_scenario(executable: Path, scenario: Scenario, artifacts: Path,
                 capture: bool, environment=None) -> tuple[bool, str]:
    """Runs one scenario, returning whether it passed and what it reported."""
    report = artifacts / f"{scenario.name}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    arguments = arguments_for(scenario, report)
    if capture:
        import gui_capture

        gui_capture.capture(
            executable, artifacts / f"{scenario.name}.png", scenario.size,
            settle=0.4, arguments=[*arguments, "--script-hold"],
            environment=environment, ready=report.is_file,
        )
    else:
        command = [str(executable.resolve()), "--window-size", scenario.size, *arguments]
        print("==> " + " ".join(command), flush=True)
        subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=180, env=environment)
    if not report.is_file():
        return False, "the application exited without writing a report"
    import json

    observed = json.loads(report.read_text(encoding="utf-8"))
    return bool(observed["passed"]), observed.get("failure", "")


def run(directory: Path, artifacts: Path, patterns=(), capture=True,
        environment=None, apps=None) -> None:
    """Runs every selected scenario and summarizes checks and diagnostics apart.

    The two groups are summarized separately on purpose: mixing a defect this
    repository already knows about into the same count as a real regression is
    how a suite stops meaning anything.
    """
    selected = scenarios(apps if apps is not None else examples(), patterns)
    failures, unexpected, reproduced = [], [], []
    for scenario in selected:
        executable = directory / executable_name(scenario.app.name)
        if not executable.is_file():
            raise SystemExit(f"build the GUI examples first: {executable} is missing")
        destination = artifacts / scenario.app.name
        print(f"\n--- {scenario} at {scenario.size}", flush=True)
        passed, failure = run_scenario(executable, scenario, destination, capture,
                                       environment)
        if scenario.diagnostic is None:
            print("    " + ("passed" if passed else f"FAILED: {failure}"), flush=True)
            if not passed:
                failures.append(f"{scenario}: {failure}")
        elif passed:
            print("    unexpectedly passed", flush=True)
            unexpected.append(str(scenario))
        else:
            print(f"    reproduced the known defect: {failure}", flush=True)
            reproduced.append(f"{scenario}: {scenario.diagnostic}")
    print(f"\n{len(selected)} scenarios; artifacts in {artifacts}", flush=True)
    for entry in reproduced:
        print("  diagnostic still open: " + entry, flush=True)
    problems = [f"regression: {entry}" for entry in failures]
    problems += [
        f"diagnostic now passes, promote it to a check: {entry}" for entry in unexpected
    ]
    if problems:
        raise SystemExit("\n".join(problems))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / ".test-out/gui",
                        help="Directory holding the built GUI examples")
    parser.add_argument("--artifacts", type=Path,
                        default=ROOT / ".test-out/gui-regression",
                        help="Where reports and window captures are written")
    parser.add_argument("--scenario", action="append", default=[], metavar="SUBSTRING",
                        help="Run only scenarios whose app/name contains this. Repeatable.")
    parser.add_argument("--no-capture", action="store_true",
                        help="Run the scripts without photographing the window")
    args = parser.parse_args()
    capture = not args.no_capture and sys.platform == "darwin"
    if not args.no_capture and not capture:
        print("window captures are implemented for macOS only; running scripts alone",
              flush=True)
    run(args.directory, args.artifacts, tuple(args.scenario), capture, dict(os.environ))


if __name__ == "__main__":
    main()
