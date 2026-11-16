import pf.Engine exposing [Elem, Signal, State]
import Api
import Fetch
import Parts
import Styles

## The comment box under an article: what the reader has typed, the POST it
## last sent, and how that ended.
CommentForm :: { body : Str, sub : Fetch.Submit, result : Outcome }.{

	is_eq : _

	## How the latest POST ended.
	Outcome : [Idle, Accepted, Rejected(List(Str)), Errored(Str)]

	## Where a comment goes and who is posting it.
	Target : { slug : Str, token : Str }

	init : CommentForm
	init = { body: "", sub: Fetch.no_submit, result: Idle }

	typed : CommentForm, Str -> CommentForm
	typed = |form, text| { ..form, body: text }

	body_json : Str -> Str
	body_json = |text| "{\"comment\":{\"body\":${Json.to_str(text)}}}"

	## The form with a POST of its text waiting to be sent.
	submitted : CommentForm, Target -> CommentForm
	submitted = |form, { slug, token }| { ..form, sub: Fetch.next(form.sub, "POST", Api.comments_uri(slug), CommentForm.body_json(form.body.trim()), token), result: Idle }

	## The POST to send, for the site that sends it.
	sending : CommentForm -> Fetch.Submit
	sending = |form| form.sub

	classify : Api.ResponseState -> Outcome
	classify = |response| {
		if !response.error.is_empty() {
			Errored("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 201 {
			Accepted
		} else if response.status == 422 {
			Rejected(Api.parse_errors(response.body))
		} else if response.status == 401 {
			Errored("Please sign in to comment.")
		} else if response.status == 404 {
			Errored("Article was not found.")
		} else {
			Errored("The server responded with status ${response.status.to_str()}.")
		}
	}

	## The form after the answer to `sent`, and whether that answer posted a
	## comment. Its keep_current site admits only the latest POST’s result.
	answered : CommentForm, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> { form : CommentForm, posted : Bool }
	answered = |form, _sent, res| {
		outcome = CommentForm.classify(Api.response_of(res))
		{ form: { ..form, result: outcome }, posted: outcome == Accepted }
	}

	## The lines to show above the box.
	errors : CommentForm -> List(Str)
	errors = |form| match form.result {
		Rejected(lines) => lines
		Errored(message) => [message]
		_ => []
	}

	## The box, drawn over a state that holds a form. `target` is read when
	## the button is pressed. `answer` is the owner's reaction to the POST's
	## answer: the owner decides what else an accepted comment changes.
	view : State(ctx, CommentForm), Signal(ctx, Target), Engine.Reaction(ctx, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure)) -> Elem(ctx)
	view = |form, target, answer| Engine.element(
		"form",
		[Engine.class("mb-8 grid gap-3 border border-zinc-950 bg-zinc-50 p-4")],
		[
			Fetch.submit_site(form.signal().map(CommentForm.sending), answer),
			Parts.error_list(form.signal().map(CommentForm.errors)),
			Parts.textarea("Comment", form.signal().map(|f| f.body), form.set_value(CommentForm.typed)),
			Parts.button("Post Comment", Styles.primary_button, form.update_by(target, CommentForm.submitted)),
		],
	)
}

expect CommentForm.init.typed(" hi ").submitted({ slug: "s", token: "t" }).sending().body == "{\"comment\":{\"body\":\"hi\"}}"
expect CommentForm.init.typed("x").submitted({ slug: "s", token: "t" }).sending().serial == 1
