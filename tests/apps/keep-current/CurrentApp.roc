import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Current-step delivery without cancellation, including surviving root
## reactions and the skipped writes of a disposed local state.
CurrentApp := [].{
	Question : { text : Str, slots : U64 }
	S : { question : Str, multiple : Bool, shown : Bool, answers : List(Str), progress : Str, local : Bool }

	initial : S
	initial = { question: "", multiple: False, shown: True, answers: [], progress: "none", local: False }

	question_of : S -> Question
	question_of = |s| { text: s.question, slots: if (s.multiple) 2 else 1 }

	requests : Question -> List(Engine.Ask(Str, Engine.HttpError))
	requests = |asked| {
		var $requests = []
		if asked.text == "redirect" {
			$requests = [Engine.command(Replace("/current/next")), Engine.again({}).map_ok(|_| "follow"), Engine.again({}).map_ok(|_| "follow")]
		} else if !asked.text.is_empty() {
			for slot in 0..<asked.slots {
				$requests = $requests.append(Engine.http_body({ url: "/current/${asked.text}/${slot.to_str()}" }).map_ok(|body| "${slot.to_str()}:${body}"))
			}
		}
		$requests
	}

	answered : S, { asked : Question, result : Try(Str, Engine.HttpError) } -> S
	answered = |s, { asked, result }| {
		answer = match result {
			Ok(body) => body
			Err(error) => Str.inspect(error)
		}
		{ ..s, question: if (asked.text == "redirect") "after" else s.question, answers: s.answers.append("${asked.text}:${answer}") }
	}

	local_view : {} -> Elem(ctx)
	local_view = |_| Engine.state(
		1.U64,
		|local| Html.div(
			"",
			[
				Html.button("Advance local", [], local.update(|n| n + 1)),
				Html.p_s(local.signal().map(|n| n.to_str()), [Engine.test_id("local-value")]),
				Engine.keep_current(local.signal(), |value| [Engine.http_body({ url: "/current/local/${value.to_str()}" })], local.on_result(|value, _, _| value + 1)),
			],
		),
	)

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |state| {
		value = state.signal()
		Html.div(
			"",
			[
				Html.text_input(Engine.const("Question"), "text", value.map(|s| s.question), [], state.set_value(|s, text| { ..s, question: text })),
				Html.checkbox(Engine.const("Shown"), value.map(|s| s.shown), [], state.set_value(|s, shown| { ..s, shown })),
				Html.checkbox(Engine.const("Two requests"), value.map(|s| s.multiple), [], state.set_value(|s, text| { ..s, multiple: text == "true" })),
				Html.button("Hide and choose B", [], state.update(|s| { ..s, shown: False, question: "B" })),
				Html.button("Open local", [], state.update(|s| { ..s, local: True })),
				Html.button("Close local", [], state.update(|s| { ..s, local: False })),
				Html.button("Reset", [], state.update(|_| CurrentApp.initial)),
				Html.p_s(value.map(|s| if (s.shown) "shown" else "hidden"), [Engine.test_id("site-status")]),
				Html.p_s(value.map(|s| if (s.local) "open" else "closed"), [Engine.test_id("local-status")]),
				Html.p_s(value.map(|s| if (s.answers.is_empty()) "no results" else Str.join_with(s.answers, "|")), [Engine.test_id("answers")]),
				Html.p_s(value.map(|s| s.progress), [Engine.test_id("progress")]),
				Engine.when(
					value.map(|s| s.shown),
					|| Engine.keep_current(
						value.map(CurrentApp.question_of),
						CurrentApp.requests,
						state.on_result(|s, asked, result| CurrentApp.answered(s, { asked, result })).with_progress({ every_ms: 1 }, state.on_progress(|s, asked, transfer| { ..s, progress: "${asked.text}:${transfer.done.to_str()}" })),
					),
					|| Engine.text(""),
				),
				Engine.when(value.map(|s| s.local), || CurrentApp.local_view({}), || Engine.text("")),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state(CurrentApp.initial, CurrentApp.view))
}
