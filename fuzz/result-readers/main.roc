app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Dom
import pf.Engine
import pf.Port
import pf.SpecRunner

## Stored result readers over generated issue, sample, dispose, progress and
## result turns. The model records the reader's marker when issued, separately
## from its issued-for value. A changed sample cannot change an old reader;
## stale results cannot apply it again. Supersession cancels live requests,
## disposal reparents HTTP requests, and a resource's retired writes are skipped.
Mode : [Posted, Latest, Resource]

Input : { mode : Mode, bytes : List(U8) }

Live : { id : U32, item : U64, marker : U64, orphan : Bool }

marker : U64 -> U64
marker = |value| value * 17 + 7

ask : U64 -> Engine.Ask(U64, [])
ask = |value| Engine.http({ url: "/reader/${value.to_str()}" })
	.map_ok(|_| marker(value))
	.map_err(|_| marker(value) + 1)
	.map(normalized)

normalized : Try(U64, U64) -> Try(U64, [])
normalized = |answer| match answer {
	Ok(value) => Ok(value)
	Err(value) => Ok(value)
}

value_of : Try(U64, []) -> U64
value_of = |answer| match answer {
	Ok(value) => value
}

view : Mode -> Engine.Elem(Engine.Root)
view = |mode| Engine.state(
	{ sample: 0.U64, query: 0.U64, posts: Engine.outbox({}), shown: True, answer: 0.U64, progress: 0.U64 },
	|state| Engine.element(
		"main",
		[],
		[
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, sample: s.sample + 1 }))], [Engine.text("sample")]),
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, query: s.query + 1, posts: s.posts.post(s.query + 1) }))], [Engine.text("issue")]),
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, shown: !s.shown }))], [Engine.text("toggle")]),
			Engine.text_s(state.signal().map(|s| "${s.answer.to_str()}/${s.progress.to_str()}")),
			Engine.when(
				state.signal().map(|s| s.shown),
				|| match mode {
					Posted => Engine.on_post_by(
						state.signal().map(|s| s.posts),
						state.signal().map(|s| s.sample),
						|sample, _| [ask(sample)],
						state.on_result(|s, item, answer| { ..s, answer: s.answer + item * 1000 + value_of(answer) }).with_progress({}, state.on_progress(|s, item, report| { ..s, progress: s.progress + item + report.done })),
					)
					Latest => Engine.watch_latest(
						state.signal().map(|s| s.query),
						|query| [ask(query)],
						state.on_result(|s, item, answer| { ..s, answer: s.answer + item * 1000 + value_of(answer) }).with_progress({}, state.on_progress(|s, item, report| { ..s, progress: s.progress + item + report.done })),
					)
					Resource => Engine.resource(
						state.signal().map(|s| s.query),
						{
							init: 0.U64,
							pending: |before, _| before,
							plan: |query| [ask(query)],
							resolve: |before, item, answer| before + item * 1000 + value_of(answer),
						},
						|reading| Engine.text_s(reading.map(|n| "r${n.to_str()}")),
					)
				},
				|| Engine.text(""),
			),
		],
	),
)

