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
SYSTEMS = {"linux": "Linux", "macos": "Darwin", "windows": "Windows"}
# A finding can belong to how the window was framed rather than to a system:
# the host draws its own frame only where the compositor delegates decorations,
# which a Wayland desktop does and Weston on Xvfb does not. The report says
# which frame the run saw, so this scope is judged after the run.
FRAMES = ("client-frame", "server-frame")


def current_system(system: str | None = None) -> str:
    """The `# diagnostic-on:` name of this system, or of the platform name given."""
    import platform

    name = system or platform.system()
    return next((key for key, value in SYSTEMS.items() if value == name), name.lower())


class Scenario:
    """One script, its window size, assets root, and any open defect it documents."""

    def __init__(self, app: Path, path: Path, system: str | None = None):
        self.app = app
        self.path = path
        self.name = path.stem
        self.size = DEFAULT_SIZE
        # Most scenarios run against the example's shipped assets. A scenario
        # about damaged assets names a prepared root instead, because a script
        # cannot damage the working tree and put it back.
        self.assets = app / "assets"
        # A native dialog cannot be driven from a script, so a scenario that
        # needs a real file or folder names it up front; the host hands each
        # path to the next chooser in order instead of prompting.
        self.choices = []
        self.diagnostic = None
        # A defect the host's chrome causes on one system, or under one window
        # frame, is not a defect elsewhere, and a diagnostic that passes fails
        # the run; naming the scope keeps the scenario an ordinary check
        # everywhere else.
        self.diagnostic_on = None
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
            elif comment.startswith("choose:"):
                choice = app / comment[len("choose:"):].strip()
                if not choice.exists():
                    raise SystemExit(f"{path}: '# choose:' names nothing on disk: {choice}")
                self.choices.append(choice)
            elif comment.startswith("diagnostic-on:"):
                scope = {word.strip().lower()
                         for word in comment[len("diagnostic-on:"):].split(",") if word.strip()}
                unknown = scope - set(SYSTEMS) - set(FRAMES)
                if not scope or unknown:
                    raise SystemExit(f"{path}: '# diagnostic-on:' expects some of "
                                     f"{', '.join((*SYSTEMS, *FRAMES))}, got "
                                     f"{sorted(unknown) or 'nothing'}")
                self.diagnostic_on = scope
            elif comment.startswith("diagnostic:"):
                note = [comment[len("diagnostic:"):].strip()]
            elif note:
                note.append(comment)
        if self.diagnostic_on is not None and not note:
            raise SystemExit(f"{path}: '# diagnostic-on:' needs a '# diagnostic:' to scope")
        if note:
            self.diagnostic = " ".join(word for word in note if word)
        self.system = current_system(system)
        if "x" not in self.size.lower():
            raise SystemExit(f"{path}: '# size:' expects WIDTHxHEIGHT")

    def diagnostic_for(self, frame: str | None) -> str | None:
        """The defect this run documents, if its scope covers this system and frame.

        A scope names systems, frames, or both; the scenario is a diagnostic
        when any named one matches, and an ordinary check otherwise.
        """
        if self.diagnostic is None:
            return None
        if self.diagnostic_on is None:
            return self.diagnostic
        if self.system in self.diagnostic_on:
            return self.diagnostic
        if frame is not None and f"{frame}-frame" in self.diagnostic_on:
            return self.diagnostic
        return None

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
    arguments = ["--host-script", str(scenario.path.resolve()),
                 "--host-script-report", str(report.resolve())]
    if scenario.assets.is_dir():
        arguments += ["--host-assets-root", str(scenario.assets.resolve())]
    for choice in scenario.choices:
        arguments += ["--host-choose", str(choice.resolve())]
    return arguments


def run_scenario(executable: Path, scenario: Scenario, artifacts: Path,
                 capture: bool, environment=None) -> tuple[bool, str, str | None]:
    """Runs one scenario: whether it passed, what it reported, and which frame it saw."""
    report = artifacts / f"{scenario.name}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    arguments = arguments_for(scenario, report)
    if capture:
        import gui_capture

        gui_capture.capture(
            executable, artifacts / f"{scenario.name}.png", scenario.size,
            settle=0.4, arguments=[*arguments, "--host-script-hold"],
            environment=environment, ready=report.is_file,
        )
    else:
        command = [str(executable.resolve()), "--host-window-size", scenario.size, *arguments]
        print("==> " + " ".join(command), flush=True)
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                   errors="replace", timeout=180, env=environment)
        # A scenario that closes its window leaves the report first and then
        # the process; a crash in that teardown is only visible here, as an
        # exit the report knows nothing about. Status 1 is the host's own
        # verdict on a failed step, and the report carries that failure.
        if completed.returncode not in (0, 1):
            return False, exit_failure(completed), None
    if not report.is_file():
        return False, "the application exited without writing a report", None
    import json

    observed = json.loads(report.read_text(encoding="utf-8"))
    return bool(observed["passed"]), observed.get("failure", ""), observed.get("frame")


def exit_failure(completed: subprocess.CompletedProcess) -> str:
    """Describes an abnormal exit, keeping the host's own last words when it left any."""
    status = completed.returncode
    if status < 0:
        detail = f"the application died from signal {-status}"
    else:
        detail = f"the application exited with status {status}"
    tail = [line for line in (completed.stderr or "").splitlines() if line.strip()][-3:]
    return detail + (": " + " | ".join(tail) if tail else "")


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
        passed, failure, *frame = run_scenario(executable, scenario, destination, capture,
                                               environment)
        diagnostic = scenario.diagnostic_for(frame[0] if frame else None)
        if diagnostic is None:
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
    parser.add_argument("--wayland", action="store_true",
                        help="Run Weston on the supplied X display; use xvfb-run for CI")
    args = parser.parse_args()
    capture = not args.no_capture and sys.platform == "darwin"
    if not args.no_capture and not capture:
        # Say which half is running. A harness that quietly skipped its captures
        # would report a pass for evidence it never gathered.
        print("window captures are implemented for macOS only; running scripts alone",
              flush=True)
    patterns = tuple(args.scenario)
    if args.wayland:
        import gui_smoke

        gui_smoke.wayland(
            args.directory,
            lambda directory, environment: run(
                directory, args.artifacts, patterns, capture, environment),
        )
        return
    run(args.directory, args.artifacts, patterns, capture, dict(os.environ))


if __name__ == "__main__":
    main()
