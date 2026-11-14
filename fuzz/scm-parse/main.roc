app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Scm

## The `.scm` parser is total: any text either parses or is refused with a
## position inside the text. A parsed spec has a name, at least one step, and
## every step's position lies inside the text.
test : Str -> Fuzz.Outcome
test = |text| {
	lines = text.split_on("\n").len()
	inside = |pos| pos.line >= 1 and pos.line <= lines and pos.column >= 1
	match Scm.parse(text) {
		Ok(spec) if spec.steps.is_empty() => crash "a parsed spec has no steps"
		Ok(spec) if !spec.steps.all(|s| inside(s.pos)) => crash "a step position lies outside the text"
		Ok(_) => Fuzz.keep
		Err(problem) if !inside(problem.pos) => crash "a parse error points outside the text: ${Str.inspect(problem)}"
		Err(_) => Fuzz.keep
	}
}

target = Fuzz.target_with({
	examples: [
		Fuzz.example({ name: "absence-before-and-after", revision: "1", make: || "(test \"absence\" (steps (expect-absent (test-id \"row-7\")) (expect-visible (test-id \"row-7\")) (expect-absent (test-id \"row-7\"))))" }),
		Fuzz.example({ name: "absence-key-misspelling", revision: "1", make: || "(test \"typo\" (steps (expect-visible (test-id \"row-7\")) (expect-absent (test-id \"row-8\"))))" }),
		Fuzz.example({ name: "absence-never-drawn", revision: "1", make: || "(test \"branch\" (steps (expect-absent (role button :name \"Reconnect\") :never-drawn)))" }),
		Fuzz.example({ name: "absence-redundant-marker", revision: "1", make: || "(test \"marker\" (steps (expect-absent (label \"Dialog\") :never-drawn) (expect-shown (label \"Dialog\") hidden)))" }),
		Fuzz.example({ name: "absence-layout-anchor", revision: "1", make: || "(test \"reports\" (steps (expect-absent (test-id \"end\")) (report-seen (test-id \"end\") yes 500)))" }),
		Fuzz.example({ name: "absence-focused-press", revision: "1", make: || "(test \"focus\" (steps (press \"Escape\") (expect-absent (text \"wrong\"))))" }),
		Fuzz.example({ name: "time-seed-locale", revision: "1", make: || "(test \"facts\" (setup (initial-time \"1969-12-31T23:59:59.999Z\") (seed 340282366920938463463374607431768211455) (languages \"en-AU\" \"\") (time-zone \"test\" -60 (0 90))) (steps (set-time -9223372036854775808) (advance-time 18446744073709551615)))" }),
		Fuzz.example({ name: "drafts-and-clipboard", revision: "1", make: || "(test \"draft\" (setup (session-storage \"draft\" \"saved\") (session-storage-full) (clipboard-denied) (max-paste-bytes 2)) (steps (paste-text (label \"Import\") \"λ\") (storage-elsewhere \"doc\" \"new\") (storage-elsewhere-removed \"doc\") (storage-elsewhere-cleared) (leave-page \"/next\" stay) (expect-session-storage \"draft\" \"saved\") (expect-no-session-storage \"absent\") (expect-clipboard \"copy\") (expect-clipboard-html \"<p>copy</p>\") (expect-clipboard-writes 18446744073709551615)))" }),
		Fuzz.example({ name: "minimal", revision: "1", make: || "(test \"t\" (steps (click (text \"a\"))))" }),
		Fuzz.example({ name: "setup-and-stub", revision: "2", make: || "(test \"t\" (setup (initial-location \"/x\")) (steps (stub-http \"s\" :url \"/a\" :status 200 :body \"{}\") (run-effect 1)))" }),
		Fuzz.example({ name: "unterminated", revision: "1", make: || "(test \"t\" (steps" }),
		Fuzz.example({ name: "worker-steps", revision: "1", make: || "(test \"w\" (steps (expect-pending-work \"p/q\" 2) (lose-work 1 app_crash) (time-out-work 2) (expect-metric-delta effects_refused 0)))" }),
		Fuzz.example({ name: "file-steps", revision: "1", make: || "(test \"f\" (setup (file \"a.txt\" \"text/plain\" \"ab\" 3) (file \"b.png\" \"image/png\" \"\")) (steps (choose-files (label \"Upload\") \"a.txt\" \"b.png\") (drop-files (test-id \"zone\") \"a.txt\") (paste-files (text \"here\") \"b.png\") (expect-files 3)))" }),
		Fuzz.example({ name: "report-frame", revision: "1", make: || "(test \"reports\" (steps (hold-reports) (set-online offline) (set-online online) (expect-reports-replaced 1) (release-reports)))" }),
		Fuzz.example({ name: "layout-media-reports", revision: "1", make: || "(test \"layout\" (setup (initial-media \"dark\" true)) (steps (hold-reports) (scroll (label \"List\") 20 0) (report-size (label \"List\") 640 400) (report-seen (label \"End\") yes 500) (set-media \"dark\" false) (release-reports) (expect-observed 2) (expect-media-subscriptions \"dark\" 1)))" }),
		Fuzz.example({ name: "report-bad-count", revision: "1", make: || "(test \"reports\" (steps (expect-reports-replaced -1)))" }),
	],
	name: "scm-parse",
	generator: Fuzz.str,
	test,
	show: |text| Str.inspect(text),
})
