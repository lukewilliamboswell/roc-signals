import pf.Core
import pf.Dom
import pf.SpecRunner

## An independent step-number oracle for keep_current. The implementation's
## current-id index is never read: the model labels each offer with the step
## that issued it, and freezes that standing when its scope is disposed.
CurrentModel := [].{
	run : List(U8) -> {}
	run = |bytes| run_sequence(bytes)
}

Answer : [Answered({ slot : U64, status : U64 }), Follow]

Failure : { slot : U64, reason : Core.HttpFailure }

S : { question : U64, shown : Bool, answered : U64, progress : U64 }

Live : { id : U32, question : U64, slot : U64, step : U64, orphan : Bool, standing : Bool }

Queued : { id : U32, question : U64, slot : U64, step : U64, kind : [Follow, Refused] }

M : {
	question : U64,
	shown : Bool,
	answered : U64,
	progress : U64,
	step : U64,
	next : U32,
	inner : U32,
	live : List(Live),
	queue : List(Queued),
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	reparented : U64,
	reports : U64,
	fx : List(Dom.FxCmd),
}

http_ask : { question : U64, slot : U64 } -> Core.Ask(Answer, Failure)
http_ask = |{ question, slot }| Core.http({ url: "/keep/${question.to_str()}/${slot.to_str()}" })
	.map_ok(|response| Answered({ slot, status: response.status.to_u64() }))
	.map_err(|reason| { slot, reason })

plan : U64 -> List(Core.Ask(Answer, Failure))
plan = |question| match question {
	1 => [Core.command(Replace("/keep/2")), Core.again({}).map_ok(|_| Follow), Core.again({}).map_ok(|_| Follow)]
	2 => [http_ask({ question, slot: 0 }), http_ask({ question, slot: 1 })]
	3 => [http_ask({ question, slot: 0 })]
	4 => [Core.command(Title("commands only"))]
	_ => []
}

applied : S, { question : U64, result : Try(Answer, Failure) } -> S
applied = |state, { question, result }| match result {
	Ok(Answered({ slot, status })) => { ..state, answered: state.answered + question * 10000 + slot * 100 + status }
	Ok(Follow) => { ..state, question: 2, answered: state.answered + question * 10000 + 700 }
	Err({ slot, reason: _ }) => { ..state, answered: state.answered + question * 10000 + slot * 100 + 900 }
}

page : {} -> Core.Elem(Core.Root({}))
page = |_| Core.state(
	{ question: 0.U64, shown: True, answered: 0.U64, progress: 0.U64 },
	|state| Core.element(
		"main",
		[],
		[
			Core.element("button", [Core.on_click(state.set_value(|s, payload| { ..s, question: U64.from_str(payload) ?? crash "CurrentModel: controlled question is not a number" }))], [Core.text("set")]),
			Core.element("button", [Core.on_click(state.update(|s| { ..s, shown: !s.shown }))], [Core.text("toggle")]),
			Core.element("button", [Core.on_click(state.set_value(|s, payload| { ..s, shown: False, question: U64.from_str(payload) ?? crash "CurrentModel: controlled hidden question is not a number" }))], [Core.text("hide")]),
			Core.text_s(state.signal().map(|s| "${s.question.to_str()}/${s.answered.to_str()}/${s.progress.to_str()}/${if (s.shown) "shown" else "hidden"}")),
			Core.when(
				state.signal().map(|s| s.shown),
				|| Core.keep_current(
					state.signal().map(|s| s.question),
					plan,
					state.on_result(|s, question, result| applied(s, { question, result })).with_progress({ every_ms: 1 }, state.on_progress(|s, question, transfer| { ..s, progress: s.progress + question * 100 + transfer.done })),
				),
				|| Core.text(""),
			),
		],
	),
)

initial : M
initial = { question: 0, shown: True, answered: 0, progress: 0, step: 1, next: 1, inner: 2147483648, live: [], queue: [], issued: 0, delivered: 0, stale: 0, refused: 0, reparented: 0, reports: 0, fx: [] }

