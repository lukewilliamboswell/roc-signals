import pf.Engine exposing [Elem, Val]
import Api

## The two request shapes Conduit's pages use, and the sites that send them.
##
## A page keeps a request as a plain value in its state. A site in its view
## watches that value and sends the request whenever it changes; the answer
## comes back to a reaction, which decides whether it is still wanted.
Fetch := [].{

	## A mutation as a click wrote it. Serial 0 means nothing was submitted;
	## each submission takes the next serial, so an answer to an older one
	## can be told from an answer to the latest.
	Submit : { serial : U64, method : Str, url : Str, body : Str, token : Str }

	## A load. `key` is what a stored value must match to be shown.
	LoadReq : { key : Str, uri : Str, token : Str }

	## What a load last stored, and the key it was stored for.
	Loaded(a) : { key : Str, value : Api.Remote(a) }

	## How a DELETE ended.
	DeleteResult : [DeleteIdle, DeleteAccepted, DeleteRejected(Str)]

	no_submit : Submit
	no_submit = { serial: 0, method: "", url: "", body: "", token: "" }

	## The submission after `prev`.
	next : Submit, Str, Str, Str, Str -> Submit
	next = |prev, method, url, body, token| { serial: prev.serial + 1, method, url, body, token }

	no_req : LoadReq
	no_req = { key: "", uri: "", token: "" }

	no_load : {} -> Loaded(a)
	no_load = |_| { key: "", value: Loading }

	## What to show for the request whose key is `key`: the stored value if it
	## was stored for that key, and `Loading` otherwise.
	remote : Loaded(a), Str -> Api.Remote(a)
	remote = |loaded, key| if (!key.is_empty() and loaded.key == key) loaded.value else Loading

	plan_submit : Submit -> List(Engine.Req)
	plan_submit = |s| {
		if s.serial == 0 {
			[]
		} else if s.method == "GET" or s.method == "DELETE" {
			[Http({ method: s.method, url: s.url, headers: Api.auth_headers(s.token), body: s.body, timeout_ms: Api.timeout_ms })]
		} else {
			[Http({ method: s.method, url: s.url, headers: Api.json_headers(s.token), body: s.body, timeout_ms: Api.timeout_ms })]
		}
	}

	classify_delete : Api.ResponseState, Str -> DeleteResult
	classify_delete = |response, what| {
		if !response.error.is_empty() {
			DeleteRejected("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 204 {
			DeleteAccepted
		} else if response.status == 401 {
			DeleteRejected("Please sign in to delete ${what}s.")
		} else if response.status == 403 {
			DeleteRejected("Only the author can delete this ${what}.")
		} else if response.status == 404 {
			DeleteRejected(if (what == "article") "Article was not found." else "Comment was not found.")
		} else {
			DeleteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	## The message to show for a DELETE, or `""`.
	delete_error : DeleteResult -> Str
	delete_error = |result| match result {
		DeleteRejected(message) => message
		_ => ""
	}

	## Sends a GET whenever `req` changes; `stored` receives the answer with
	## the request it was sent for.
	load_site : Val(ctx, LoadReq), Engine.Reaction(ctx, LoadReq) -> Elem(ctx)
	load_site = |req, stored| Engine.watch(req, |r| if (r.uri.is_empty()) [] else [Api.get_request(r.uri, r.token)], stored)

	## Sends a submission whenever `sub` changes; `answered` receives the
	## answer with the submission it was sent for.
	submit_site : Val(ctx, Submit), Engine.Reaction(ctx, Submit) -> Elem(ctx)
	submit_site = |sub, answered| Engine.watch(sub, Fetch.plan_submit, answered)
}

expect Fetch.next(Fetch.no_submit, "POST", "/x", "", "").serial == 1
expect Fetch.remote({ key: "a", value: Ready(1.U64) }, "b") == Loading
