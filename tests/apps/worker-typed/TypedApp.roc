import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Typed worker test app: `Worker` programs whose inputs and outputs cross as
## derived payloads, with no codec written here.
## - "Query" filters a word list in a worker through `Worker.derive_when`: an
##   empty query is `Skip`, a newer query supersedes the run of an older one,
##   and the previous matches stay shown while the next run is wanted.
## - "Text" is measured through `Worker.derive`, which runs for every value,
##   the first one included.
## - "Parse" submits the text to a fallible program through an `Engine.latest`
##   site with a typed `request` and `result`.
TypedApp := [].{

	## `submitted` counts presses of "Parse" and keeps the text at the last
	## one, so editing the text alone issues nothing.
	S : { query : Str, text : Str, submitted : { n : U64, text : Str }, parsed : Str }

	Ctx : In(Root, S)

	words : List(Str)
	words = ["apple", "pear", "pineapple", "peach", "plum"]

	## A record in, a list out.
	filter : Worker.Program({ query : Str, words : List(Str) }, List(Str))
	filter = Worker.pure("test.roc-signals/typed/filter", |{ query, words: all }| all.keep_if(|word| word.contains(query)))

	## A string in, a record with a nominal-free tag union out.
	measure : Worker.Program(Str, { bytes : U64, kind : [Empty, Short, Long] })
	measure = Worker.pure(
		"test.roc-signals/typed/measure",
		|text| {
			bytes = text.count_utf8_bytes()
			{ bytes, kind: if (bytes == 0) Empty else if (bytes < 8) Short else Long }
		},
	)

	## A calculation that can fail with an error the app chose.
	parse : Worker.Program(Str, Try(U64, [NotANumber(Str)]))
	parse = Worker.fallible("test.roc-signals/typed/parse", |text| U64.from_str(text).map_err(|_| NotANumber(text)))

	program : Engine.Program
	program = Engine.program(|| Engine.state({ query: "", text: "", submitted: { n: 0, text: "" }, parsed: "" }, TypedApp.view))
		.with_workers([TypedApp.filter.registration(), TypedApp.measure.registration(), TypedApp.parse.registration()])

	show_error : Worker.Error -> Str
	show_error = |error| match error {
		Timeout => "timed out"
		Refused => "refused"
		Lost(_) => "lost"
		FileFailed(_) => "unread"
	}

	show_matches : Worker.Remote(List(Str)) -> Str
	show_matches = |{ running, answer }| {
		head = if (running) "searching" else "idle"
		shown = match answer {
			Nothing => "no answer"
			Done(matches) => if (matches.is_empty()) "no matches" else Str.join_with(matches, ",")
			Failed(error) => TypedApp.show_error(error)
		}
		"${head}; ${shown}"
	}

	show_measure : Worker.Remote({ bytes : U64, kind : [Empty, Short, Long] }) -> Str
	show_measure = |{ running, answer }| {
		head = if (running) "measuring" else "measured"
		shown = match answer {
			Nothing => "nothing yet"
			Done({ bytes, kind }) => "${bytes.to_str()} bytes, ${Str.inspect(kind)}"
			Failed(error) => TypedApp.show_error(error)
		}
		"${head}; ${shown}"
	}

	show_parsed : Try(Try(U64, [NotANumber(Str)]), Worker.Error) -> Str
	show_parsed = |outcome| match outcome {
		Ok(Ok(n)) => "number ${n.to_str()}"
		Ok(Err(NotANumber(text))) => "not a number: ${text}"
		Err(error) => TypedApp.show_error(error)
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
			],
		)
	}
}
