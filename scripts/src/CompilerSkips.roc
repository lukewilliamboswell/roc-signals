## Every spec a compiler defect keeps from meaning what it says, each keyed to
## the exact compiler versions it was verified to fail on (contributing.md,
## "Compilers"). The suite prints a `SKIP` line for each one it applies and
## counts it as skipped, never as passed. On any other compiler the spec runs
## as usual, so the next nightly retries it and the skip lapses by itself
## when the fix lands; remove the entry then, with its note in design.md's
## compiler limitations. Do not add a compiler version that was not verified.
CompilerSkips := [].{

	## One skipped spec: the app (`example`, as the suite names apps) and the spec id, which runner and which build
	## skip it (only Chrome on the development Wasm build so far), the package
	## compilers (`roc version`) it fails on, the upstream issue and why.
	Skip : { example : Str, spec : Str, runner : [Browser], build : [Development], compilers : List(Str), issue : Str, link : Str, reason : Str }

	## The skips. The development Wasm backend keeps a removed `Dict` entry's
	## file handle alive until its table is dropped (roc-lang/roc#13020), so
	## these two handle-lifetime specs find live handles in Chrome on a
	## development build; natively and on an `--opt=size` build they pass,
	## and the suite runs them on that size build instead.
	skips : List(Skip)
	skips = [
		{ example: "files", spec: "table-a-record-keeps-handles-until-the-next-write", runner: Browser, build: Development, compilers: verified_13020, issue: "roc-lang/roc#13020", link: "https://github.com/roc-lang/roc/issues/13020", reason: "the development Wasm backend keeps a removed Dict entry's file handle alive" },
		{ example: "files", spec: "table-d-retained-handles-count-at-the-bound", runner: Browser, build: Development, compilers: verified_13020, issue: "roc-lang/roc#13020", link: "https://github.com/roc-lang/roc/issues/13020", reason: "the development Wasm backend keeps a removed Dict entry's file handle alive" },
	]
}

## The nightlies on which roc-lang/roc#13020 was verified to fail these specs.
verified_13020 : List(Str)
verified_13020 = ["nightly-2026-11-13-03dce41", "nightly-2026-11-14-a87808d", "nightly-2026-11-15-f25da45"]
