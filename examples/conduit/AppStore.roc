import pf.Engine exposing [Handler, Signal]
import Article
import CommentForm
import Comments
import Nav
import Pages
import Route
import Session
import Story

## Conduit's store: the state the whole app shares, held at the root and
## reached from any depth with no `lift` and no prop. Each cell's getter
## and modifier are generated from its place in `store`.
##
## - `session`: who is signed in.
## - `loc`: where the reader is.
## - `nav`: a navigation an in-app link or an answer asked for. The root
##   pushes it to the history and moves `loc` and the pages in a
##   follow-up turn (`moved`), so asking to go somewhere is one write of
##   one cell from anywhere.
## - `incoming`: a session a login accepted, applied in the turn after the
##   navigation it triggers: home mounts for an anonymous reader and then
##   asks for its feed again with the token.
## - `pages`: every page's loads and forms but the article page's (`Pages`).
## - `article`: the article page's cells, a feature's description nested
##   in this one (`Article`).
##
## The module's one tag, `Conduit`, is the store's name: it is part of the
## type of every handle, so a cell of another store is a type error here.
## Nothing spells the store's contents type: an annotation that mentions it
## says `_` (`Engine.Reach(ctx, _)`, `Engine.Write(_)`,
## `Engine.StoreRoot(_)`), and the compiler fills it in from `store`.
AppStore := [Conduit].{

	## Where the reader is and who they are: what most loads depend on.
	Here : { loc : Str, session : Session }

	## The store: its name, and its cells with their starting values.
	store = Engine.store(
		AppStore.Conduit,
		{
			session: Engine.cell(Session.Anonymous),
			loc: Engine.cell(""),
			nav: Engine.cell(Engine.outbox({})),
			incoming: Engine.cell(Session.Anonymous),
			pages: Engine.cell(Pages.init("")),
			article: Article.cells({}),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = AppStore.store.cells()

	jwt_key : Str
	jwt_key = "conduit.jwt"

	username_key : Str
	username_key = "conduit.username"

	home_url : Str
	home_url = Route.to_url(Route.home_location)

	## The store a reader starts with: the session kept in local storage
	## and the location the page was opened at.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| {
		session = match (Engine.boot_storage(boot, AppStore.jwt_key), Engine.boot_storage(boot, AppStore.username_key)) {
			(Ok(token), Ok(username)) => SignedIn({ token, username })
			_ => Anonymous
		}
		loc = if (boot.url.is_empty()) AppStore.home_url else boot.url
		slug = Article.slug_of(loc)
		AppStore.store
			.with_initial(AppStore.cells.session, session)
			.with_initial(AppStore.cells.loc, loc)
			.with_initial(AppStore.cells.article.cells.story, Story.init(slug))
			.with_initial(AppStore.cells.article.cells.comments, Comments.init(slug))
	}

	## Where the reader is and who they are, as one value.
	here : {} -> Signal(ctx, Here)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	here = |{}| AppStore.cells.loc.signal().map2(AppStore.cells.session.signal(), |loc, session| { loc, session })

	## A handler that asks to go to `url`.
	go : Str -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	go = |url| Nav.go(AppStore.cells.nav, url)

	## A handler that asks to go to the URL `url` holds when the event fires.
	go_by : Signal(ctx, Str) -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	go_by = |url| Nav.go_by(AppStore.cells.nav, url)

	## The write that asks to go to `url`, for a decision's list.
	asking : Str -> Engine.Write(_)
	asking = |url| AppStore.cells.nav.update(|o| o.post(url))

	## The writes of a move from where the reader is (`at`) to `url`: one
	## decision for every cell a move touches. Another kind of page starts
	## every page again: the article page's cells with the write its
	## description generated, so this function names none of them. Then
	## the article page is pointed at the article the URL names.
	moved : Here, Str -> List(Engine.Write(_))
	moved = |at, url| {
		art = AppStore.cells.article
		slug = Article.slug_of(url)
		restart = if (Article.same_kind(at.loc, url)) [] else [AppStore.cells.pages.set(Pages.init(url)), art.reset]
		restart.concat([
			art.cells.story.update(|s| s.moved_to(slug)),
			art.cells.comments.update(|c| c.moved_to(slug)),
			AppStore.cells.loc.set(url),
		])
	}
}

## A move to another kind of page starts the article page's cells again.
expect {
	article = Route.to_url(Route.article_location("a"))
	typed = AppStore.store.after([AppStore.cells.loc.set(article), AppStore.cells.article.cells.form.set(CommentForm.init.typed("x"))])
	home = typed.after(AppStore.moved({ loc: article, session: Session.Anonymous }, AppStore.home_url))
	home.read(AppStore.cells.article.cells.form) == CommentForm.init and home.read(AppStore.cells.loc) == AppStore.home_url
}

## A move between two articles keeps the comment box and points the story at the new one.
expect {
	first = Route.to_url(Route.article_location("a"))
	second = Route.to_url(Route.article_location("b"))
	typed = AppStore.store.after([AppStore.cells.loc.set(first), AppStore.cells.article.cells.form.set(CommentForm.init.typed("x"))])
	moved = typed.after(AppStore.moved({ loc: first, session: Session.Anonymous }, second))
	moved.read(AppStore.cells.article.cells.form) == CommentForm.init.typed("x") and moved.read(AppStore.cells.article.cells.story).slug() == "b"
}

## Leaving a page kind starts every page's state again, including drafts,
## submissions and loads outside the article page's own cells.
expect {
	login = Route.to_url(Route.login_location)
	pages = Pages.init(login)
	dirty = { ..pages, auth: { ..pages.auth, username: "kim" }, settings: { ..pages.settings, bio: "draft bio" }, editor: { ..pages.editor, title: "draft article" }, prof: { ..pages.prof, refetch: 3 }, loads: { ..pages.loads, feed: { key: "old feed", value: Loading } } }
	typed = AppStore.store.after([AppStore.cells.loc.set(login), AppStore.cells.pages.set(dirty)])
	home = typed.after(AppStore.moved({ loc: login, session: Session.Anonymous }, AppStore.home_url))
	home.read(AppStore.cells.pages) == Pages.init(AppStore.home_url)
}
