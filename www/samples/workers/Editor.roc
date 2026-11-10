import pf.Engine exposing [Elem, In, Root, State, Val]
import pf.Html
import pf.Worker
import Words

## A text box whose analysis runs in workers: a summary that follows the
## text, a search that runs only when there is a word to find, a count that
## the user starts and cancels, and a total that can fail.
Editor := [].{

	# region model
	## What the "Count words" button last asked for. `press` numbers the
	## presses, so pressing it again for the same text counts again.
	Ask : [Idle, Count({ press : U64, text : Str })]

	## What the count shows.
	Counted : [NotCounted, Counting, Cancelled, Counted(List(Words.Frequency)), CountFailed(Worker.Error)]

	S : { text : Str, query : Str, numbers : Str, presses : U64, ask : Ask, counted : Counted }

	Ctx : In(Root, S)
	# endregion model

	# region register
	## The program both platforms run, with every worker program it asks for.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(Editor.initial, Editor.view))
			.with_workers([
				Words.summary.registration(),
				Words.find.registration(),
				Words.frequencies.registration(),
				Words.total.registration(),
			])
	# endregion register

	initial : S
	initial = { text: "the cat saw the hat", query: "", numbers: "", presses: 0, ask: Idle, counted: NotCounted }

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"editor",
			[
				Html.textarea(Engine.const("Text"), v.map(|s| s.text), [], st.set_value(|s, text| { ..s, text })),
				Editor.length(v),
				Editor.summary(v),
				Editor.find(st),
				Editor.count(st),
				Editor.total(st),
			],
		)
	}

	# region cheap
	## Counting words is quick, so it stays on the page in a `derive`.
	length : Val(Ctx, S) -> Elem(Ctx)
	length = |v|
		Engine.derive(
			v.map(|s| Words.split(s.text).len()),
			|n| Html.p_v(n.map(|count| "${count.to_str()} words"), [Engine.test_id("length")]),
		)
	# endregion cheap

	# region derive
	## The summary of the text, computed in a worker.
	summary : Val(Ctx, S) -> Elem(Ctx)
	summary = |v|
		Worker.derive(
			Words.summary,
			v.map(|s| s.text),
			|remote| Html.p_v(remote.map(Editor.show_summary), [Engine.test_id("summary")]),
		)

	## While a job is wanted, the previous answer stays and says it is being
	## updated.
	show_summary : Engine.Remote(Words.Summary, Worker.Error) -> Str
	show_summary = |{ request, answer }|
		match answer {
			Unanswered => if (request == Pending) "Analysing…" else ""
			Answered({ distinct, top }) => {
				shown = "${distinct.to_str()} different words; most used: ${top}"
				if (request == Pending) "${shown} (analysing…)" else shown
			}
			Failed(error) => Editor.problem(error)
		}
	# endregion derive

	## What to tell the user when a job produced no answer.
	problem : Worker.Error -> Str
	problem = |error|
		match error {
			Timeout => "This took too long."
			Refused => "Too much is running; edit the text to try again."
			Lost(_) => "The analysis failed."
			FileFailed(_) => "The file could not be read."
		}

	# region derive-when
	## Search the text for a word. An empty box asks nothing.
	find : State(Ctx, S) -> Elem(Ctx)
	find = |st| {
		v = st.val()
		Html.div(
			"find",
			[
				Html.text_input(Engine.const("Find"), "search", v.map(|s| s.query), [], st.set_value(|s, query| { ..s, query })),
				Worker.derive_when(
					Words.find,
					v.map(|s| if (s.query == "") Skip else Run({ text: s.text, word: s.query })),
					Editor.found,
				),
			],
		)
	}

	## The body of the search's layer, as a named function. Its context is
	## left generic: inside the layer it is `In(Ctx, Engine.Remote(List(U64), Worker.Error))`,
	## which a named body has no need to spell out.
	found : Val(ctx, Engine.Remote(List(U64), Worker.Error)) -> Elem(ctx)
	found = |remote| Html.p_v(remote.map(Editor.show_lines), [Engine.test_id("found")])

	show_lines : Engine.Remote(List(U64), Worker.Error) -> Str
	show_lines = |{ request, answer }|
		match answer {
			Unanswered => if (request == Pending) "Searching…" else ""
			Answered([]) => "Not found"
			Answered(lines) => "Lines ${Str.join_with(lines.map(|n| n.to_str()), ", ")}"
			Failed(error) => Editor.problem(error)
		}
	# endregion derive-when

	# region latest
	## Count the most used words when asked. "Cancel" stops a count that is
	## still running; editing the text starts nothing.
	count : State(Ctx, S) -> Elem(Ctx)
	count = |st| {
		v = st.val()
		Html.div(
			"count",
			[
				Html.button("Count words", [], st.update(|s| { ..s, presses: s.presses + 1, ask: Count({ press: s.presses + 1, text: s.text }), counted: Counting })),
				Html.button("Cancel", [], st.update(|s| { ..s, ask: Idle, counted: Editor.cancelled(s.counted) })),
				Engine.latest(
					v.map(|s| s.ask),
					|ask|
						match ask {
							Idle => []
							Count({ text, .. }) => [Words.frequencies.request(text)]
						},
					st.on_result(|s, _, res| { ..s, counted: Editor.counted(Words.frequencies.result(res)) }),
				),
				Html.p_v(v.map(|s| Editor.show_counted(s.counted)), [Engine.test_id("counted")]),
			],
		)
	}

	counted : Try(List(Words.Frequency), Worker.Error) -> Counted
	counted = |outcome|
		match outcome {
			Ok(top) => Counted(top)
			Err(error) => CountFailed(error)
		}
	# endregion latest

	## Cancelling changes only a count that is running.
	cancelled : Counted -> Counted
	cancelled = |c|
		match c {
			Counting => Cancelled
			other => other
		}

	show_counted : Counted -> Str
	show_counted = |c|
		match c {
			NotCounted => ""
			Counting => "Counting…"
			Cancelled => "Cancelled"
			Counted(top) => Str.join_with(top.map(|f| "${f.word} ${f.count.to_str()}"), ", ")
			CountFailed(error) => Editor.problem(error)
		}

	# region fallible-view
	## Add up the numbers in a box, in a worker.
	total : State(Ctx, S) -> Elem(Ctx)
	total = |st| {
		v = st.val()
		Html.div(
			"total",
			[
				Html.text_input(Engine.const("Numbers"), "text", v.map(|s| s.numbers), [], st.set_value(|s, numbers| { ..s, numbers })),
				Worker.derive(Words.total, v.map(|s| s.numbers), |sum| Html.p_v(sum.map(Editor.show_total), [Engine.test_id("total")])),
			],
		)
	}

	## The program's own error is an answer (`Answered(Err(...))`); a job that
	## produced no answer is `Failed`.
	show_total : Engine.Remote(Try(U64, [NotANumber(Str)]), Worker.Error) -> Str
	show_total = |{ answer, .. }|
		match answer {
			Unanswered => "Adding…"
			Answered(Ok(sum)) => "Total ${sum.to_str()}"
			Answered(Err(NotANumber(word))) => "\"${word}\" is not a number"
			Failed(Timeout) => "Adding took too long."
			Failed(Refused) => "Too much is running; edit the numbers to try again."
			Failed(Lost(_)) => "Adding failed."
			Failed(FileFailed(_)) => "The file could not be read."
		}
	# endregion fallible-view
}
