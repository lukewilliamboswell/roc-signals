import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Outbox test app: `Engine.Outbox` and `Engine.on_post`, with specs in
## `specs/` run natively and in Chrome.
## - "Send" posts the draft to `notes`, whose `on_post` site sends it as an
##   HTTP request; each answer is logged with the note it was posted with,
##   so answers taken out of order still name their own note.
## - The site sits in a `when` ("Sending"): unchecking it disposes the
##   site, and a request still in flight is kept and delivered to the
##   `when`, so its answer still reaches the log.
## - "Send twice" posts twice in one turn, a contract error the browser
##   contract test (`tests/browser/outbox-browser.mjs`) observes; a native
##   spec cannot, since the spec runner shares the page's process.
## - "Send both" posts one list of two notes, the way to send several
##   things in one turn.
OutboxApp := [].{

	## The app's state: the note being typed, the outbox the site sends,
	## the outbox of note lists, whether the site is mounted, and the log of
	## answers.
	S : {
		draft : Str,
		notes : Engine.Outbox(Str),
		batches : Engine.Outbox(List(Str)),
		sending : [Sending, Paused],
		log : List(Str),
	}

	initial : S
	initial = { draft: "", notes: Engine.outbox({}), batches: Engine.outbox({}), sending: Sending, log: [] }

	## Post the draft as a note and clear it.
	send : S -> S
	send = |s| { ..s, notes: s.notes.post(s.draft), draft: "" }

	## Post the draft twice in one turn: a contract error.
	send_twice : S -> S
	send_twice = |s| { ..s, notes: s.notes.post(s.draft).post(s.draft) }

	## Post the draft and a copy as one list.
	send_both : S -> S
	send_both = |s| { ..s, batches: s.batches.post([s.draft, "${s.draft}2"]), draft: "" }

	## A note's request: one GET whose URL names it.
	request : Str -> Engine.Req
	request = |note| Http({ method: "GET", url: "/notes/${note}", headers: [], body: "", timeout_ms: 0 })

	## A line of the log: the note an answer belongs to, and the answer.
	answered : S, Str, Engine.Res -> S
	answered = |s, note, res| {
		line = match Engine.http_text(res) {
			Ok(body) => "${note}:${body}"
			Err(problem) => "${note}:${Str.inspect(problem)}"
		}
		{ ..s, log: s.log.append(line) }
	}

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| Html.div(
		"outbox",
		[
			Html.text_input(Engine.const("Note"), "text", st.val().map(|s| s.draft), [], st.set_value(|s, text| { ..s, draft: text })),
			Html.button("Send", [], st.update(OutboxApp.send)),
			Html.button("Send twice", [], st.update(OutboxApp.send_twice)),
			Html.button("Send both", [], st.update(OutboxApp.send_both)),
			Html.checkbox(
				Engine.const("Sending"),
				st.val().map(|s| s.sending == Sending),
				[],
				st.set_value(|s, checked| { ..s, sending: if (checked == "true") Sending else Paused }),
			),
			Engine.when(
				st.val().map(|s| s.sending == Sending),
				|| Engine.on_post(st.val().map(|s| s.notes), |note| [OutboxApp.request(note)], st.on_result(OutboxApp.answered)),
				|| Engine.text(""),
			),
			Engine.on_post(st.val().map(|s| s.batches), |notes| notes.map(OutboxApp.request), st.on_result(|s, notes, res| OutboxApp.answered(s, Str.join_with(notes, "+"), res))),
			Html.p_v(st.val().map(|s| Str.join_with(s.log, " | ")), [Engine.test_id("log")]),
		],
	)

	program : Engine.Program
	program = Engine.program(|| Engine.state(OutboxApp.initial, OutboxApp.view))
}

## A post is never equal to the outbox before it, even with an equal item,
## and `last` reads the latest post.
expect {
	sent = OutboxApp.send({ ..OutboxApp.initial, draft: "a" })
	again = OutboxApp.send({ ..sent, draft: "a" })
	actual =
		\\initial: ${Str.inspect(OutboxApp.initial.notes.last())}
		\\sent: ${Str.inspect(sent.notes.last())} "${sent.draft}"
		\\again: ${Str.inspect(again.notes.last())}
		\\equal to the post before: ${Str.inspect(again.notes == sent.notes)}
		\\equal to itself: ${Str.inspect(again.notes == again.notes)}
		\\fresh outboxes equal: ${Str.inspect(OutboxApp.initial.notes == Engine.outbox({}))}
	expected =
		\\initial: Unposted
		\\sent: Posted("a") ""
		\\again: Posted("a")
		\\equal to the post before: False
		\\equal to itself: True
		\\fresh outboxes equal: True
	actual == expected
}
