#!/usr/bin/env python3
"""Drive the window scenarios against the built GUI examples.

`gui_smoke.py` answers one question — did the application mount and render — and
that is what let a real editing-history defect survive both the semantic specs
and a screenshot of the first frame. This driver runs the `(scenario ...)` specs
stored beside each example's `(test ...)` specs in `examples-gui/<app>/specs/`:
initial, populated, selected, focused, disabled, modal, error/loading and resized
states, chosen by risk rather than by enumeration.

A scenario is written in the spec language, parsed by the engine's spec parser,
and interpreted by the GUI host against a real window. This driver owns no
grammar: it finds the scenario files, starts one host per scenario, and reads
the JSON report the host writes. On macOS it also photographs the application's
own window at the state the scenario finished in — its own window, by the
process id this driver started, never a region of the reviewer's desktop.

A scenario whose header carries `:diagnostic` documents a defect that is open
elsewhere. It is executed, and its failure is reported, but it does not fail the
run; a diagnostic that starts passing does fail the run, so a fix cannot quietly
leave a stale exclusion behind. `:on` scopes the diagnostic to systems or to the
window frame the run saw, which the report records.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

from build_gui import executable_name
from gui_suite import ROOT, examples
import spec_driver

SYSTEMS = {"linux": "Linux", "macos": "Darwin", "windows": "Windows"}


def current_system(system: str | None = None) -> str:
    """The `:on` name of this system, or of the platform name given."""
    name = system or platform.system()
    return next((key for key, value in SYSTEMS.items() if value == name), name.lower())


class Scenario:
    """One scenario file and the example it belongs to."""

    def __init__(self, app: Path, path: Path):
        self.app = app
        self.path = path
        self.name = path.stem

    def __str__(self) -> str:
        return f"{self.app.name}/{self.name}"


def scenarios(apps, patterns=()) -> list[Scenario]:
    """Collects every scenario, refusing an example that has none.

    An example with no scenarios is the state this work exists to end, so the
    absence is an error here rather than a silently shorter run.
    """
    found = []
    for app in apps:
        cases = spec_driver.select_specs(
            spec_driver.discover_specs(app / "specs"), form="scenario")
        if not cases:
            raise SystemExit(f"{app.name} has no window scenarios in {app / 'specs'}")
        for case in cases:
            scenario = Scenario(app, case.path)
            if not patterns or any(pattern in str(scenario) for pattern in patterns):
                found.append(scenario)
    if not found:
        raise SystemExit("no window scenarios matched the requested filters")
    return found


def diagnostic_for(report: dict, system: str | None = None) -> str | None:
    """The defect a run documents, if its scope covers this system and frame.

    The host copies the scenario header's `:diagnostic` and `:on` into the
    report, so this is judged from the evidence alone. A scope names systems,
    frames, or both; the run is a diagnostic when any named one matches, and an
    ordinary check otherwise.
    """
    diagnostic = report.get("diagnostic")
    if not diagnostic:
        return None
    scope = report.get("diagnostic_on") or []
    if not scope:
        return diagnostic
    if current_system(system) in scope:
        return diagnostic
    frame = report.get("frame")
    if frame and f"{frame}-frame" in scope:
        return diagnostic
    return None


def arguments_for(scenario: Scenario, report: Path) -> list[str]:
    """The host flags one scenario needs. Its size, assets and chooser answers
    come from its own header, so the host reads them; nothing is repeated here."""
    return ["--host-scenario", str(scenario.path.resolve()),
            "--host-scenario-report", str(report.resolve())]


def run_scenario(executable: Path, scenario: Scenario, artifacts: Path,
                 capture: bool, environment=None) -> tuple[bool, str, dict]:
    """Runs one scenario: whether it passed, what it reported, and the report."""
    report = artifacts / f"{scenario.name}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    arguments = arguments_for(scenario, report)
    if capture:
        import gui_capture

        def reported_size():
            if not report.is_file():
                return False
            window = json.loads(report.read_text(encoding="utf-8"))["window"]
            return f"{window[0]}x{window[1]}"

        gui_capture.capture(
            executable, artifacts / f"{scenario.name}.png", None,
            settle=0.4, arguments=[*arguments, "--host-scenario-hold"],
            environment=environment, ready=reported_size,
        )
    else:
        command = [str(executable.resolve()), *arguments]
        print("==> " + " ".join(command), flush=True)
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                   errors="replace", timeout=180, env=environment)
        # A scenario that closes its window leaves the report first and then
        # the process; a crash in that teardown is only visible here, as an
        # exit the report knows nothing about. Status 1 is the host's own
        # verdict on a failed step, and the report carries that failure.
        if completed.returncode not in (0, 1):
            return False, exit_failure(completed), {}
        if not report.is_file():
            tail = [line for line in (completed.stderr or "").splitlines() if line.strip()][-3:]
            return False, "the application exited without writing a report" + (
                ": " + " | ".join(tail) if tail else ""), {}
    if not report.is_file():
        return False, "the application exited without writing a report", {}
    observed = json.loads(report.read_text(encoding="utf-8"))
    return bool(observed["passed"]), observed.get("failure", ""), observed


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
    import time

    selected = scenarios(apps if apps is not None else examples(), patterns)
    failures, unexpected, reproduced = [], [], []
    started = time.monotonic()
    for scenario in selected:
        scenario_started = time.monotonic()
        executable = directory / executable_name(scenario.app.name)
        if not executable.is_file():
            raise SystemExit(f"build the GUI examples first: {executable} is missing")
        destination = artifacts / scenario.app.name
        print(f"\n--- {scenario}", flush=True)
        passed, failure, report = run_scenario(executable, scenario, destination, capture,
                                               environment)
        diagnostic = diagnostic_for(report)
        elapsed = f" ({time.monotonic() - scenario_started:.1f}s)"
        if diagnostic is None:
            print("    " + ("passed" if passed else f"FAILED: {failure}") + elapsed, flush=True)
            if not passed:
                failures.append(f"{scenario}: {failure}")
        elif passed:
            print("    unexpectedly passed", flush=True)
            unexpected.append(str(scenario))
        else:
            print(f"    reproduced the known defect: {failure}", flush=True)
            reproduced.append(f"{scenario}: {diagnostic}")
    # Wall time is the number every later change to waiting and settling is
    # judged against, so it is printed with the verdicts rather than guessed at.
    print(f"\n{len(selected)} scenarios in {time.monotonic() - started:.1f}s; "
          f"artifacts in {artifacts}", flush=True)
    for entry in reproduced:
        print("  diagnostic still open: " + entry, flush=True)
    problems = [f"scenario: {entry}" for entry in failures]
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
                        default=ROOT / ".test-out/gui-scenarios",
                        help="Where reports and window captures are written")
    parser.add_argument("--scenario", action="append", default=[], metavar="SUBSTRING",
                        help="Run only scenarios whose app/name contains this. Repeatable.")
    parser.add_argument("--no-capture", action="store_true",
                        help="Run the scenarios without photographing the window")
    parser.add_argument("--wayland", action="store_true",
                        help="Run Weston on the supplied X display; use xvfb-run for CI")
    args = parser.parse_args()
    capture = not args.no_capture and sys.platform == "darwin"
    if not args.no_capture and not capture:
        # Say which half is running. A harness that quietly skipped its captures
        # would report a pass for evidence it never gathered.
        print("window captures are implemented for macOS only; running scenarios alone",
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
