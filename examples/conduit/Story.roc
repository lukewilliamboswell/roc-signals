import pf.Engine exposing [Cell, Elem, State]
import pf.Html
import Api
import Fetch
import Format
import MarkdownView
import Nav
import Parts
import Route
import Session
import Styles

## One article as its page shows it: what the server last sent, and the
## favourite and delete requests in progress, if any. The type, its pure
## operations, its effect sites and its view are this one module.
##
## The view is drawn over cells of whichever store holds them (`Props`),
## so this module never imports the app's store, which holds a `Story`
## and therefore imports this module. Whatever else the view reads or
## writes in the store (who is signed in, where to ask for a navigation)
## it is handed as a cell.
Story :: { slug : Str, article : Fetch.Loaded(Api.Article), refetch : U64, fav : Fetch.Submit, fav_result : FavoriteResult, del : Fetch.Submit, del_result : Fetch.DeleteResult }.{

	is_eq : _

	FavoriteResult : [FavoriteIdle, FavoriteAccepted(Api.Article), FavoriteRejected(Str)]

	## What the view is drawn over, in a store whose type is `st`: the
	## story's own cell, who is signed in, and the cell a navigation is
	## asked through.
	Props(st) : { story : Cell(st, Story), session : Cell(st, Session), nav : Nav.Asked(st) }

	init : Str -> Story
	init = |slug| { slug, article: Fetch.no_load({}), refetch: 0, fav: Fetch.no_submit, fav_result: FavoriteIdle, del: Fetch.no_submit, del_result: DeleteIdle }

	## The same story model pointed at another article.
	moved_to : Story, Str -> Story
	moved_to = |s, slug| { ..s, slug }

	slug : Story -> Str
	slug = |s| s.slug

	## The load for the article. Its key changes with every refetch.
	req : Story -> Fetch.LoadReq
	req = |s| {
		if s.slug.is_empty() {
			Fetch.no_req
		} else {
			uri = Api.article_uri(s.slug)
			{ key: "${uri}#${s.refetch.to_str()}", uri, token: "" }
		}
	}

	## Keep an answer only if it is for the load wanted now.
	stored : Story, Fetch.LoadReq, Try(Engine.Response, Engine.HttpFailure) -> Story
	stored = |s, sent, res| { ..s, article: { key: sent.key, value: Api.decode_get(Api.response_of(res), Api.decode_article) } }

	## What to show now: the article, a failure, or loading.
	current : Story -> Api.Remote(Api.Article)
	current = |s| Fetch.remote(s.article, Story.req(s).key)

	## The article's title once it has loaded, and `""` before.
	title : Story -> Str
	title = |s| match Story.current(s) {
		Ready(a) => a.title
		_ => ""
	}

	classify_favorite : Api.ResponseState -> FavoriteResult
	classify_favorite = |response| {
		if !response.error.is_empty() {
			FavoriteRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_article(response.body) {
				Ready(article) => FavoriteAccepted(article)
				Failed(message) => FavoriteRejected(message)
				Loading => FavoriteRejected("The server returned an empty article response.")
			}
		} else if response.status == 401 {
			FavoriteRejected("Please sign in to favorite articles.")
		} else if response.status == 404 {
			FavoriteRejected("Article was not found.")
		} else {
			FavoriteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	## Ask the server to favourite the article, or to undo that.
	favoriting : Story, Session -> Story
	favoriting = |s, session| {
		favorited = match Story.current(s) {
			Ready(a) => a.favorited
			_ => False
		}
		method = if (favorited) "DELETE" else "POST"
		{ ..s, fav: Fetch.next(s.fav, method, Api.favorite_uri(s.slug), "", session.token()), fav_result: FavoriteIdle }
	}

	favorite_answered : Story, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> Story
	favorite_answered = |s, _sent, res| {
		outcome = Story.classify_favorite(Api.response_of(res))
		match outcome {
			FavoriteAccepted(_) => { ..s, fav_result: outcome, refetch: s.refetch + 1 }
			_ => { ..s, fav_result: outcome }
		}
	}

	## Ask the server to delete the article.
	deleting : Story, Session -> Story
	deleting = |s, session| { ..s, del: Fetch.next(s.del, "DELETE", Api.article_uri(s.slug), "", session.token()), del_result: DeleteIdle }

	## The story after the answer to a deletion, and whether the article is
	## gone. Its owner decides where to go when it is.
	delete_answered : Story, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure) -> { story : Story, deleted : Bool }
	delete_answered = |s, _sent, res| {
		outcome = Fetch.classify_delete(Api.response_of(res), "article")
		{ story: { ..s, del_result: outcome }, deleted: outcome == DeleteAccepted }
	}

	## The site that loads the article.
	load : State(ctx, Story) -> Elem(ctx)
	load = |story| Fetch.load_site(story.signal().map(Story.req), story.on_result(Story.stored))

	## The site that sends a favourite or its undoing.
	favorite_site : State(ctx, Story) -> Elem(ctx)
	favorite_site = |story| Fetch.submit_site(story.signal().map(|s| s.fav), story.on_result(Story.favorite_answered))

	## The site that sends a deletion. `answer` is the owner's reaction,
	## because a deleted article changes more than the story.
	delete_site : State(ctx, Story), Engine.Reaction(ctx, Fetch.Submit, Try(Engine.Response, Engine.HttpFailure)) -> Elem(ctx)
	delete_site = |story, answer| Fetch.submit_site(story.signal().map(|s| s.del), answer)

	## The article, drawn over its cell, with `below` under it.
	view : Props(st), Elem(ctx) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props, below| {
		story = props.story
		sv = story.signal()
		article = sv.map(Story.current)
		field = |f| article.map(
			|shown| match shown {
				Ready(a) => f(a)
				_ => ""
			},
		)
		author = field(|a| a.author.username)
		session = props.session.signal()
		Engine.when(
			article.map(Api.is_loading),
			|| Html.p("Loading article...", "border border-zinc-950 bg-white p-6 text-zinc-500"),
			|| Engine.when(
				article.map(Api.is_failed),
				|| Html.p_s(article.map(Api.failure_message), [Engine.class(Styles.status_error)]),
				|| Engine.element(
					"div",
					[Engine.attr("data-conduit", "article"), Engine.class("border border-zinc-950 bg-white p-6 sm:p-10")],
					[
						Engine.element("h2", [Engine.class("text-4xl font-semibold leading-tight tracking-normal text-zinc-950 sm:text-5xl")], [Engine.text_s(field(|a| a.title))]),
						Html.div(
							"flex flex-wrap items-center gap-2 py-4 text-sm text-zinc-500",
							[
								Nav.link_s(props.nav, author, "font-medium text-emerald-600", author.map(profile_url)),
								Engine.text_s(field(|a| "${Format.display_date(a.created_at)} | ${a.favorites_count.to_str()} favorites")),
							],
						),
						Engine.when(
							session.map(|s| s.is_signed_in()),
							|| Parts.button_s(
								article.map(
									|shown| match shown {
										Ready(a) => if (a.favorited) "Unfavorite Article (${a.favorites_count.to_str()})" else "Favorite Article (${a.favorites_count.to_str()})"
										_ => "Favorite Article"
									},
								),
								"mb-4 mr-2 border border-emerald-600 bg-white px-4 py-2 text-sm font-medium text-emerald-700",
								Engine.handle_by(session, |who, _| [story.update(|s| Story.favoriting(s, who))]),
							),
							|| Engine.text(""),
						),
						Html.p_s(
							sv.map(favorite_error),
							[Engine.class("text-red-700")],
						),
						Engine.when(
							article.map2(
								session,
								|shown, who| match shown {
									Ready(a) => a.author.username == who.username()
									_ => False
								},
							),
							|| Parts.button("Delete Article", "mb-4 ${Styles.danger_button}", Engine.handle_by(session, |who, _| [story.update(|s| Story.deleting(s, who))])),
							|| Engine.text(""),
						),
						Html.p_s(sv.map(delete_error), [Engine.class("text-red-700")]),
						MarkdownView.markdown(field(|a| a.body)),
						below,
					],
				),
			),
		)
	}
}

## The message to show for the latest favourite request, or `""`.
favorite_error : Story -> Str
favorite_error = |s| match s.fav_result {
	FavoriteRejected(message) => message
	_ => ""
}

## The message to show for the latest deletion, or `""`.
delete_error : Story -> Str
delete_error = |s| Fetch.delete_error(s.del_result)

profile_url : Str -> Str
profile_url = |name| Route.to_url(Route.profile_location(name))

expect Story.init("s").req().key == "/api/articles/s#0"
expect Story.init("s").deleting(Session.SignedIn({ token: "t", username: "kim" })).del.method == "DELETE"
expect Story.init("s").title() == ""
