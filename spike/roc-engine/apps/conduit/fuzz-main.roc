app [target] { fuzz: platform "../../p0a/fuzzpf/main.roc" }

import fuzz.Fuzz
import Engine
import Dom
import Spec
import FxSpec
import ConduitApp
import ConduitSpecs
import Bench

## Conduit on the engine.
## - "specs": every original .scm spec replayed through FxSpec (events and
##   effect results in, decoded DOM and modelled browser out). All specs
##   run; failures are collected and reported together in one crash.
## - "bench-N": the Bench scenario with N feed articles, one measured
##   region per engine transaction (exact allocation baselines).

specs! : {} => Fuzz.Outcome
specs! = |_| {
	var $fails = []
	var $pass = 0.U64
	for (name, setup, steps) in ConduitSpecs.all {
		match FxSpec.run(ConduitApp.main, setup, steps) {
			Ok(_) => {
				$pass = $pass + 1
			}
			Err(msg) => {
				$fails = $fails.append("${name}: ${msg}")
			}
		}
	}
	# Lenient pass over the failing ones: how far they get when pending-count
	# assertions are recorded rather than fatal (design.md keeps admitted
	# effects running after disposal; this engine cancels them).
	var $notes = []
	for (name, setup, steps) in ConduitSpecs.all {
		match FxSpec.run(ConduitApp.main, setup, steps) {
			Ok(_) => {}
			Err(_) => {
				match FxSpec.run_lenient(ConduitApp.main, setup, steps) {
					Ok((_, dev)) => {
						$notes = $notes.append("${name}: completes leniently; deviations: ${Str.join_with(dev, "; ")}")
					}
					Err(msg) => {
						$notes = $notes.append("${name}: lenient replay also fails at ${msg}")
					}
				}
			}
		}
	}
	if $fails.is_empty() {
		Fuzz.keep
	} else {
		crash "conduit specs ${$pass.to_str()}/${ConduitSpecs.all.len().to_str()} pass; failures:\n${Str.join_with($fails, "\n")}\nlenient:\n${Str.join_with($notes, "\n")}"
	}
}

measured! : FxSpec.S, Str, (Engine.App -> Engine.App) => FxSpec.S
measured! = |st, name, f| {
	w = Fuzz.start_measure!(name)
	(a, c) = Engine.take_cmds(f(st.s.eng), [])
	_ = w.finish!()
	FxSpec.take(st, a, c)
}

bench! : U64 => Fuzz.Outcome
bench! = |n| {
	view = ConduitApp.main(Bench.boot)
	w = Fuzz.start_measure!("mount")
	(a0, c0) = Engine.take_cmds(Engine.mount_with(32, view), [])
	_ = w.finish!()
	var $st = Bench.start_from(a0, c0)
	tags_id = Bench.id_of($st, 2)
	$st = measured!($st, "tags", |a| Engine.result(a, tags_id, Http({ status: 200, body: Bench.tags_json })))
	feed_id = Bench.id_of($st, 1)
	feed = Bench.feed_json(n)
	$st = measured!($st, "feed", |a| Engine.result(a, feed_id, Http({ status: 200, body: feed })))
	(fn, fh) = Bench.click_target($st, Role("button", Bench.favorite_label(n)))
	$st = measured!($st, "favorite", |a| Engine.event(a, fn, fh, ""))
	fav_id = Bench.id_of($st, 3)
	resp = Bench.favorite_response(n)
	$st = measured!($st, "favorite-response", |a| Engine.result(a, fav_id, Http({ status: 200, body: resp })))
	_ = Bench.expect_visible($st, Role("button", "Unfavorite Article ${Bench.mid(n).to_str()} (${(Bench.mid(n) % 5 + 1).to_str()})"))
	(tn, th) = Bench.click_target($st, Role("link", "signals"))
	$st = measured!($st, "tag-click", |a| Engine.event(a, tn, th, ""))
	if $st.b.loc != "/roc-signals/examples-web/conduit/#/?tag=signals" {
		crash "bench: tag click went to ${$st.b.loc}"
	}
	Fuzz.keep
}

Input : { mode : U8, size : U64 }

test! : Input => Fuzz.Outcome
test! = |{ mode, size }| if mode == 0 bench!(size) else specs!({})

ex : Str, U8, U64 -> Fuzz.Example(Input)
ex = |name, mode, size| Fuzz.example({ name, revision: "1", make: || { mode, size } })

target = Fuzz.target_with!({
	name: "conduit",
	examples: [
		ex("specs", 1, 0),
		ex("bench-20", 0, 20),
		ex("bench-200", 0, 200),
	],
	generator: { mode: Fuzz.constant(1), size: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
