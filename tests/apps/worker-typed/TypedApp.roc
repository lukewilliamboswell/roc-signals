import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Typed worker test app: `Worker` tasks whose inputs, outputs and errors
## cross as derived payloads, with no codec written here, in each shape a
## task's `run!` takes: a pure lambda, a lambda calling a pure named
## function, and a named effectful function.
## - "Query" filters a word list in a worker through `Worker.derive_when`: an
##   empty query is `Skip`, a newer query supersedes the job of an older one,
##   and the previous matches stay shown while the next job is wanted.
## - "Text" is measured through `Worker.derive`, which runs for every value,
##   the first one included.
## - "Parse" submits the text to a task that can fail through an
##   `Engine.latest` site with a typed `request` and `result`.
## - "Shout" submits the text to two tasks: one that cannot fail, and one
##   that refuses empty text with its own error and keeps its job when its
##   site is disposed.
TypedApp := [].{

	## `submitted` counts presses of "Parse" and keeps the text at the last
	## one, so editing the text alone issues nothing.
	S : { query : Str, text : Str, submitted : { n : U64, text : Str }, parsed : Str, shouted : { n : U64, text : Str }, loud : Str, checked : Str }

	Ctx : In(Root, S)

	words : List(Str)
	words = ["apple", "pear", "pineapple", "peach", "plum"]

	## A record in, a list out: a pure lambda, for a task that cannot fail.
	filter : Worker.Task({ query : Str, words : List(Str) }, List(Str), Worker.Never)
	filter = Worker.task({ name: "test.roc-signals/typed/filter", run!: |{ query, words: all }| Ok(all.keep_if(|word| word.contains(query))) })

	## A string in, a record with a nominal-free tag union out, with a
	## deadline and a cancel policy beside it.
	measure : Worker.Task(Str, { bytes : U64, kind : [Empty, Short, Long] }, Worker.Never)
	measure = Worker.task({
		name: "test.roc-signals/typed/measure",
		run!: |text| {
			bytes = text.count_utf8_bytes()
			Ok({ bytes, kind: if (bytes == 0) Empty else if (bytes < 8) Short else Long })
		},
		deadline: Ms(60000),
		on_cancel: Finish,
	})

	## A calculation that can fail with an error the app chose.
	parse : Worker.Task(Str, U64, [NotANumber(Str)])
	parse = Worker.task({ name: "test.roc-signals/typed/parse", run!: |text| U64.from_str(text).map_err(|_| NotANumber(text)) })

	## A pure named function.
	shout : Str -> Str
	shout = |text| "${text}!"

	## A lambda that calls a pure named function.
	loud : Worker.Task(Str, Str, Worker.Never)
	loud = Worker.task({ name: "test.roc-signals/typed/loud", run!: |text| Ok(TypedApp.shout(text)) })

	## A named effectful function, refusing empty text.
	check! : Str => Try(Str, [Empty])
	check! = |text| if (text == "") Err(Empty) else Ok(TypedApp.shout(text))

	## A named `=>` function as `run!`, kept running when its site goes.
	checked : Worker.Task(Str, Str, [Empty])
	checked = Worker.task({ name: "test.roc-signals/typed/checked", run!: TypedApp.check!, on_dispose: Keep })

	program : Engine.Program
	program = Engine.program(|| Engine.state({ query: "", text: "", submitted: { n: 0, text: "" }, parsed: "", shouted: { n: 0, text: "" }, loud: "", checked: "" }, TypedApp.view))
		.with_workers([TypedApp.filter.registration(), TypedApp.measure.registration(), TypedApp.parse.registration(), TypedApp.loud.registration(), TypedApp.checked.registration()])

	## Why a task that cannot fail has no answer: no `Failed` arm.
	show_error : Worker.Error(Worker.Never) -> Str
	show_error = |error| match error {
		Timeout => "timed out"
		Refused => "refused"
		Lost(_) => "lost"
	}

	show_matches : Engine.Remote(List(Str), Worker.Error(Worker.Never)) -> Str
	show_matches = |{ request, answer }| {
		head = if (request == Pending) "searching" else "idle"
		shown = match answer {
			Unanswered => "no answer"
			Answered(matches) => if (matches.is_empty()) "no matches" else Str.join_with(matches, ",")
			Failed(error) => TypedApp.show_error(error)
		}
		"${head}; ${shown}"
	}

	show_measure : Engine.Remote({ bytes : U64, kind : [Empty, Short, Long] }, Worker.Error(Worker.Never)) -> Str
	show_measure = |{ request, answer }| {
		head = if (request == Pending) "measuring" else "measured"
		shown = match answer {
			Unanswered => "nothing yet"
			Answered({ bytes, kind }) => "${bytes.to_str()} bytes, ${Str.inspect(kind)}"
			Failed(error) => TypedApp.show_error(error)
		}
		"${head}; ${shown}"
	}

	show_parsed : Try(U64, Worker.Error([NotANumber(Str)])) -> Str
	show_parsed = |outcome| match outcome {
		Ok(n) => "number ${n.to_str()}"
		Err(Failed(NotANumber(text))) => "not a number: ${text}"
		Err(Timeout) => "timed out"
		Err(Refused) => "refused"
		Err(Lost(_)) => "lost"
	}

	show_loud : Try(Str, Worker.Error(Worker.Never)) -> Str
	show_loud = |outcome| match outcome {
		Ok(text) => text
		Err(error) => TypedApp.show_error(error)
	}

	show_checked : Try(Str, Worker.Error([Empty])) -> Str
	show_checked = |outcome| match outcome {
		Ok(text) => text
		Err(Failed(Empty)) => "empty"
		Err(Timeout) => "timed out"
		Err(Refused) => "refused"
		Err(Lost(_)) => "lost"
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"typed",
			[
				Html.text_input(Engine.const("Query"), "search", v.map(|s| s.query), [], st.set_value(|s, query| { ..s, query })),
				Worker.derive_when(
					TypedApp.filter,
					v.map(|s| if (s.query == "") Skip else Run({ query: s.query, words: TypedApp.words })),
					|matches| Html.p_v(matches.map(TypedApp.show_matches), [Engine.test_id("matches")]),
				),
				Html.text_input(Engine.const("Text"), "text", v.map(|s| s.text), [], st.set_value(|s, text| { ..s, text })),
				Worker.derive(
					TypedApp.measure,
					v.map(|s| s.text),
					|measured| Html.p_v(measured.map(TypedApp.show_measure), [Engine.test_id("measure")]),
				),
				Html.button("Parse", [], st.update(|s| { ..s, submitted: { n: s.submitted.n + 1, text: s.text }, parsed: "parsing" })),
				Engine.latest(
					v.map(|s| s.submitted),
					|{ n, text }| if (n == 0) [] else [TypedApp.parse.request(text)],
					st.on_result(|s, _, res| { ..s, parsed: TypedApp.show_parsed(TypedApp.parse.result(res)) }),
				),
				Html.p_v(v.map(|s| s.parsed), [Engine.test_id("parsed")]),
				Html.button("Shout", [], st.update(|s| { ..s, shouted: { n: s.shouted.n + 1, text: s.text } })),
				Engine.latest(
					v.map(|s| s.shouted),
					|{ n, text }| if (n == 0) [] else [TypedApp.loud.request(text)],
					st.on_result(|s, _, res| { ..s, loud: TypedApp.show_loud(TypedApp.loud.result(res)) }),
				),
				Engine.latest(
					v.map(|s| s.shouted),
					|{ n, text }| if (n == 0) [] else [TypedApp.checked.request(text)],
					st.on_result(|s, _, res| { ..s, checked: TypedApp.show_checked(TypedApp.checked.result(res)) }),
				),
				Html.p_v(v.map(|s| s.loud), [Engine.test_id("loud")]),
				Html.p_v(v.map(|s| s.checked), [Engine.test_id("checked")]),
			],
		)
	}
}
