app [main] {
	pf: platform "../../../platform-gui/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/0.1/6LcdNq2r7xTBwj972ecYWUkMWobJr94yL2NyJpHRAXap.tar.zst",
}

import http.Method
import http.Request
import http.Response
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Env
import pf.Http
import pf.Signal
import pf.Ui

## Exercises the hosted `Http` functions from inside an action's effect. The
## spec host answers each request from declared stubs; a live run fetches the
## URL in `ROC_SIGNALS_HTTP_URL`, which a smoke check points at a local server.
main : () -> Elem
main = || Ui.state(
	"Idle",
	|status| Elem.col(
		{ test_id: "http-fixture" },
		[
			Elem.heading("Native Http fixture"),
			Elem.text_s(status.signal()),
			Elem.button("Fetch", Action.run(Signal.const({}), |_| Action.then([status.set("Fetching")], |_| fetch!(status)))),
			Elem.button("Send", Action.run(Signal.const({}), |_| Action.then([status.set("Sending")], |_| send!(status)))),
		],
	),
)

url! : () => Str
url! = || match Env.var!("ROC_SIGNALS_HTTP_URL") {
	Ok(value) => value
	Err(Missing) => "http://127.0.0.1:8765/hello.txt"
}

## Fetches the URL as text and reports the body.
fetch! : Ui.State(Str) => Action({})
fetch! = |status| match Http.get_text!(url!()) {
	Ok(text) => Action.update([status.set("Fetched: ${text}")])
	Err(error) => Action.update([status.set(Http.error_text(error))])
}

## Sends a full request and reports the status and header count.
send! : Ui.State(Str) => Action({})
send! = |status| {
	request = Request.from_method(Method.POST).with_uri(url!()).add_header("accept", "text/plain").with_body("ping".to_utf8())
	match Http.send!(request) {
		Ok(response) => Action.update([status.set("Status ${Response.status(response).to_str()} with ${Response.headers(response).len().to_str()} headers")])
		Err(error) => Action.update([status.set(Http.error_text(error))])
	}
}