## A changed question starts one step. Two independent Self answers model a
## redirect-shaped command/follow-up: the first changes the question, so the
## second must be delivered without applying its older reader or reaction.
issue_step : M -> M
issue_step = |model| {
	m = { ..model, step: model.step + 1 }
	match m.question {
		1 => {
			..m,
			inner: m.inner + 2,
			fx: m.fx.append(Replace("/keep/2")),
			queue: m.queue.concat([
				{ id: m.inner, question: m.question, slot: 0, step: m.step, kind: Follow },
				{ id: m.inner + 1, question: m.question, slot: 0, step: m.step, kind: Follow },
			]),
		}
		2 => offer(offer(m, 0), 1)
		3 => offer(m, 0)
		4 => { ..m, fx: m.fx.append(Title("commands only")) }
		_ => m
	}
}

offer : M, U64 -> M
offer = |model, slot| {
	id = model.next
	if model.live.len() == 2 {
		{ ..model, next: id + 1, refused: model.refused + 1, queue: model.queue.append({ id, question: model.question, slot, step: model.step, kind: Refused }) }
	} else {
		{
			..model,
			next: id + 1,
			issued: model.issued + 1,
			live: model.live.append({ id, question: model.question, slot, step: model.step, orphan: False, standing: True }),
			fx: model.fx.append(Http(id, "GET", "/keep/${model.question.to_str()}/${slot.to_str()}", [], "", 0, { cache: "default", credentials: "same-origin", progress_ms: 16 })),
		}
	}
}

change_question : M, U64 -> M
change_question = |model, question|
	if model.question == question {
		model
	} else {
		next = { ..model, question }
		if (next.shown) issue_step(next) else next
	}

hide : M, U64 -> M
hide = |model, question| {
	..model,
	question,
	shown: False,
	reparented: model.reparented + model.live.count_if(|entry| !entry.orphan),
	live: model.live.map(|entry| if (entry.orphan) entry else { ..entry, orphan: True, standing: entry.step == model.step }),
}

toggle : M -> M
toggle = |model| if (model.shown) hide(model, model.question) else issue_step({ ..model, shown: True })

## Logical step numbers are independent of the engine's indexed membership.
can_apply : M, Live -> Bool
can_apply = |model, entry| if (entry.orphan) entry.standing and entry.question == model.question else entry.step == model.step

answer : M, { id : U32, status : U64 } -> M
answer = |model, { id, status }| match model.live.find_first(|entry| entry.id == id) {
	Err(_) => { ..model, stale: model.stale + 1 }
	Ok(entry) => {
		..model,
		delivered: model.delivered + 1,
		live: model.live.keep_if(|other| other.id != id),
		answered: model.answered + if (can_apply(model, entry)) entry.question * 10000 + entry.slot * 100 + status else 0,
	}
}

report : M, { id : U32, done : U64 } -> M
report = |model, { id, done }| match model.live.find_first(|entry| entry.id == id) {
	Err(_) => { ..model, stale: model.stale + 1 }
	Ok(entry) => { ..model, reports: model.reports + 1, progress: model.progress + if (can_apply(model, entry)) entry.question * 100 + done else 0 }
}

settle : M -> M
settle = |model| {
	var $model = model
	while !$model.queue.is_empty() {
		queued = $model.queue.first() ?? crash "CurrentModel: nonempty queue"
		m = $model
		taken = { ..m, queue: m.queue.drop_first(1), delivered: m.delivered + 1 }
		$model = if queued.step != taken.step {
			taken
		} else match queued.kind {
			Follow => change_question({ ..taken, answered: taken.answered + queued.question * 10000 + 700 }, 2)
			Refused => { ..taken, answered: taken.answered + queued.question * 10000 + queued.slot * 100 + 900 }
		}
	}
	$model
}

check : Core.App, { dom : Dom.Model, effects : List(Dom.FxCmd), model : M } -> {}
check = |engine, { dom, effects, model }| {
	stats = Core.fx_stats(engine)
	actual = { live: Core.fx_live(engine), text: Dom.text_of(dom, dom.root), effects, issued: stats.issued, delivered: stats.delivered, stale: stats.stale, refused: stats.refused, cancelled: stats.cancelled, reparented: stats.reparented, skipped: stats.skipped, reports: Core.work_counters(engine).get(47) }
	wanted = { live: model.live.map(|entry| entry.id), text: "settogglehide${model.question.to_str()}/${model.answered.to_str()}/${model.progress.to_str()}/${if (model.shown) "shown" else "hidden"}", effects: model.fx, issued: model.issued, delivered: model.delivered, stale: model.stale, refused: model.refused, cancelled: 0.U64, reparented: model.reparented, skipped: 0.U64, reports: Ok(model.reports) }
	if actual != wanted {
		crash "keep_current model differs: ${Str.inspect(actual)} expected ${Str.inspect(wanted)}"
	}
	if Core.settled(engine).is_err() {
		crash "keep_current left a reader stale"
	}
	{}
}

