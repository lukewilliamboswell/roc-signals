app [target] { pf: platform "../../platform/fuzz.roc" }

import pf.Core
import pf.Fuzz
import pf.Scm
import pf.Soak
import pf.SpecRunner
import Form
import FormApp

## Form Builder on the Roc-owned engine.
## - specs: run through main.roc (events in,
##   decoded DOM out); any mismatch crashes with the spec and step.
## - generated: random sequences of designer/preview edits checked against a
##   reference model of the schema/answers (the DOM's field order, labels,
##   summaries, verdicts and counts must match the pure Form functions).

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

Input : { mode : U8, size : U64, program : List(U8) }

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [Fill(Label("Answer f1"), "Ada"), Fill(Label("Answer f1"), ""), Click(Role({ role: "button", name: "Move up f2" })), Click(Role({ role: "button", name: "Move up f1" }))]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, settled after every event, which must free everything it
## allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(Core.driver(FormApp.program), SpecRunner.mount(Core.driver(FormApp.program), "/", []), program, Soak.settled(Core.driver(FormApp.program))))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (settle-checked and leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(Core.driver(FormApp.program), SpecRunner.mount(Core.driver(FormApp.program), "/", []), 7, 10000, Soak.settled(Core.driver(FormApp.program))))
	(s1, evs) = Soak.triples(Core.driver(FormApp.program), SpecRunner.mount(Core.driver(FormApp.program), "/", []), cycle, Soak.settled(Core.driver(FormApp.program)))
	counts = Soak.replay!(Core.driver(FormApp.program), s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
	match Soak.flat(counts, 2) {
		Ok(_) => {}
		Err(m) => crash m
	}
	Fuzz.mark!("soak cycle net live bytes ${Str.inspect(counts.sublist({ start: 0, len: 4 }))} ... (${counts.len().to_str()} cycles)")
	Fuzz.keep
}

## Soak probes: a measured region around one cycle; its net live bytes.
begin! : {} => Fuzz.Measurement
begin! = |_| Fuzz.start_measure!("cycle")

net_bytes! : Fuzz.Measurement => I64
net_bytes! = |w| {
	stats = w.finish!()
	stats.exit_live_bytes.to_i64_wrap() - stats.entry_live_bytes.to_i64_wrap()
}

## Engine mount alone at n fields (measured), no DOM model.
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
test! = |{ mode, size, program }| {
	if mode == 2 {
		soak_walk!(program)
	} else if mode == 4 {
		mount_only!(size)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "form-builder",
	examples: [
		ex("soak-10k", 3, 0),
		# ~65k fields: more than 4,095 each sites (one nested each per field row);
		# engine mount only (the DOM oracle is too slow at this size)
		ex("mount-65536", 4, 65536),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