sequence : Input -> {}
sequence = |{ mode, bytes }| {
	(initial, batch) = Core.take_cmds(Core.mount_with(256, view(mode)), [])
	var $engine = initial
	var $dom = Dom.apply(Dom.new({}), batch)
	var $next = if (mode == Posted) 1.U32 else 2
	var $live = if (mode == Posted) [] else [{ id: 1.U32, item: 0.U64, marker: marker(0), orphan: False }]
	var $sample = 0.U64
	var $query = 0.U64
	var $shown = True
	var $answer = 0.U64
	var $progress = 0.U64
	var $resource = 0.U64
	var $delivered = 0.U64
	var $stale = 0.U64
	var $cancelled = 0.U64
	var $reparented = 0.U64
	var $skipped = 0.U64
	for byte in bytes {
		op = byte % 5
		id = (byte // 5).to_u32() % $next + 1
		var $issue = False
		engine = if op == 3 or (op == 4 and mode != Resource) {
			match $live.find_first(|entry| entry.id == id) {
				Err(_) => {
					$stale = $stale + 1
				}
				Ok(entry) => if op == 4 {
					$progress = $progress + entry.item + byte.to_u64()
				} else {
					$delivered = $delivered + 1
					$live = $live.keep_if(|other| other.id != id)
					value = entry.item * 1000 + entry.marker + (if (byte % 2 == 0) 1 else 0)
					if mode == Resource {
						if entry.orphan {
							$skipped = $skipped + 1
						} else {
							$resource = $resource + value
						}
					} else {
						$answer = $answer + value
					}
				}
			}
			if (op == 4) Core.progress($engine, id, { direction: Receiving, done: byte.to_u64(), total: Unknown }) else Core.result($engine, id, if (byte % 2 == 0) Timeout else Http({ status: 503, headers: [], body: "answer" }))
		} else {
			node = if op == 1 {
				$query = $query + 1
				$issue = $shown
				if $shown and mode != Posted {
					$cancelled = $cancelled + $live.count_if(|entry| !entry.orphan)
					$live = $live.keep_if(|entry| entry.orphan)
				}
				3.U32
			} else if op == 2 {
				$shown = !$shown
				if !$shown {
					$reparented = $reparented + $live.count_if(|entry| !entry.orphan)
					$live = $live.map(|entry| { ..entry, orphan: True })
				} else {
					$resource = 0
					$issue = mode != Posted
				}
				4
			} else {
				$sample = $sample + 1
				2
			}
			index = SpecRunner.find($dom, Text(if (node == 3) "issue" else if (node == 4) "toggle" else "sample")) ?? crash "reader model button absent"
			route = Dom.target($dom, index, "click", True) ?? crash "reader model route absent"
			Core.event($engine, route.node, route.handler, "")
		}
		if $issue {
			$live = $live.append({ id: $next, item: $query, marker: marker(if (mode == Posted) $sample else $query), orphan: False })
			$next = $next + 1
		}
		(taken, commands) = Core.take_cmds(engine, [])
		$dom = Dom.apply($dom, commands)
		stats = Core.fx_stats(taken)
		text = "sampleissuetoggle${$answer.to_str()}/${$progress.to_str()}${if (mode == Resource and $shown) "r${$resource.to_str()}" else ""}"
		actual = { live: Core.fx_live(taken), text: Dom.text_of($dom, $dom.root), issued: stats.issued, delivered: stats.delivered, stale: stats.stale, cancelled: stats.cancelled, reparented: stats.reparented, skipped: stats.skipped }
		wanted = { live: $live.map(|entry| entry.id), text, issued: ($next - 1).to_u64(), delivered: $delivered, stale: $stale, cancelled: $cancelled, reparented: $reparented, skipped: $skipped }
		if actual != wanted {
			crash "stored reader sequence differs: ${Str.inspect(actual)} expected ${Str.inspect(wanted)}"
		}
		if Core.settled(taken).is_err() {
			crash "stored reader turn left a reader stale"
		}
		$engine = taken
	}
	{}
}

## A subscription reader owns a large capture and a real Roc file handle box.
## One of each post's two asks is refused at admission; the other terminates.
## Neither reader may remain owned after those authoritative terminal turns.
Capture : { checksum : U64, file : Engine.File, message : U64, offset : U64 }

capture_of : Try(Capture, []) -> Capture
capture_of = |answer| match answer {
	Ok(capture) => capture
}

feed : Port.Subscription({}, U64)
feed = Port.subscription({ name: "test.roc-signals/result-reader", delivery: Every(1) })

ownership_view : {} -> Engine.Elem(Engine.Root)
ownership_view = |_| Engine.state(
	{ posts: Engine.outbox({}), serial: 0.U64, last: [] },
	|state| Engine.element(
		"main",
		[],
		[
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, serial: s.serial + 1, posts: s.posts.post(s.serial + 1) }))], [Engine.text("post")]),
			Engine.on_post(
				state.signal().map(|s| s.posts),
				|serial| [0.U64, 1].map(
					|offset| {
						buffer = List.repeat((serial + offset).to_u8_wrap(), 16384)
						file = Core.held_file(Box.box(serial * 2 + offset))
						feed.ask({}).map(
							|answer| Ok({
								checksum: buffer.fold(0.U64, |total, b| total + b.to_u64()),
								file,
								offset,
								message: match answer {
									Ok(n) => n
									Err(_) => 0
								},
							}),
						)
					},
				),
				state.on_result(
					|s, serial, answer| {
						capture = capture_of(answer)
						if capture.checksum != (serial + capture.offset).to_u8_wrap().to_u64() * 16384 {
							crash "reader capture bytes changed"
						}
						{ ..s, last: [capture.file] }
					},
				),
			),
			Engine.watch_changes(state.signal().map(|s| s.last), |files| files.map(|file| Engine.command(Engine.File.save(file, {}))), Engine.ignore({})),
		],
	),
)

