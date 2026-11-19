# This generic lookup adapter stays inside the script package root. The
# complete policy is the shared TSV also read by cli/ and the Node driver.
# TODO https://github.com/roc-lang/roc/issues/13195: remove the exact-a520
# development-Wasm row from compiler-profiles.tsv once the compiler is fixed.
import "../../cli/compiler-profiles.tsv" as profile_data : Str

## Internal build compatibility, not engine semantics. Each row names an
## exact compiler, target, requested option, effective option and issue. Keeping
## the entire match in one data file lets the Node CI driver use the same
## rule. Remove a row after its upstream defect is fixed; unknown compilers
## always retry the requested build. https://github.com/roc-lang/roc/issues/13195
CompilerProfile :: [].{

	## The actual optimisation mode. Native and shipping requests are unchanged
	## unless a row explicitly names them. Native-fuzz is a tooling purpose,
	## so its row cannot affect an ordinary native application build.
	effective : { compiler : Str, target : Str, requested : Str } -> Str
	effective = |given|
		match rows.find_first(|row| row.compiler == given.compiler and row.target == given.target and row.requested == given.requested) {
			Ok(row) => row.effective
			Err(_) => given.requested
		}

	## Name the unavailable profile and the actual one before compiling. This
	## skips a compiler profile, never a story, assertion or worker operation.
	notice : { compiler : Str, target : Str, requested : Str } -> Str
	notice = |given| {
		match rows.find_first(|row| row.compiler == given.compiler and row.target == given.target and row.requested == given.requested) {
			Ok(row) if row.effective != given.requested => "SKIP ${given.target} --opt=${given.requested} on ${given.compiler}: ${row.issue}; using --opt=${row.effective}, with every behavior check retained."
			_ => ""
		}
	}
}

rows = read_rows(profile_data) ?? crash "CompilerProfile: invalid or duplicate compatibility row"

## The table is checked-in build input. Refuse malformed or ambiguous rules;
## an empty table is valid when the final workaround has been removed.
read_rows : Str -> Try(List({ compiler : Str, target : Str, requested : Str, effective : Str, issue : Str }), [InvalidProfileTable])
read_rows = |text| {
	var $rows = []
	for line in text.trim().split_on("\n").drop_if(Str.is_empty) {
		row = match line.split_on("\t") {
			[compiler, target, requested, effective, issue] if !compiler.is_empty() and !target.is_empty() and !requested.is_empty() and !effective.is_empty() and !issue.is_empty() => { compiler, target, requested, effective, issue }
			_ => return Err(InvalidProfileTable)
		}
		if $rows.any(|other| other.compiler == row.compiler and other.target == row.target and other.requested == row.requested) {
			return Err(InvalidProfileTable)
		}
		$rows = $rows.append(row)
	}
	Ok($rows)
}

## Only the reproduced compiler and requested target/profile select size.
expect {
	given = { compiler: "nightly-2026-11-18-a520eed", target: "wasm32", requested: "dev" }
	[
		CompilerProfile.effective(given),
		CompilerProfile.effective({ ..given, compiler: "nightly-2026-11-19-future" }),
		CompilerProfile.effective({ ..given, target: "arm64mac" }),
		CompilerProfile.effective({ ..given, requested: "size" }),
		CompilerProfile.effective({ ..given, requested: "speed" }),
	] == ["size", "dev", "dev", "size", "speed"]
}

## Notices distinguish substituted profiles from requested builds that ran.
expect {
	given = { compiler: "nightly-2026-11-18-a520eed", target: "wasm32", requested: "dev" }
	CompilerProfile.notice(given) == "SKIP wasm32 --opt=dev on nightly-2026-11-18-a520eed: https://github.com/roc-lang/roc/issues/13195; using --opt=size, with every behavior check retained."
		and CompilerProfile.notice({ ..given, compiler: "nightly-2026-11-19-future" }) == ""
}

## Broken table rows never silently disable a workaround; removing all rows
## restores requested builds without needing a special placeholder entry.
expect {
	bad = ["a\tb\tc\td", "a\tb\tc\td\t", "a\tb\tc\t\tissue", "a\tb\tc\td\tissue\na\tb\tc\te\tissue"]
	bad.all(|text| read_rows(text).is_err()) and read_rows("") == Ok([])
}

## The fuzz fallback applies only to the exact compiler and tooling purpose.
## TODO https://github.com/roc-lang/roc/issues/13197: remove its table row
## once speed specialisation works; future compilers already retry speed.
expect {
	given = { compiler: "nightly-2026-11-18-a520eed", target: "native-fuzz", requested: "speed" }
	CompilerProfile.effective(given) == "size" and
		CompilerProfile.effective({ ..given, compiler: "nightly-2026-11-19-future" }) == "speed" and
			["arm64mac", "x64musl", "x64mac", "x64win"].all(|target| CompilerProfile.effective({ ..given, target }) == "speed") and
				CompilerProfile.notice(given) == "SKIP native-fuzz --opt=speed on nightly-2026-11-18-a520eed: https://github.com/roc-lang/roc/issues/13197; using --opt=size, with every behavior check retained."
}
