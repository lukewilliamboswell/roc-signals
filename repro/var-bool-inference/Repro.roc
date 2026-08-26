## `var $flag = False` infers `[False, ..]`, not `Bool`, so `!$flag` fails
## method lookup even though `$flag` is assigned `True` in the same block.
##
## Upstream: not filed
##
## Reproduce with the nightly pinned in `.roc-version`:
##
##     roc check repro/var-bool-inference/Repro.roc
##
## Expected: clean. Actual: "✗ missing method ... !$flag".
Repro := {}.{
	f : U64 -> Bool
	f = |n| {
		var $flag = False
		if n > 3 {
			$flag = True
		}
		!$flag
	}
}
