import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Worker search test app: an app that computes in Web Workers the way an
## author would, with no control that poisons the page, so its specs, its
## leak-checked native soak and its Chrome soak all walk it freely.
## - A search box whose `latest` site runs the filter program on each new
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

	filter_name = "test.roc-signals/search/filter"

	summarise_name = "test.roc-signals/search/summarise"

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

	## The filter program: a query in, the catalogue names that contain it
	## (ignoring ASCII case) out, joined by ", ".
	filter : List(U8) -> List(U8)
	filter = |query| {
		q = SearchApp.lower(query)
		hits = SearchApp.catalogue.keep_if(|name| SearchApp.contains(SearchApp.lower(name.to_utf8()), q))
		Str.join_with(hits, ", ").to_utf8()
	}

	## The summary program: the catalogue's size and its longest name.
	summarise : List(U8) -> List(U8)
	summarise = |_| {
		longest = SearchApp.catalogue.fold("", |best, n| if (n.to_utf8().len() > best.to_utf8().len()) n else best)
		"${SearchApp.catalogue.len().to_str()} entries, longest ${longest}".to_utf8()
	}

	## What a finished job says, success or not.
	outcome : Engine.Res -> Try(Str, Str)
	outcome = |r| match r {
		Work(out) => Ok(Str.from_utf8(out) ?? "")
		WorkLost(fault) => Err("lost (${Str.inspect(fault)})")
		Timeout => Err("took too long")
		Refused => Err("too busy")
		_ => Err("unexpected")
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
					|_| [Work({ program: SearchApp.summarise_name, input: [], deadline_ms: 2000 })],
					st.on_result(
						|s, _, r| {
							..s,
							summary: match SearchApp.outcome(r) {
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
					|q| if (q == "") [] else [Work({ program: SearchApp.filter_name, input: q.to_utf8(), deadline_ms: 0 })],
					st.on_result(
						|s, q, r|
							match SearchApp.outcome(r) {
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
				Engine.registration(SearchApp.filter_name, SearchApp.filter),
				Engine.registration(SearchApp.summarise_name, SearchApp.summarise),
			])
}
