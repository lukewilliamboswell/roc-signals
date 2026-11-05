app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Fuzz
import pf.Engine
import ts.Dom
import ts.Scm
import ts.Soak
import ts.SpecRunner
import Notes
import NotesApp

## Field Notes on the Roc-owned engine (its specs run through
## `main-test.roc`).
## - "bench": one measured region per engine transaction through a whole
##   capture, queue, sync, edit and reorder session (exact allocations).
## - generated: explorer-driven random walks over the live DOM, with every
##   sync request answered, which must free everything they allocated.
## - "soak-10k": 10k seeded events, then a draft, filter and reorder round
##   trip 48 times on the engine alone with flat live bytes.

St : SpecRunner.S(Engine.App)

## Two restored notes: one queued, one draft.
storage : List({ key : Str, value : Str })
storage = [{ key: Notes.notes_key, value: "n0|0|1|r7|Generator hours;n1|1|0|r7|Fence line check" }]

start : {} -> St
start = |_| SpecRunner.mount(NotesApp.program, "/", storage)

## Answer every pending sync request as the server would (it echoes the
## token), a few rounds deep: a settled sync starts the next one.
answer : St -> St
answer = |s0| {
	var $s = s0
	var $round = 0.U64
	while $round < 4 {
		for p in $s.browser.pending {
			b = $s.browser
			$s = SpecRunner.deliver(NotesApp.program, { ..$s, browser: { ..b, pending: b.pending.keep_if(|q| q.id != p.id) } }, p.id, SpecRunner.encode_http(200, [], p.body))
		}
		$round = $round + 1
	}
	$s
}

## One measured engine transaction (the oracle's model kept in step).
measured! : St, Str, (Engine.App -> Engine.App) => St
measured! = |st, name, f| {
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(f(st.inst), [])
	_ = w.finish!()
	SpecRunner.take_batch(st, a, c)
}

## The DOM event a locator's element handles.
event! : St, Str, Scm.Loc, Str, Str => St
event! = |st, name, loc, ev, payload| {
	i = SpecRunner.find(st.dom, loc) ?? crash "bench ${name}: no ${Scm.show_loc(loc)}"
	(node, h) = Dom.target(st.dom, i, ev) ?? crash "bench ${name}: no ${ev} handler"
	measured!(st, name, |a| Engine.event(a, node, h, payload))
}

## Answer the latest issued request with `body`.
sync! : St, Str, Str => St
sync! = |st, name, body| {
	id = st.browser.issued.last() ?? crash "bench ${name}: nothing issued"
	measured!(st, name, |a| Engine.result(a, id, Http({ status: 200, headers: [], body })))
}

bench! : {} => Fuzz.Outcome
bench! = |_| {
	view = NotesApp.main_with(Notes.initial(Notes.stored_notes(storage.map(|{ key, value }| (key, value))), Bool.True), Bool.True)
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount(view), [])
	_ = w.finish!()
	var $st = SpecRunner.adopt(a0, c0, "/", storage)
	$st = event!($st, "type-draft", Label("Note body"), "input", "Pump pressure log")
	$st = event!($st, "save", Role({ role: "button", name: "Save note" }), "click", "")
	$st = event!($st, "queue", Role({ role: "button", name: "Queue note s1" }), "click", "")
	$st = sync!($st, "sync-n0", "n0#r7")
	$st = sync!($st, "sync-s1", "s1#r0")
	$st = event!($st, "edit-synced", Label("Body n0"), "input", "Generator hours 128")
	$st = sync!($st, "resync-n0", "n0#n0:1")
	$st = event!($st, "promote", Role({ role: "button", name: "Promote note n1" }), "click", "")
	$st = event!($st, "hide-synced", Label("Hide synced notes"), "change", "true")
	$st = event!($st, "show-synced", Label("Hide synced notes"), "change", "false")
	$st = event!($st, "pause", Label("Sync automatically"), "change", "false")
	$st = event!($st, "delete", Role({ role: "button", name: "Delete note s1" }), "click", "")
	_ = $st
	Fuzz.keep
}

## A round trip back to the initial state (soak cycle).
cycle : List(Scm.Op)
cycle = [
	Fill(Label("Note body"), "Soak note"),
	Fill(Label("Note body"), ""),
	Check(Label("Hide synced notes")),
	Uncheck(Label("Hide synced notes")),
	Click(Role({ role: "button", name: "Promote note n1" })),
	Click(Role({ role: "button", name: "Promote note n0" })),
]

## Soak, mode 2: an explorer-driven random walk (two bytes per event) from a
## fresh mount, which must free everything it allocated.
soak_walk! : List(U8) => Fuzz.Outcome
soak_walk! = |program| {
	Fuzz.expect_no_leaks!(|| Soak.walk(NotesApp.program, answer(start({})), program, answer))
	Fuzz.keep
}

## Soak, mode 3: 10k seeded random events (leak-checked), then the round trip
## 48 times on the engine alone: live allocations flat after 2 warm-up cycles.
soak_10k! : {} => Fuzz.Outcome
soak_10k! = |_| {
	Fuzz.expect_no_leaks!(|| Soak.walk_n(NotesApp.program, answer(start({})), 7, 10000, answer))
	(s1, evs) = Soak.triples(NotesApp.program, answer(start({})), cycle, |s| s)
	counts = Soak.replay!(NotesApp.program, s1.inst, evs, 48, |a, b| (a, b), begin!, net_bytes!)
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

Input : { mode : U8, size : U64, program : List(U8) }

test! : Input => Fuzz.Outcome
test! = |{ mode, program, .. }| {
	if mode == 0 {
		bench!({})
	} else if mode == 2 {
		soak_walk!(program)
	} else if mode == 3 {
		soak_10k!({})
	} else {
		Fuzz.reject
	}
}

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size, program: [] } })

target = Fuzz.target_with!({
	name: "field-notes",
	examples: [
		ex("soak-10k", 3, 0),
		ex("bench", 0, 0),
	],
	generator: { mode: Fuzz.constant(2), size: Fuzz.constant(0), program: Fuzz.list(Fuzz.u8, 400) }.Fuzz,
	test!,
	show: Str.inspect,
})
