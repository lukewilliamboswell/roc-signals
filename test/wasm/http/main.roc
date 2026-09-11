app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-04-c125b82" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	"Idle",
	|status| Html.div(
		[],
		[
			Html.text_s(status.signal()),
			Html.button("Fetch", Action.run(Signal.const({}), |_| Action.then([status.set("Loading")], |_| fetch!(status)))),
			Html.button("Oversized", Action.run(Signal.const({}), |_| Action.then([], |_| oversized!(status)))),
			Html.button("Too long", Action.run(Signal.const({}), |_| Action.then([], |_| invalid_timeout!(status)))),
		],
	),
)

invalid_timeout! : Ui.State(Str) => Action({})
invalid_timeout! = |status| {
	request = Http.request_from_method(Http.method_get)
		|> Http.with_uri("https://example.test/value")
		|> Http.with_timeout_ms(18446744073709551615.U64)
	text = match Http.send!(request) {
		Err(InvalidRequest(_)) => "Invalid timeout"
		Err(_) => "Wrong timeout failure"
		Ok(_) => "Unexpected timeout success"
	}
	Action.update([status.set(text)])
}

headers : U64 -> List({ name : Str, value : Str })
headers = |count| if count == 0 [] else [{ name: "X-Test", value: "value" }].concat(headers(count - 1))

oversized! : Ui.State(Str) => Action({})
oversized! = |status| {
	request = Http.request_from_method(Http.method_get)
		|> Http.with_uri("https://example.test/value")
		|> Http.with_headers(headers(257))
	text = match Http.send!(request) {
		Err(TooLarge(_)) => "Too large"
		Err(_) => "Wrong failure"
		Ok(_) => "Unexpected success"
	}
	Action.update([status.set(text)])
}

fetch! : Ui.State(Str) => Action({})
fetch! = |status| {
	text = match Http.get_text!("https://example.test/value") {
		Ok(value) => value
		Err(Timeout) => "Timeout"
		Err(Status(code)) => "HTTP ${code.to_str()}"
		Err(_) => "Request failed"
	}
	Action.update([status.set(text)])
}
