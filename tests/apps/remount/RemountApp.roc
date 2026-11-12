import pf.Engine exposing [Elem, Signal]
import pf.Html

## Remount test app: `Engine.remount_on`, a site that disposes its
## body and mounts it again whenever its key changes to an unequal value,
## with specs in `specs/` run natively and in Chrome.
##
## A mail client: the owner holds which message is open, and the detail
## pane is remounted on it. The pane keeps a reply draft as its own private
## state, loads its message over HTTP into private state as well, and keeps
## a long timer, so a change of message shows what disposal does: the draft
## starts again, the timer is cancelled, and the load still in flight is
## kept and delivered to the remount site, whose write to the pane's
## retired state is skipped.
RemountApp := [].{

	## What one message's load writes into the pane.
	loaded : Str, Str, Engine.Result -> Str
	loaded = |_, id, res| match Engine.http_text(res) {
		Ok(body) => "${id}:${body}"
		Err(problem) => "${id}:${Str.inspect(problem)}"
	}

	## The detail pane of the open message `id`. It takes no key: it reads
	## `id` like any other value, and is remounted when the key changes.
	detail : Signal(ctx, Str) -> Elem(ctx)
	detail = |id| Engine.state(
		"",
		|draft| Html.div(
			"detail",
			[
				Html.p_s(id.lift().map(|i| "Message ${i}"), [Engine.test_id("message")]),
				Html.text_input(Engine.const("Reply"), "text", draft.signal(), [], draft.set_value(|_, v| v)),
				Engine.state(
					"loading",
					|body| Html.div(
						"body",
						[
							Html.p_s(body.signal(), [Engine.test_id("body")]),
							Engine.watch(
								id.lift().lift(),
								|i| [Http({ method: "GET", url: "/messages/${i}", headers: [], body: "", timeout_ms: 0 })],
								body.on_result(RemountApp.loaded),
							),
							Engine.watch(Engine.const("reminder"), |_| [Timer(60000)], Engine.ignore({})),
						],
					),
				),
			],
		),
	)

	program : Engine.Program
	program = Engine.program(
		|| Engine.state(
			"a",
			|open| Html.div(
				"mail",
				[
					Html.button("Open a", [], open.update(|_| "a")),
					Html.button("Open b", [], open.update(|_| "b")),
					Engine.remount_on(open.signal(), || RemountApp.detail(open.signal())),
				],
			),
		),
	)
}
