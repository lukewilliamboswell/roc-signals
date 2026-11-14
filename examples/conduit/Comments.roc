import pf.Engine exposing [Cell, Elem, Row, RowRef, State]
import pf.Html
import Api
import Fetch
import Format
import Parts
import Session
import Styles

## The comments under one article: what the server last sent, and the
## deletion in progress, if any. The type, its pure operations, its effect
## sites and its view are this one module; the view is drawn over cells of
## whichever store holds them (`Props`), so it never imports the app's.
Comments :: { slug : Str, loaded : Fetch.Loaded(List(Api.Comment)), refetch : U64, del : Fetch.Submit, del_result : Fetch.DeleteResult }.{

	is_eq : _

	## What the view is drawn over, in a store whose type is `st`: the
	## comments' own cell and who is signed in.
	Props(st) : { comments : Cell(st, Comments), session : Cell(st, Session) }

	init : Str -> Comments
	init = |slug| { slug, loaded: Fetch.no_load({}), refetch: 0, del: Fetch.no_submit, del_result: DeleteIdle }

	## The same comments model pointed at another article.
	moved_to : Comments, Str -> Comments
	moved_to = |c, slug| { ..c, slug }

	## The load for these comments. Its key changes with every refetch.
	req : Comments -> Fetch.LoadReq
	req = |c| {
		if c.slug.is_empty() {
			Fetch.no_req
		} else {
			match Api.comments_uri(c.slug) {
				Ok(uri) => { key: "${uri}#${c.refetch.to_str()}", uri, token: "" }
				Err(_) => Fetch.no_req
			}
		}
	}

	## Keep an answer only if it is for the load wanted now.
	stored : Comments, Fetch.LoadReq, Try(Engine.Response, Engine.HttpFailure) -> Comments
	stored = |c, sent, res| { ..c, loaded: { key: sent.key, value: Api.decode_get(Api.response_of(res), Api.decode_comments) } }

	## What to show now: the list, a failure, or loading.
	current : Comments -> Api.Remote(List(Api.Comment))
	current = |c| Fetch.remote(c.loaded, Comments.req(c).key)

	## Ask for the list again, as after a comment is posted.
	refetched : Comments -> Comments
	refetched = |c| { ..c, refetch: c.refetch + 1 }

	## Ask the server to delete the comment whose row key is `key`.
	deleting : Comments, { key : Str, token : Str } -> Comments
	deleting = |c, { key, token }| {
		id = U64.from_str(key) ?? 0
		{ ..c, del: Fetch.next(c.del, "DELETE", Api.comment_uri(c.slug, id), "", token), del_result: DeleteIdle }
	}

	delete_answered : Comments, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> Comments
	delete_answered = |c, _sent, res| {
		outcome = Fetch.classify_delete(Api.response_of(res), "comment")
		match outcome {
			DeleteAccepted => { ..c, del_result: outcome, refetch: c.refetch + 1 }
			_ => { ..c, del_result: outcome }
		}
	}

	## The site that loads the comments. It is separate from `view` so the
	## page can start the load before the article has arrived.
	load : State(ctx, Comments) -> Elem(ctx)
	load = |comments| Fetch.load_site(comments.signal().map(Comments.req), comments.on_result(Comments.stored))

	## The site that sends a deletion.
	delete_site : State(ctx, Comments) -> Elem(ctx)
	delete_site = |comments| Fetch.submit_site(comments.signal().map(|c| c.del), comments.on_result(Comments.delete_answered))

	## One comment, in a row of the list: a row reads and writes the cells
	## with no `lift`.
	one : Props(st), RowRef(ctx, Api.Comment) -> Elem(Row(ctx, Api.Comment))
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	one = |props, r| {
		session = props.session.signal()
		mine = r.field(|c| c.author.username).map2(session, |name, s| name == s.username())
		Html.div(
			"my-4 overflow-hidden border border-zinc-950 bg-white p-4",
			[
				Html.p_s(r.field(|c| c.body), []),
				Html.p_s(r.field(|c| "${c.author.username} on ${Format.display_date(c.created_at)}"), [Engine.class("text-sm text-zinc-500")]),
				Engine.when(
					mine,
					|| Parts.button("Delete Comment", "mt-3 ${Styles.danger_button}", Engine.handle_by(r.key().map2(session, |key, s| { key, token: s.token() }), |asked, _| [props.comments.update(|c| Comments.deleting(c, asked))])),
					|| Engine.text(""),
				),
			],
		)
	}

	## The comments section, drawn over the comments' cell. `form` is
	## whatever the page wants shown to a signed-in reader above the list.
	view : Props(st), Elem(ctx) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props, form| {
		comments = props.comments
		session = props.session.signal()
		list = comments.signal().map(Comments.current)
		Html.div(
			"mt-10 border-t border-zinc-200 pt-8",
			[
				Engine.element("h3", [Engine.class("mb-5 text-2xl font-semibold tracking-normal text-zinc-950")], [Engine.text("Comments")]),
				Engine.when(session.map(|s| s.is_signed_in()), || form, || Html.p("Sign in to add a comment.", "")),
				Html.p_s(comments.signal().map(delete_error), [Engine.class("text-red-700")]),
				Engine.when(
					list.map(Api.is_loading),
					|| Html.p("Loading comments...", ""),
					|| Engine.when(
						list.map(Api.is_failed),
						|| Html.p_s(list.map(Api.failure_message), [Engine.class("text-red-700")]),
						|| Engine.element(
							"div",
							[],
							[
								Engine.each(
									list.map(
										|shown| match shown {
											Ready(l) => l
											_ => []
										},
									),
									|c| c.id.to_str(),
									|r| Comments.one(props, r),
								),
							],
						),
					),
				),
			],
		)
	}
}

## The message to show for the latest deletion, or `""`.
delete_error : Comments -> Str
delete_error = |c| Fetch.delete_error(c.del_result)

expect Comments.init("s").req().key == "/api/articles/s/comments#0"
expect Comments.init("s").refetched().req().key == "/api/articles/s/comments#1"
expect Comments.init("s").deleting({ key: "7", token: "t" }).del.url == Ok("/api/articles/s/comments/7")
