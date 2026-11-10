import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Worker

## Worker search test app: an app that computes in Web Workers the way an
## author would, with no control that poisons the page, so its specs, its
## leak-checked native soak and its Chrome soak all walk it freely.
## - A search box whose `latest` site runs the filter task on each new
##   query in a worker: only the newest query's job is in flight, and an
##   empty query cancels it.
## - A "Report" panel (a `when` branch) whose site summarises the catalogue
##   in a worker at mount, with a deadline; leaving the panel disposes the
##   site, which cancels the job. A lost or timed-out report offers a retry.
SearchApp := [].{
	S : { query : Str, results : Str, searched : Str, report : Bool, attempt : U64, summary : Str }

	Ctx : In(Root, S)

	initial : S
	initial = { query: "", results: "", searched: "", report: False, attempt: 0, summary: "" }

	catalogue : List(Str)
	catalogue = ["roc-signals", "roc-fuzz", "roc-automation", "plume", "basic-cli", "basic-webserver", "rocket", "pocket"]

	lower : List(U8) -> List(U8)
	lower = |bytes| bytes.map(|b| if (b >= 65 and b <= 90) b + 32 else b)

	contains : List(U8), List(U8) -> Bool
	contains = |hay, needle| {
		if needle.is_empty() {
			return Bool.True
		}
		var $i = 0.U64
		while $i + needle.len() <= hay.len() {
			if hay.sublist({ start: $i, len: needle.len() }) == needle {
				return Bool.True
			}
			$i = $i + 1
		}
		Bool.False
	}

	## The filter: a query in, the catalogue names that contain it (ignoring
	## ASCII case) out, joined by ", ". A pure function, which the task runs
	## and the fuzz target's walks answer jobs with.
	filter : Str -> Str
	filter = |query| {
		q = SearchApp.lower(query.to_utf8())
		hits = SearchApp.catalogue.keep_if(|name| SearchApp.contains(SearchApp.lower(name.to_utf8()), q))
		Str.join_with(hits, ", ")
	}

	## The summary: the catalogue's size and its longest name.
	summarise : {} -> Str
	summarise = |_| {
		longest = SearchApp.catalogue.fold("", |best, n| if (n.to_utf8().len() > best.to_utf8().len()) n else best)
		"${SearchApp.catalogue.len().to_str()} entries, longest ${longest}"
	}

	filter_task : Worker.Task(Str, Str, Worker.Never)
	filter_task = Worker.task({ name: "test.roc-signals/search/filter", run!: |query| Ok(SearchApp.filter(query)) })

	summarise_task : Worker.Task({}, Str, Worker.Never)
	summarise_task = Worker.task({ name: "test.roc-signals/search/summarise", run!: |input| Ok(SearchApp.summarise(input)), deadline: Ms(2000) })

	## For the fuzz target, which has no worker: the answer a job of either
	## task gives, from the pure functions the tasks run.
	stand_in : Str, List(U8), List(U8) -> List(U8)
	stand_in = |task, prep, input|
		if task == SearchApp.filter_task.name() {
			(SearchApp.filter_task.stand_in(|q| Ok(SearchApp.filter(q))))(prep, input)
		} else if task == SearchApp.summarise_task.name() {
			(SearchApp.summarise_task.stand_in(|x| Ok(SearchApp.summarise(x))))(prep, input)
		} else {
			crash "worker search: the app issued a job of an unknown task \"${task}\""
		}

	## What a finished job says, success or not.
	outcome : Try(Str, Worker.Error(Worker.Never)) -> Try(Str, Str)
	outcome = |r| match r {
		Ok(text) => Ok(text)
		Err(Lost(fault)) => Err("lost (${Str.inspect(fault)})")
		Err(Timeout) => Err("took too long")
		Err(Refused) => Err("too busy")
	}

	status : S -> Str
	status = |s|
		if s.query == "" {
			""
		} else if s.searched != s.query {
			"Searching…"
		} else if s.results == "" {
			"No matches"
		} else {
			"Found"
		}

	report_view : State(Ctx, S) -> Elem(Ctx)
	report_view = |st|
		Engine.element(
			"section",
			[Html.aria_label("Report")],
			[
				Engine.watch(
					st.val().map(|s| s.attempt),
					|_| [SearchApp.summarise_task.request({})],
					st.on_result(
						|s, _, r| {
							..s,
							summary: match SearchApp.outcome(SearchApp.summarise_task.result(r)) {
								Ok(text) => text
								Err(why) => "The report ${why}"
							},
						},
					),
				),
				Html.p_v(st.val().map(|s| if (s.summary == "") "Computing…" else s.summary), [Engine.test_id("summary")]),
				Html.button("Retry", [], st.update(|s| { ..s, attempt: s.attempt + 1, summary: "" })),
			],
		)

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"search",
			[
				Html.text_input(Engine.const("Search"), "search", v.map(|s| s.query), [], st.set_value(|s, t| { ..s, query: t })),
				Engine.latest(
					v.map(|s| s.query),
					|q| if (q == "") [] else [SearchApp.filter_task.request(q)],
					st.on_result(
						|s, q, r|
							match SearchApp.outcome(SearchApp.filter_task.result(r)) {
								Ok(text) => { ..s, results: text, searched: q }
								Err(why) => { ..s, results: "Search ${why}", searched: q }
							},
					),
				),
				Html.p_v(v.map(SearchApp.status), [Engine.test_id("status")]),
				Html.p_v(v.map(|s| s.results), [Engine.test_id("results")]),
				Html.button("Report", [], st.update(|s| { ..s, report: !s.report, summary: "" })),
				Engine.when(v.map(|s| s.report), || SearchApp.report_view(st), || Engine.text("")),
			],
		)
	}

	## The program the page and every worker instance run.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(SearchApp.initial, |st| SearchApp.view(st)))
			.with_workers([
				SearchApp.filter_task.registration(),
				SearchApp.summarise_task.registration(),
			])
}
