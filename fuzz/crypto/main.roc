app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Engine
import pf.SpecRunner
import pf.WebCrypto

## Generated issue, supersede, dispose, remount, lock and late-result sequences.
## The reference model keeps request identity independently of the engine.
## Every turn checks live ids, all effect counters, stored-key observation and
## the settle oracle. Injected key results traverse the real key entry and
## opaque Box storage, so allocation checking also sees stale/disposed handles.
view : {} -> Engine.Elem(Engine.Root)
view = |_| Engine.state(
	{ query: 0.U64, shown: True, key: [], failures: 0.U64, noise: 0.U64 },
	|state| Engine.element(
		"main",
		[],
		[
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, query: s.query + 1 }))], [Engine.text("issue")]),
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, shown: !s.shown }))], [Engine.text("toggle")]),
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, key: [] }))], [Engine.text("lock")]),
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, noise: s.noise + 1 }))], [Engine.text("noise")]),
			Engine.text_s(state.signal().map(|s| "${s.key.len().to_str()}/${s.failures.to_str()}")),
			Engine.when(
				state.signal().map(|s| s.shown),
				|| Engine.watch_latest(
					state.signal().map(|s| s.query),
					|query| [WebCrypto.derive_key({ password: query.to_str(), salt: List.repeat(7, 16), iterations: 1 })],
					state.on_result(
						|s, _query, result| match result {
							Ok(key) => { ..s, key: [key] }
							Err(_) => { ..s, failures: s.failures + 1 }
						},
					),
				),
				|| Engine.text(""),
			),
		],
	),
)

sequence : List(U8) -> {}
sequence = |bytes| {
	program = Core.driver(Engine.program(|| view({})))
	(initial, batch, initial_work) = (program.init)([])
	var $engine = initial
	var $buffer = []
	var $work = initial_work
	var $dom = Dom.apply(Dom.new({}), batch)
	var $shown = True
	var $has_key = False
	var $failures = 0.U64
	var $live = [1.U32]
	var $next = 2.U32
	var $issued = 1.U64
	var $delivered = 0.U64
	var $cancelled = 0.U64
	var $stale = 0.U64
	for byte in bytes {
		op = byte % 6
		id = (byte // 6).to_u32() % $next + 1
		var $issues = False
		var $cancels = False
		(engine, commands, work) = if op == 3 or op == 4 {
			if $live.contains(id) {
				$live = []
				$delivered = $delivered + 1
				if op == 3 {
					$has_key = True
				} else {
					$failures = $failures + 1
				}
			} else {
				$stale = $stale + 1
			}
			if op == 3 {
				(program.key)($engine, $buffer, $work, 0xffffffff, id, [27], [Box.box(id.to_u64())])
			} else {
				(program.event)($engine, $buffer, $work, 0xffffffff, id, [30, 6])
			}
		} else {
			label = match op {
				0 => {
					$issues = $shown
					$cancels = $shown
					"issue"
				}
				1 => {
					$shown = !$shown
					$issues = $shown
					$cancels = True
					"toggle"
				}
				2 => {
					$has_key = False
					"lock"
				}
				_ => "noise"
			}
			index = SpecRunner.find($dom, Text(label)) ?? crash "crypto sequence button absent"
			route = Dom.target($dom, index, "click", True) ?? crash "crypto sequence route absent"
			(program.event)($engine, $buffer, $work, route.node, route.handler, [0, 0])
		}
		if $cancels {
			$cancelled = $cancelled + $live.len()
			$live = []
		}
		if $issues {
			$live = [$next]
			$next = $next + 1
			$issued = $issued + 1
		}
		$dom = Dom.apply($dom, commands)
		stats = Core.fx_stats(engine)
		actual = { live: Core.fx_live(engine), text: Dom.text_of($dom, $dom.root), issued: stats.issued, delivered: stats.delivered, cancelled: stats.cancelled, stale: stats.stale, refused: stats.refused, reparented: stats.reparented, skipped: stats.skipped }
		expected = { live: $live, text: "issuetogglelocknoise${if ($has_key) "1" else "0"}/${$failures.to_str()}", issued: $issued, delivered: $delivered, cancelled: $cancelled, stale: $stale, refused: 0.U64, reparented: 0.U64, skipped: 0.U64 }
		if actual != expected {
			crash "crypto sequence: ${Str.inspect(actual)} expected ${Str.inspect(expected)}"
		}
		if (program.settled)(engine).is_err() {
			crash "crypto turn left a reader unsettled"
		}
		$engine = engine
		$buffer = commands
		$work = work
	}
	{}
}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	sequence(bytes)
	Fuzz.keep
}

target = Fuzz.target_with({
	name: "crypto",
	generator: Fuzz.list(Fuzz.u8, 128),
	test,
	show: Str.inspect,
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "key-lock-late", revision: "1", make: || [3, 2, 3, 0, 9, 2, 5] }),
		Fuzz.example({ name: "cancel-dispose-remount", revision: "1", make: || [0, 3, 1, 9, 1, 15, 2, 4, 0, 21] }),
		Fuzz.example({
			name: "all-operations",
			revision: "1",
			make: || {
				var $all = []
				for i in 0.U64..<128 {
					$all = $all.append(i.to_u8_wrap())
				}
				$all
			},
		}),
	],
})
