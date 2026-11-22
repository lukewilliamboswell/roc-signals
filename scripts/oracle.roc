#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.OsStr
import cli.Path
import src/Checks
import src/Proc

## The `oracle` task, local only and never in CI: build the Lean reference
## models under `oracle/` with the toolchain `oracle/lean-toolchain` pins,
## run their fixed checks (`lake exe check gate` in each project), check
## the structure vectors against the reference, and write every vector file
## again under `.build/oracle/`. A regenerated file that differs from the
## checked-in one fails the task, as does a proof that uses `sorry`.
## `lake` must be on the PATH (elan installs it); without it the task fails
## and names the toolchain file, it never skips.
main! : List(OsStr) => Try({}, _)
main! = |raw_args| {
	if !raw_args.map(OsStr.display).drop_if(|a| a == "--").is_empty() {
		Proc.warn!("usage: oracle.roc (it takes no arguments)")
		return Err(Exit(2))
	}
	lake_code = match Proc.output!({ program: "lake", args: ["--version"], cwd: "oracle/turns" }) {
		Ok({ code, .. }) => code
		Err(_) => 127
	}
	if lake_code != 0 {
		Proc.warn!("oracle: `lake` is not on the PATH. Install elan (https://github.com/leanprover/elan); it reads the Lean version from oracle/lean-toolchain.")
		return Err(Exit(1))
	}
	out = ".build/oracle"
	Path.create_all!(Path.utf8(out))?
	var $problems = []
	for project in ["oracle/turns", "oracle/tables"] {
		$problems = $problems.concat(build!(project)?)
	}
	if $problems.is_empty() {
		$problems = $problems.concat(step!("oracle/turns", ["exe", "check", "gate"], "turns: check gate")?)
		$problems = $problems.concat(step!("oracle/tables", ["exe", "check", "gate"], "tables: check gate")?)
		$problems = $problems.concat(step!("oracle/turns", ["exe", "vectors", "check", "../../fuzz/structure/vectors.trace", "../../fuzz/structure/vectors-bad.trace"], "turns: vectors check")?)
		$problems = $problems.concat(step!("oracle/turns", ["exe", "vectors", "structure", "../../${out}/vectors.trace", "../../${out}/vectors-bad.trace"], "turns: vectors structure")?)
		$problems = $problems.concat(step!("oracle/tables", ["exe", "vectors", "write", "../../${out}/table-changes.txt", "../../${out}/view-follow.txt"], "tables: vectors write")?)
		generated = [
			("${out}/vectors.trace", "fuzz/structure/vectors.trace"),
			("${out}/vectors-bad.trace", "fuzz/structure/vectors-bad.trace"),
			("${out}/table-changes.txt", "fuzz/table-changes/vectors.txt"),
			("${out}/view-follow.txt", "fuzz/view-follow/vectors.txt"),
		]
		for (fresh, kept) in generated {
			$problems = $problems.concat(same!(fresh, kept)?)
		}
	}
	Checks.finish!("oracle", $problems)
}

## Build one Lake project. Its output is printed; a warning that a
## declaration uses `sorry` is a problem, since every proof must be whole.
build! : Str => Try(List(Str), _)
build! = |project| {
	Proc.note!("== lake build (${project})")
	{ code, stdout } = Proc.merged!({ program: "lake", args: ["build"], cwd: project })?
	text = Str.from_utf8_lossy(stdout)
	Proc.note!(text)
	if code != 0 {
		Ok(["${project}: lake build exited with ${code.to_str()}"])
	} else if text.contains("sorry") {
		Ok(["${project}: a declaration uses sorry"])
	} else {
		Ok([])
	}
}

## Run one `lake` step in a project; a non-zero exit is a problem.
step! : Str, List(Str), Str => Try(List(Str), _)
step! = |project, args, label| {
	Proc.note!("== ${label}")
	code = Proc.status!({ program: "lake", args, cwd: project })?
	Ok(if (code == 0) [] else ["${label} exited with ${code.to_str()}"])
}

## A regenerated vector file must equal the checked-in one.
same! : Str, Str => Try(List(Str), _)
same! = |fresh, kept| {
	a = Path.read_utf8!(Path.utf8(fresh))?
	b = Path.read_utf8!(Path.utf8(kept)) ?? ""
	Ok(if (a == b) [] else ["${kept} differs from what oracle/ writes (${fresh}); the model changed: copy the regenerated file over it in the same commit as the change (oracle/README.md), or fix the model"])
}
