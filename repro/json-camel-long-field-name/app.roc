app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

State : { body : Str, ready : Bool }

fetch_row : Str, (Str -> Str) -> Elem
fetch_row = |file, run| {
	task = Http.request_task("probe-${file}")
	state : Signal.Signal(State)
	state =
		Signal.fold_task(
			task,
			{ body: "", ready: False },
			|response| { body: Str.from_utf8_lossy(Http.response_body(response)), ready: True },
			|_err| { body: "", ready: True },
		)
	line = state.map(|s| if s.ready { "${s.body} -> ${run(s.body)}" } else { "${file}: loading" })

	Html.div_c(
		"grid gap-1",
		[
			Html.paragraph_s_c(line, "text-sm font-mono"),
			Ui.on_change_initial(
				Signal.const(1),
				|_| Http.start(task, Http.request_from_method(GET).with_uri("/probe/${file}")),
			),
		],
	)
}

r11 : Str -> Str
r11 = |body| {
	parse : Str -> Try({ abcdefg_hij : U64 }, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()
	match parse(body) {
		Ok(_) => "ok"
		Err(InvalidJson(_)) => "InvalidJson"
		Err(MissingRequiredField(f)) => "Missing '${f}'"
	}
}

r12 : Str -> Str
r12 = |body| {
	parse : Str -> Try({ abcdefgh_ijk : U64 }, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()
	match parse(body) {
		Ok(_) => "ok"
		Err(InvalidJson(_)) => "InvalidJson"
		Err(MissingRequiredField(f)) => "Missing '${f}'"
	}
}

r13 : Str -> Str
r13 = |body| {
	parse : Str -> Try({ abcdefghi_jkl : U64 }, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()
	match parse(body) {
		Ok(_) => "ok"
		Err(InvalidJson(_)) => "InvalidJson"
		Err(MissingRequiredField(f)) => "Missing '${f}'"
	}
}

r14 : Str -> Str
r14 = |body| {
	parse : Str -> Try({ abcdefghij_klm : U64 }, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()
	match parse(body) {
		Ok(_) => "ok"
		Err(InvalidJson(_)) => "InvalidJson"
		Err(MissingRequiredField(f)) => "Missing '${f}'"
	}
}

main : () -> Elem
main = ||
	Html.div_c(
		"grid gap-2 p-4",
		[fetch_row("n11.json", r11), fetch_row("n12.json", r12), fetch_row("n13.json", r13), fetch_row("n14.json", r14)],
	)
