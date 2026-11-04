import Engine exposing [Elem, Root, In, State]
import H

## Effect-channel test app: three effect sites, each watching a per-site
## counter in the root state and shown or hidden by a `when` (hiding disposes
## the site and cancels what it owns), plus a popstate subscription at the
## root. Every reaction appends a line to the root log, rendered as text.
## Site k issues GET /s<k>/<count> for every nonzero count, plus a `Self`
## follow-up when the count is a multiple of 3, and a second one when it is a
## multiple of 6; the first follow-up's reaction then hides the site, so the
## second must be dropped with it (counted stale), never delivered.
FxApp := [].{
	S : { counts : List(U64), shown : List(Bool), log : List(Str) }

	Ctx : In(Root, S)

	nsites : U64
	nsites = 3

	url_of : U64, U64 -> Str
	url_of = |k, c| "/s${k.to_str()}/${c.to_str()}"

	plan : U64 -> (U64 -> List(Engine.Req))
	plan = |k| |c| {
		if c == 0 {
			[]
		} else {
			get = Http({ method: "GET", url: FxApp.url_of(k, c), headers: [("accept", "text/plain")], body: "" })
			if c % 6 == 0 [get, Self, Self] else if c % 3 == 0 [get, Self] else [get]
		}
	}

	describe : U64, U64, Engine.Res -> Str
	describe = |k, c, r| {
		head = "${k.to_str()}:${c.to_str()}"
		match r {
			Http({ status, body }) => "${head}:${status.to_str()}:${body}"
			Network(m) => "${head}:net:${m}"
			Refused => "${head}:refused"
			Now => "${head}:self"
			Location(u) => "pop:${u}"
			_ => "${head}:other"
		}
	}

	log_line : S, Str -> S
	log_line = |{ counts, shown, log }, line| { counts, shown, log: log.append(line) }

	bump : S, U64 -> S
	bump = |{ counts, shown, log }, k| { counts: counts.update(k, |c| c + 1) ?? counts, shown, log }

	toggle : S, U64 -> S
	toggle = |{ counts, shown, log }, k| { counts, shown: shown.update(k, |b| !b) ?? shown, log }

	react : S, U64, U64, Engine.Res -> S
	react = |s, k, c, r| {
		s1 = FxApp.log_line(s, FxApp.describe(k, c, r))
		match r {
			Now => if c % 6 == 0 FxApp.toggle(s1, k) else s1
			_ => s1
		}
	}

	site : State(Ctx, S), U64 -> Elem(Ctx)
	site = |st, k| {
		label = "site ${k.to_str()}"
		Engine.element("div", [], [
			H.button("issue ${k.to_str()}", [], st.update(|s| FxApp.bump(s, k))),
			H.button("toggle ${k.to_str()}", [], st.update(|s| FxApp.toggle(s, k))),
			Engine.when(
				st.val().map(|s| s.shown.get(k) ?? False),
				|| Engine.element("p", [], [
					Engine.text(label),
					Engine.watch(
						st.val().map(|s| s.counts.get(k) ?? 0),
						FxApp.plan(k),
						st.on_result(|s, c, r| FxApp.react(s, k, c, r)),
					),
				]),
				|| Engine.text(""),
			),
		])
	}

	main_with : List(Bool) -> Elem(Root)
	main_with = |shown| Engine.state(
		{ counts: List.repeat(0, FxApp.nsites), shown, log: [] },
		|st| Engine.element("div", [], [
			Engine.watch(Engine.const(0.U64), |_| [Popstate], st.on_result(|s, _, r| FxApp.log_line(s, FxApp.describe(9, 0, r)))),
			FxApp.site(st, 0),
			FxApp.site(st, 1),
			FxApp.site(st, 2),
			Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
			# An SVG badge (namespace check in the browser): its class follows the log length.
			Engine.element("svg", [Engine.attr("aria-label", "badge"), Engine.attr("width", "10"), Engine.attr("height", "10")], [
				Engine.element("circle", [Engine.attr("r", "4"), Engine.attr("cx", "5"), Engine.attr("cy", "5"), Engine.class_v(st.val().map(|s| if s.log.is_empty() "idle" else "busy"))], []),
			]),
		]),
	)

	main : {} -> Elem(Root)
	main = |_| FxApp.main_with([True, True, True])
}
