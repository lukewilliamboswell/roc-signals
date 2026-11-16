import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Payload nesting test app: worker inputs and answers nested to a depth the
## spec types into "Levels", around the payload's bound of 128 levels of
## the app's own containers (each list, set, dictionary, record, tuple and
## tag with a payload is one level).
##
## - "Send" sends a chain of that many one-payload tags to a task that
##   answers how deep it was (`test-id "sent"`): past the bound nothing is
##   sent, and the request is answered `TooDeep` at once.
## - "Ask" asks a task to answer with a chain that deep (`test-id "asked"`):
##   past the bound the worker answers `TooDeep` and is kept.
## - "Grow" asks a preparation's task over the prepared number 100 for a
##   chain of 100 plus "Levels" (`test-id "grown"`): an answer past the
##   bound leaves the prepared state for the next job.
## - "Echo nested" and "Echo fat" send a value of the measured worst shapes
##   at that many levels to a task that answers it back, so the page
##   encodes and decodes it and the worker decodes and encodes it
##   (`test-id "nested"`, `test-id "fat"`): a record holding a list of
##   itself (two levels for each record, an even count), and a tag holding a
##   seven-field record (two levels for each tag, an even count).
##
## - "Send NaN keys" sends a dictionary with that many NaN keys to a task
##   that answers how many keys it has (`test-id "nan-sent"`), and "Ask NaN
##   keys" asks a task to answer with one (`test-id "nan-asked"`). NaN is
##   unequal to itself, so a dictionary holds every one, but a payload
##   writes them alike: one crosses, and two are `NanKeys`.
##
## Each shows the depth or the size of what came back, counted on the page,
## or why nothing did.
DeepApp := [].{

	## A chain of one-payload tags: each `Link` is one level.
	Chain := [Link(Chain), End].{
		parser_for : _
		encoder_for : _
		is_eq : _
	}

	## A record holding a list of itself: each record is two levels, its
	## own and its list's.
	Nested := { items : List(Nested) }.{
		parser_for : _
		encoder_for : _
		is_eq : _
	}

	## A tag holding a seven-field record: each `Node` is two levels, the
	## tag's and its record's.
	Fat := [Node({ a : U64, b : Str, c : Bool, d : I64, e : U32, f : Str, next : Fat }), Leaf].{
		parser_for : _
		encoder_for : _
		is_eq : _
	}

	## A chain `levels` links deep.
	chain : U64 -> Chain
	chain = |levels| {
		var $value = Chain.End
		for _ in (0.U64).until(levels) {
			$value = Chain.Link($value)
		}
		$value
	}

	## How many links deep a chain is.
	chain_levels : Chain -> U64
	chain_levels = |value| {
		var $at = value
		var $levels = 0.U64
		var $more = Bool.True
		while $more {
			match $at {
				Link(inner) => {
					$at = inner
					$levels = $levels + 1
				}
				End => {
					$more = Bool.False
				}
			}
		}
		$levels
	}

	## A nested record `levels` levels deep (an even count, at least 2): the
	## innermost holds an empty list.
	nested : U64 -> Nested
	nested = |levels| {
		var $value = { items: [] }
		for _ in (0.U64).until((levels.max(2) - 2) // 2) {
			$value = { items: [$value] }
		}
		$value
	}

	## How many levels deep a nested record is.
	nested_levels : Nested -> U64
	nested_levels = |value| {
		var $at = value
		var $levels = 2.U64
		var $more = Bool.True
		while $more {
			match $at.items {
				[inner, ..] => {
					$at = inner
					$levels = $levels + 2
				}
				[] => {
					$more = Bool.False
				}
			}
		}
		$levels
	}

	## A chain of seven-field records `levels` levels deep (an even count).
	fat : U64 -> Fat
	fat = |levels| {
		var $value = Fat.Leaf
		for n in (0.U64).until(levels // 2) {
			$value = Fat.Node({ a: n, b: "node", c: Bool.True, d: -1, e: 7, f: "", next: $value })
		}
		$value
	}

	## How many levels deep a chain of records is.
	fat_levels : Fat -> U64
	fat_levels = |value| {
		var $at = value
		var $levels = 0.U64
		var $more = Bool.True
		while $more {
			match $at {
				Node({ next, .. }) => {
					$at = next
					$levels = $levels + 2
				}
				Leaf => {
					$more = Bool.False
				}
			}
		}
		$levels
	}

	## Answers how deep the chain it was sent is.
	take : Worker.Task(Chain, U64, Worker.Never)
	take = Worker.task({ name: "test.roc-signals/deep-payload/take", run!: |value| Ok(DeepApp.chain_levels(value)) })

	## Answers with a chain as deep as it is asked for.
	make : Worker.Task(U64, Chain, Worker.Never)
	make = Worker.task({ name: "test.roc-signals/deep-payload/make", run!: |levels| Ok(DeepApp.chain(levels)) })

	## Answers with the nested record it was sent.
	echo_nested : Worker.Task(Nested, Nested, Worker.Never)
	echo_nested = Worker.task({ name: "test.roc-signals/deep-payload/echo-nested", run!: |value| Ok(value) })

	## Answers with the chain of records it was sent.
	echo_fat : Worker.Task(Fat, Fat, Worker.Never)
	echo_fat = Worker.task({ name: "test.roc-signals/deep-payload/echo-fat", run!: |value| Ok(value) })

	## A dictionary with `count` NaN keys.
	nan_keyed : U64 -> Dict(F64, U8)
	nan_keyed = |count| (0.U64).until(count).fold(Dict.empty(), |keys, n| keys.insert(F64.nan, n.to_u8_wrap()))

	## Answers how many keys the dictionary it was sent has.
	count_keys : Worker.Task(Dict(F64, U8), U64, Worker.Never)
	count_keys = Worker.task({ name: "test.roc-signals/deep-payload/count-keys", run!: |keys| Ok(keys.len()) })

	## Answers with a dictionary with as many NaN keys as it is asked for.
	make_keys : Worker.Task(U64, Dict(F64, U8), Worker.Never)
	make_keys = Worker.task({ name: "test.roc-signals/deep-payload/make-keys", run!: |count| Ok(DeepApp.nan_keyed(count)) })

	## A preparation whose state is the number its text names, or
	## `NotANumber` when it names none.
	##
	## A preparation that cannot fail would name `Worker.Never`, which
	## crashes native compilation in monotype lowering
	## (https://github.com/roc-lang/roc/issues/13056).
	base : Worker.Preparation(Str, U64, [NotANumber])
	base = Worker.preparation({ name: "test.roc-signals/deep-payload/base", prepare!: |text| U64.from_str(text).map_err(|_| NotANumber) })

	## Answers with a chain as deep as the prepared number plus its input.
	grow : Worker.PreparedTask(Str, U64, U64, Chain, [NotANumber])
	grow = DeepApp.base.task({ name: "test.roc-signals/deep-payload/grow", run!: |prepared, more| Ok(DeepApp.chain(prepared + more)) })

	## The levels "Levels" holds, and how many times each button was pressed
	## with the levels at that press, so editing "Levels" alone asks nothing.
	S : { levels : Str, sent : Asked, asked : Asked, grown : Asked, nested : Asked, fat : Asked, nan_sent : Asked, nan_asked : Asked, shown : Shown }

	## A button's presses and the levels at the last one.
	Asked : { n : U64, levels : U64 }

	## What each output shows.
	Shown : { sent : Str, asked : Str, grown : Str, nested : Str, fat : Str, nan_sent : Str, nan_asked : Str }

	Ctx : In(Root, S)

	## A result as its output shows it: the depth counted on the page, or
	## why there is none.
	show : Try(a, Worker.Error(Worker.Never)), (a -> U64) -> Str
	show = |outcome, levels| DeepApp.show_as(outcome, |value| "${levels(value).to_str()} levels")

	## A result as `shown` shows it, or why there is none.
	show_as : Try(a, Worker.Error(Worker.Never)), (a -> Str) -> Str
	show_as = |outcome, shown| match outcome {
		Ok(value) => shown(value)
		Err(Timeout) => "timed out"
		Err(Refused) => "refused"
		Err(TooDeep) => "too deep"
		Err(NanKeys) => "NaN keys"
		Err(TooManyFiles) => "too many files"
		Err(Lost(fault)) => "lost ${Str.inspect(fault)}"
	}

	## A preparation's task's result as its output shows it.
	show_grown : Try(Chain, Worker.Error([NotANumber])) -> Str
	show_grown = |outcome| match outcome {
		Err(Failed(NotANumber)) => "not a number"
		Ok(value) => DeepApp.show(Ok(value), DeepApp.chain_levels)
		Err(Timeout) => "timed out"
		Err(Refused) => "refused"
		Err(TooDeep) => "too deep"
		Err(NanKeys) => "NaN keys"
		Err(TooManyFiles) => "too many files"
		Err(Lost(fault)) => "lost ${Str.inspect(fault)}"
	}

	## The press a button records: one more, at the levels now typed.
	pressed : S, Asked -> Asked
	pressed = |s, before| { n: before.n + 1, levels: U64.from_str(s.levels) ?? 0 }

	## A labelled output.
	output : State(Ctx, S), (Shown -> Str), Str -> Elem(Ctx)
	output = |st, field, id| Html.p_s(st.signal().map(|s| field(s.shown)), [Engine.test_id(id)])

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"deep-payload",
			[
				Html.text_input(Engine.const("Levels"), "text", v.map(|s| s.levels), [], st.set_value(|s, levels| { ..s, levels })),
				Html.button("Send", [], st.update(|s| { ..s, sent: DeepApp.pressed(s, s.sent), shown: { ..s.shown, sent: "sending" } })),
				Html.button("Ask", [], st.update(|s| { ..s, asked: DeepApp.pressed(s, s.asked), shown: { ..s.shown, asked: "asking" } })),
				Html.button("Grow", [], st.update(|s| { ..s, grown: DeepApp.pressed(s, s.grown), shown: { ..s.shown, grown: "growing" } })),
				Html.button("Echo nested", [], st.update(|s| { ..s, nested: DeepApp.pressed(s, s.nested), shown: { ..s.shown, nested: "echoing" } })),
				Html.button("Echo fat", [], st.update(|s| { ..s, fat: DeepApp.pressed(s, s.fat), shown: { ..s.shown, fat: "echoing" } })),
				Html.button("Send NaN keys", [], st.update(|s| { ..s, nan_sent: DeepApp.pressed(s, s.nan_sent), shown: { ..s.shown, nan_sent: "sending" } })),
				Html.button("Ask NaN keys", [], st.update(|s| { ..s, nan_asked: DeepApp.pressed(s, s.nan_asked), shown: { ..s.shown, nan_asked: "asking" } })),
				Engine.watch_latest(
					v.map(|s| s.sent),
					|{ n, levels }| if (n == 0) [] else [DeepApp.take.ask(DeepApp.chain(levels))],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, sent: DeepApp.show(res, |levels| levels) } }),
				),
				Engine.watch_latest(
					v.map(|s| s.asked),
					|{ n, levels }| if (n == 0) [] else [DeepApp.make.ask(levels)],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, asked: DeepApp.show(res, DeepApp.chain_levels) } }),
				),
				Engine.watch_latest(
					v.map(|s| s.grown),
					|{ n, levels }| if (n == 0) [] else [DeepApp.grow.ask({ init: "100", input: levels })],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, grown: DeepApp.show_grown(res) } }),
				),
				Engine.watch_latest(
					v.map(|s| s.nested),
					|{ n, levels }| if (n == 0) [] else [DeepApp.echo_nested.ask(DeepApp.nested(levels))],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, nested: DeepApp.show(res, DeepApp.nested_levels) } }),
				),
				Engine.watch_latest(
					v.map(|s| s.fat),
					|{ n, levels }| if (n == 0) [] else [DeepApp.echo_fat.ask(DeepApp.fat(levels))],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, fat: DeepApp.show(res, DeepApp.fat_levels) } }),
				),
				Engine.watch_latest(
					v.map(|s| s.nan_sent),
					|{ n, levels }| if (n == 0) [] else [DeepApp.count_keys.ask(DeepApp.nan_keyed(levels))],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, nan_sent: DeepApp.show_as(res, |count| "${count.to_str()} keys") } }),
				),
				Engine.watch_latest(
					v.map(|s| s.nan_asked),
					|{ n, levels }| if (n == 0) [] else [DeepApp.make_keys.ask(levels)],
					st.on_result(|s, _, res| { ..s, shown: { ..s.shown, nan_asked: DeepApp.show_as(res, |keys| "${keys.len().to_str()} keys") } }),
				),
				DeepApp.output(st, |s| s.sent, "sent"),
				DeepApp.output(st, |s| s.asked, "asked"),
				DeepApp.output(st, |s| s.grown, "grown"),
				DeepApp.output(st, |s| s.nested, "nested"),
				DeepApp.output(st, |s| s.fat, "fat"),
				DeepApp.output(st, |s| s.nan_sent, "nan-sent"),
				DeepApp.output(st, |s| s.nan_asked, "nan-asked"),
			],
		)
	}

	program : Engine.Program
	program = {
		none = { n: 0, levels: 0 }
		Engine.program(|| Engine.state({ levels: "", sent: none, asked: none, grown: none, nested: none, fat: none, nan_sent: none, nan_asked: none, shown: { sent: "", asked: "", grown: "", nested: "", fat: "", nan_sent: "", nan_asked: "" } }, DeepApp.view))
			.with_workers([DeepApp.take.registration(), DeepApp.make.registration(), DeepApp.echo_nested.registration(), DeepApp.echo_fat.registration(), DeepApp.count_keys.registration(), DeepApp.make_keys.registration(), DeepApp.base.registration([DeepApp.grow.registration()])])
	}
}

## The builders make what their counters count, at and past the bound.
expect {
	(DeepApp.chain_levels(DeepApp.chain(129)), DeepApp.nested_levels(DeepApp.nested(128)), DeepApp.fat_levels(DeepApp.fat(130))) == (129, 128, 130)
}