ownership_round : Core.App({}), Dom.Target, U64 -> Core.App({})
ownership_round = |engine, route, round| {
	(posted, _) = Core.take_cmds(Core.event(engine, route.node, route.handler, ""), [])
	id = Core.fx_live(posted).first() ?? crash "reader admission did not retain one subscription"
	# A nonterminal message and progress-free subscription keep the reader;
	# Closed and Threw both retire it. Repeating the terminal result is stale.
	message = Core.result(posted, id, PortAnswer({ json: "7", blobs: [], files: [] }))
	if Core.fx_live(message) != [id] {
		crash "reader disappeared after a nonterminal message"
	}
	result = if (round % 2 == 0) PortFailed(Closed) else PortFailed(Threw("closed"))
	(ended, _) = Core.take_cmds(Core.result(Core.result(message, id, result), id, result), [])
	stats = Core.fx_stats(ended)
	if Core.fx_live(ended) != [] or stats.refused != round + 1 or stats.delivered != (round + 1) * 3 or stats.stale != round + 1 {
		crash "reader terminal/refusal/stale counters differ: ${Str.inspect(stats)}"
	}
	if Core.settled(ended).is_err() {
		crash "reader retirement left an unsettled engine"
	}
	ended
}

measured_round! : Core.App({}), Dom.Target, U64 => { value : Core.App({}), stats : Fuzz.Stats }
measured_round! = |engine, route, round| Fuzz.measure!("reader-retirement", || ownership_round(engine, route, round))

ownership! : U64 => {}
ownership! = |rounds| {
	program = Engine.program_boot({ storage_keys: [], max_inflight: 1 }, |_| ownership_view({})).with_ports(
		Port.registrations(
			{
				feed
			},
		),
	)
	(mounted, batch, _) = (Core.driver(program).init)([])
	dom = Dom.apply(Dom.new({}), batch)
	index = SpecRunner.find(dom, Text("post")) ?? crash "ownership post absent"
	route = Dom.target(dom, index, "click", True) ?? crash "ownership post route absent"
	var $engine = mounted
	var $live_bytes = 0.U64
	var $live_allocs = 0.U64
	for round in 0..<rounds {
		measured = measured_round!($engine, route, round)
		# Warm the bounded vectors before requiring an exact mounted plateau.
		if round > 3 and (measured.stats.exit_live_bytes != $live_bytes or measured.stats.exit_live_allocs != $live_allocs) {
			crash "terminal/refused reader capture retained while mounted: ${Str.inspect(measured.stats)} previous ${$live_bytes.to_str()}/${$live_allocs.to_str()}"
		}
		$live_bytes = measured.stats.exit_live_bytes
		$live_allocs = measured.stats.exit_live_allocs
		$engine = measured.value
	}
	# Consume the final engine, so the invocation's own leak check also sees
	# the remaining file handle, root state and all reader captures released.
	if Core.settled($engine).is_err() {
		crash "final reader engine is unsettled"
	}
	{}
}

## Replanning a current step retains the older readers until their requests
## terminate. Withheld progress and wrong-kind finals cannot run those readers;
## terminal delivery must free both the large capture and its handle box.
current_ownership_view : {} -> Engine.Elem(Engine.Root)
current_ownership_view = |_| Engine.state(
	{ query: 0.U64, last: [] },
	|state| Engine.element(
		"main",
		[],
		[
			Engine.element("button", [Engine.on_click(state.update(|s| { ..s, query: s.query + 1 }))], [Engine.text("issue current")]),
			Engine.keep_current(
				state.signal().map(|s| s.query),
				|query| if query == 0 {
					[]
				} else {
					[0.U64, 1].map(
						|offset| {
							buffer = List.repeat((query + offset).to_u8_wrap(), 16384)
							file = Core.held_file(Box.box(query * 2 + offset))
							Engine.http({ url: "/current-reader" }).map(|_| Ok({ checksum: buffer.fold(0.U64, |sum, byte| sum + byte.to_u64()), file, offset, message: 0.U64 }))
						},
					)
				},
				state.on_result(
					|s, query, answer| {
						capture = capture_of(answer)
						if capture.checksum != (query + capture.offset).to_u8_wrap().to_u64() * 16384 {
							crash "current reader used another step's capture"
						}
						{ ..s, last: [capture.file] }
					},
				).with_progress({}, state.on_progress(|s, _, _| s)),
			),
			Engine.watch_changes(state.signal().map(|s| s.last), |files| files.map(|file| Engine.command(Engine.File.save(file, {}))), Engine.ignore({})),
		],
	),
)

current_round : Core.App({}), Dom.Target -> Core.App({})
current_round = |engine, route| {
	(first, _) = Core.take_cmds(Core.event(engine, route.node, route.handler, ""), [])
	old = Core.fx_live(first)
	(second, _) = Core.take_cmds(Core.event(first, route.node, route.handler, ""), [])
	live = Core.fx_live(second)
	if old.len() != 2 or live.len() != 4 {
		crash "current requests were cancelled or not admitted"
	}
	var $engine = second
	for id in live {
		$engine = Core.progress($engine, id, { direction: Receiving, done: 1, total: Unknown })
		# A withheld request's typed HTTP reader rejects this wrong-kind data
		# if policy checks accidentally run after decoding the result.
		result = if (old.contains(id)) FileBytes([7]) else Timeout
		(taken, _) = Core.take_cmds(Core.result($engine, id, result), [])
		$engine = taken
	}
	if !Core.fx_live($engine).is_empty() or Core.settled($engine).is_err() {
		crash "current reader retirement left live or unsettled work"
	}
	$engine
}

