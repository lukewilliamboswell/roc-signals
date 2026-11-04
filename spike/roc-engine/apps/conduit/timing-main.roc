app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst" }

import pf.Stdout
import pf.Monotonic
import Engine
import FxSpec
import ConduitApp
import Bench

## Native timing of Conduit: the Bench scenario (mount, tags, feed of N,
## favorite, favorite-response, tag-click). Only the engine transaction
## (Engine.mount / event / result + take_cmds) is timed; locating nodes and
## decoding the DOM are outside. One line per sample: "n case nanos".

timed! : U64, FxSpec.S, Str, (Engine.App -> Engine.App) => FxSpec.S
timed! = |n, st, name, f| {
	t0 = Monotonic.now!()
	(a, c) = Engine.take_cmds(f(st.s.eng), [])
	d = Monotonic.since(Monotonic.now!(), t0)
	_ = Stdout.line!("${n.to_str()} ${name} ${d.to_nanos().to_str()}")
	FxSpec.take(st, a, c)
}

main! : List(_) => Try({}, [Exit(I32)])
main! = |_args| {
	for n in [20, 200] {
		feed = Bench.feed_json(n)
		resp = Bench.favorite_response(n)
		var $run = 0.U64
		while $run < 11 {
			view = ConduitApp.main(Bench.boot)
			t0 = Monotonic.now!()
			(a0, c0) = Engine.take_cmds(Engine.mount_with(32, view), [])
			d0 = Monotonic.since(Monotonic.now!(), t0)
			_ = Stdout.line!("${n.to_str()} mount ${d0.to_nanos().to_str()}")
			var $st = Bench.start_from(a0, c0)
			tags_id = Bench.id_of($st, 2)
			$st = timed!(n, $st, "tags", |a| Engine.result(a, tags_id, Http({ status: 200, headers: [], body: Bench.tags_json })))
			feed_id = Bench.id_of($st, 1)
			$st = timed!(n, $st, "feed", |a| Engine.result(a, feed_id, Http({ status: 200, headers: [], body: feed })))
			(fn, fh) = Bench.click_target($st, Role("button", Bench.favorite_label(n)))
			$st = timed!(n, $st, "favorite", |a| Engine.event(a, fn, fh, ""))
			fav_id = Bench.id_of($st, 3)
			$st = timed!(n, $st, "favorite-response", |a| Engine.result(a, fav_id, Http({ status: 200, headers: [], body: resp })))
			(tn, th) = Bench.click_target($st, Role("link", "signals"))
			$st = timed!(n, $st, "tag-click", |a| Engine.event(a, tn, th, ""))
			_ = $st
			$run = $run + 1
		}
	}
	Ok({})
}
