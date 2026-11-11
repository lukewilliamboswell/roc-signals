app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/engine.roc",
}

import fz.Fuzz
import pf.Core
import pf.Soak
import pf.SpecRunner
import Form
import FormApp

## Form Builder:
## - generated: walks of real user events over the live DOM, two bytes per
##   event, from a fresh mount, settled after every event, which must free
##   everything they allocated; "walk-10k" is a seeded walk of 10,000 events.
## - "mount-65536": the engine alone mounts a form of 65,536 fields, more
##   than 4,095 `each` sites (one nested `each` per field row), measured.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-answer-and-reorder.scm`).

schema_of : U64 -> Form.Schema
schema_of = |n| {
	var $s = { seq: 0, fields: [] }
	var $i = 0.U64
	while $i < n {
		kind = match $i % 4 {
			0 => Form.text_kind
			1 => Form.number_kind
			2 => Form.email_kind
			_ => Form.select_kind
		}
		$s = Form.add_field($s, kind)
		$i = $i + 1
	}
	$s
}

## A walk (mode 2) or a large mount (mode 4, `size` fields).
Input : { mode : U8, size : U64, session : Soak.Session }

walk! : Soak.Session => Fuzz.Outcome
walk! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(FormApp.program), SpecRunner.mount(Core.driver(FormApp.program), "/", []), Soak.session_bytes(session), Soak.settled(Core.driver(FormApp.program))))
	Fuzz.keep
}

## Engine mount alone at n fields (measured), no DOM model: the oracle is
## too slow at this size.
mount_only! : U64 => Fuzz.Outcome
mount_only! = |n| {
	view = FormApp.main_with(schema_of(n))
	w = Fuzz.start_measure!("mount")
	(_, c) = Core.take_cmds(Core.mount(view), [])
	_ = w.finish!()
	if c.len() < n {
		crash "mount produced too few commands"
	}
	Fuzz.keep
}

test! : Input => Fuzz.Outcome
test! = |{ mode, size, session }| {
	if mode == 2 {
		walk!(session)
	} else if mode == 4 {
		mount_only!(size)
	} else {
		Fuzz.reject
	}
}

target = Fuzz.target_with!({
	name: "form-builder",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { mode: 2, size: 0, session: { program: [], seed: 7, steps: 10000 } } }),
		Fuzz.example({ name: "mount-65536", revision: "1", make: || { mode: 4, size: 65536, session: { program: [], seed: 0, steps: 0 } } }),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), session: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz }.Fuzz,
	test!,
	show: Str.inspect,
})