run_sequence : List(U8) -> {}
run_sequence = |bytes| {
	(initial_engine, initial_commands) = Core.take_cmds(Core.mount_with(2, page({})), [])
	var $engine = initial_engine
	var $dom = Dom.apply(Dom.new({}), initial_commands)
	var $model = initial
	for byte in bytes {
		op = byte % 6
		argument = (byte // 6).to_u64()
		m = { ..$model, fx: [] }
		id = if (argument % 4 == 0 or m.live.is_empty()) argument.to_u32_wrap() % m.next else (m.live.get(argument % m.live.len()) ?? crash "CurrentModel: bounded live selection").id
		status = 200 + argument
		before_evaluations = Core.evals($engine)
		var $withheld = False
		(engine, next) = if op == 3 or op == 4 {
			found = m.live.find_first(|entry| entry.id == id)
			allowed = match found {
				Ok(entry) => can_apply(m, entry)
				Err(_) => False
			}
			$withheld = match found {
				Ok(entry) => !entry.orphan and !allowed
				Err(_) => False
			}
			if op == 3 {
				# Wrong-kind data for a withheld result proves its stored typed
				# reader is not evaluated, not merely that its write is ignored.
				result = if (allowed) Http({ status: status.to_u16_wrap(), headers: [], body: "answer" }) else FileBytes([7])
				(Core.result($engine, id, result), answer(m, { id, status }))
			} else {
				(Core.progress($engine, id, { direction: Receiving, done: byte.to_u64(), total: Unknown }), report(m, { id, done: byte.to_u64() }))
			}
		} else {
			(label, payload, changed) = if op == 1 {
				("toggle", "", toggle(m))
			} else if op == 2 {
				question = argument % 6
				("hide", question.to_str(), hide(m, question))
			} else {
				question = if (op == 5) m.question else argument % 6
				("set", question.to_str(), change_question(m, question))
			}
			index = SpecRunner.find($dom, Text(label)) ?? crash "CurrentModel: button absent"
			route = Dom.target($dom, index, "click", True) ?? crash "CurrentModel: handler absent"
			(Core.event($engine, route.node, route.handler, payload), changed)
		}
		(taken, commands) = Core.take_cmds(engine, [])
		(dom, _, effects) = Dom.apply_fx($dom, commands)
		settled = settle(next)
		check(taken, { dom, effects, model: settled })
		if $withheld and Core.evals(taken) != before_evaluations {
			crash "keep_current recomputed a live question for a withheld result"
		}
		$engine = taken
		$dom = dom
		$model = settled
	}
	{}
}

## ABA, empty and command-only steps, refusal, synchronous follow-up
## supersession, progress, reparenting, remount and stale results share a model.
expect CurrentModel.run([18, 22, 12, 27, 30, 3, 10, 1, 8, 39, 1, 6, 5, 4, 9, 15, 21, 24, 27]) == {}

## An old A cannot replace a newer A of the same still-live construction.
expect CurrentModel.run([18, 12, 9, 18, 9, 15]) == {}

## All requests of one step are current, including answers taken in reverse order.
expect CurrentModel.run([12, 9, 9]) == {}

## A command and two Self results admit the first reaction, whose new step
## withholds the second; old progress still counts without reaching its reader.
expect CurrentModel.run([18, 6, 16, 10, 15, 9]) == {}

## A current orphan can answer while its ancestor still asks the same question.
expect CurrentModel.run([18, 1, 10, 9]) == {}

## Changing the question while hidden makes both progress and final data inert.
expect CurrentModel.run([18, 1, 12, 10, 9]) == {}

## An older step never regains standing after disposal, even when its question returns.
expect CurrentModel.run([18, 12, 1, 18, 16, 15, 10, 9]) == {}

## A remount is a new scope; an old current orphan keeps its frozen standing
## under the same-question rule, rather than sharing the new site's generation.
expect CurrentModel.run([18, 1, 1, 9, 9]) == {}

## Empty and command-only steps invalidate every earlier live request.
expect CurrentModel.run([12, 24, 15, 9, 18, 30, 9]) == {}