current_ownership! : U64 => {}
current_ownership! = |rounds| {
	(mounted, batch) = Core.take_cmds(Core.mount_with(4, current_ownership_view({})), [])
	dom = Dom.apply(Dom.new({}), batch)
	index = SpecRunner.find(dom, Text("issue current")) ?? crash "current ownership button absent"
	route = Dom.target(dom, index, "click", True) ?? crash "current ownership route absent"
	var $engine = mounted
	var $bytes = 0.U64
	var $allocs = 0.U64
	for round in 0..<rounds {
		engine = $engine
		measured = Fuzz.measure!("current-reader-retirement", || current_round(engine, route))
		if round > 3 and (measured.stats.exit_live_bytes != $bytes or measured.stats.exit_live_allocs != $allocs) {
			crash "current reader captures retained while mounted: ${Str.inspect(measured.stats)} previous ${$bytes.to_str()}/${$allocs.to_str()}"
		}
		$bytes = measured.stats.exit_live_bytes
		$allocs = measured.stats.exit_live_allocs
		$engine = measured.value
	}
	stats = Core.fx_stats($engine)
	if stats.issued != rounds * 4 or stats.delivered != rounds * 4 or stats.cancelled != 0 or stats.stale != 0 {
		crash "current retirement changed request accounting: ${Str.inspect(stats)}"
	}
	{}
}

expect sequence({ mode: Posted, bytes: [1, 0, 0, 1, 4, 3, 2, 8, 9, 2, 1, 13, 14, 2, 18] }) == {}
expect sequence({ mode: Latest, bytes: [1, 0, 0, 1, 4, 3, 2, 8, 9, 2, 1, 13, 14, 2, 18] }) == {}
expect sequence({ mode: Resource, bytes: [1, 0, 0, 1, 4, 3, 2, 8, 9, 2, 1, 13, 14, 2, 18] }) == {}

## A resource result must run its stored reader without allocating its plan's
## 64 KiB capture again. This is an allocation bound, not a timing baseline.
large_ask : U64 -> Engine.Ask(U64, [])
large_ask = |value| {
	capture = List.repeat(value.to_u8_wrap(), 65536)
	Engine.http({ url: "/resource-reader" }).map(|_| Ok(capture.fold(0.U64, |sum, byte| sum + byte.to_u64())))
}

resource_result! : Core.App({}) => { value : Core.App({}), stats : Fuzz.Stats }
resource_result! = |engine| Fuzz.measure!("resource-result", || Core.result(engine, 1, Timeout))

resource_plan! : () => {}
resource_plan! = || {
	resource_view = Engine.resource(
		Engine.const(7.U64),
		{
			init: 0.U64,
			pending: |before, _| before,
			plan: |value| [large_ask(value)],
			resolve: |_, _, answer| value_of(answer),
		},
		|reading| Engine.text_s(reading.map(|value| value.to_str())),
	)
	(mounted, batch) = Core.take_cmds(Core.mount(resource_view), [])
	dom = Dom.apply(Dom.new({}), batch)
	measured = resource_result!(mounted)
	if measured.stats.requested_bytes >= 32768 {
		crash "resource result allocated a fresh reader plan: ${Str.inspect(measured.stats)}"
	}
	(after, commands) = Core.take_cmds(measured.value, [])
	shown = Dom.apply(dom, commands)
	if Dom.text_of(shown, shown.root) != "458752" or Core.settled(after).is_err() {
		crash "resource did not use its stored capture"
	}
	{}
}

## Mapping the result preserves the exact request the ask sends.
expect ask(5).sent() == Engine.http({ url: "/reader/5" }).sent()

test! : Input => Fuzz.Outcome
test! = |input| {
	rounds = 8 + input.bytes.len()
	sequence(input)
	ownership!(rounds)
	current_ownership!(rounds)
	resource_plan!()
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "result-readers",
	examples: [Posted, Latest, Resource].map(|mode| Fuzz.example({ name: "${Str.inspect(mode)}-lifetime", revision: "1", make: || { mode, bytes: [1, 0, 0, 1, 4, 3, 2, 8, 9, 2, 1, 13, 14, 2, 18, 2, 1, 23, 28, 33] } })),
	generator: { mode: Fuzz.map(Fuzz.u8, |b| if (b % 3 == 0) Posted else if (b % 3 == 1) Latest else Resource), bytes: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
