import pf.Engine exposing [Cell, Elem, Reaction, Row, RowRef, Signal, State]
import pf.Html
import Api
import AppStore
import ArticlePage
import Fetch
import Pages
import Session
import Story
import Route
import Format
import Links
import Styles

## Conduit, the RealWorld demo app: a blogging site with feeds, articles,
## comments, profiles and sign-in, against the RealWorld API.
##
## The state the whole app shares is a store (`AppStore`): the session,
## the location, the navigation asked for, the incoming session and the
## pages' models are cells held at the root, read and written from any
## depth with no `lift` and no prop. Store state never resets by itself,
## so changing the route's kind resets the page models. Pages are a
## `switch` over the route kind, so leaving a page disposes its effect
## sites. A request the page has sent is kept, not cancelled: its answer
## arrives where the `switch` stands, and the checks below decide whether
## it is still wanted.
##
## Effects are sites that watch state:
## - loads watch a request record ({ key, uri, token }); a result is stored
##   only while its key is still the page's current key, so an older
##   response never overwrites a newer one. A feed keeps its one stored
##   answer visible, labeled as previous results, while a new key loads;
## - mutations watch a submission snapshot ({ serial, method, url, body,
##   token }) written by the click; a result applies only while its serial is
##   the latest;
## - the root owns the popstate subscription, history push (an `on_post`
##   site sending each navigation asked for, then moving there in a
##   follow-up turn), the guard redirect (Replace plus a `Self` follow-up
##   that moves the location), the document title and the session's storage
##   keys.
ConduitApp := [].{

	M : Pages.Model

	Here : AppStore.Here

	Loaded(a) : Pages.Loaded(a)

	Loads : Pages.Loads

	LoadReq : Pages.LoadReq

	Submit : Pages.Submit

	ArticleResult : Pages.ArticleResult

	FavoriteResult : [FavoriteIdle, FavoriteAccepted(Api.Article), FavoriteRejected(Str)]

	FollowResult : Pages.FollowResult

	SettingsForm : Pages.SettingsForm

	FavState : { req : Submit, result : FavoriteResult }

	## ------------------------------------------------------------------
	## Model.

	## The pages' models: a cell of the store.
	pages : Cell(_, M)
	pages = AppStore.cells.pages

	## Where the reader is and who they are, read at the root.
	here : Signal(Engine.StoreRoot(_), Here)
	here = AppStore.here({})

	no_submit : Submit
	no_submit = Pages.no_submit

	home_url : Str
	home_url = AppStore.home_url

	route_of : Here -> Route
	route_of = |w| Route.of_url(w.loc)

	token_of : Session -> Str
	token_of = |s| s.token()

	username_of : Session -> Str
	username_of = |s| s.username()

	is_signed_in : Session -> Bool
	is_signed_in = |s| s.is_signed_in()

	## Where a visitor at `loc` must be sent instead, or `""`.
	guard_for : Str, Session -> Str
	guard_for = |loc, session| {
		kind = Route.kind(Route.of_url(loc))
		signed_in = session.is_signed_in()
		requires_auth = kind == Settings or kind == EditorNew or kind == EditorEdit
		anonymous_only = kind == Login or kind == Register
		if requires_auth and !signed_in {
			Route.to_url(Route.login_location)
		} else if anonymous_only and signed_in {
			ConduitApp.home_url
		} else {
			""
		}
	}

	remote : Loaded(a), Str -> Api.Remote(a)
	remote = |loaded, key| if (!key.is_empty() and loaded.key == key) loaded.value else Loading

	title_of : Here, Story -> Str
	title_of = |w, story| {
		route = ConduitApp.route_of(w)
		match route {
			Article(_) => {
				name = story.title()
				if (name.is_empty()) Route.title(route) else "${name} - Conduit"
			}
			_ => Route.title(route)
		}
	}

	set_loads : M, (Loads -> Loads) -> M
	set_loads = |m, f| { ..m, loads: f(m.loads) }

	## ------------------------------------------------------------------
	## Load requests (key = what the stored value must match to be shown).

	no_req : LoadReq
	no_req = { key: "", uri: "", token: "" }

	feed_req : Here -> LoadReq
	feed_req = |w| match ConduitApp.route_of(w) {
		Home(feed) => {
			uri = Api.feed_uri(feed)
			token = ConduitApp.token_of(w.session)
			{ key: "${uri}|${token}", uri, token }
		}
		_ => ConduitApp.no_req
	}

	tags_req : Here -> LoadReq
	tags_req = |_| { key: "tags", uri: Api.tags_uri, token: "" }

	profile_req : Here, M -> LoadReq
	profile_req = |w, m| {
		name = Route.profile_username(ConduitApp.route_of(w))
		if name.is_empty() {
			ConduitApp.no_req
		} else {
			uri = Api.profile_uri(name)
			{ key: "${uri}#${m.prof.refetch.to_str()}", uri, token: "" }
		}
	}

	articles_req : Here -> LoadReq
	articles_req = |w| {
		route = ConduitApp.route_of(w)
		name = Route.profile_username(route)
		if name.is_empty() {
			ConduitApp.no_req
		} else {
			uri = if (Route.kind(route) == ProfileFavorites) Api.favorited_articles_uri(name) else Api.author_articles_uri(name)
			{ key: uri, uri, token: "" }
		}
	}

	## A handler for a text control of a page's form: `set` puts what was
	## typed into the pages.
	fill : (M, Str -> M) -> Engine.Handler(Engine.StoreRoot(_))
	fill = |set| Engine.handle(|value| [ConduitApp.pages.update(|m| set(m, value))])

	## A load site: issue a GET whenever the request record changes; store
	## the decoded result only while it is still the current request, which
	## `store` decides from where the reader is when the answer arrives.
	load_site : Signal(Engine.StoreRoot(_), LoadReq), (M, Here, LoadReq, Engine.Result -> M) -> Elem(Engine.StoreRoot(_))
	load_site = |req, store| Engine.watch(
		req,
		|r| if (r.uri.is_empty()) [] else [Api.get_request(r.uri, r.token)],
		Engine.react_by(ConduitApp.here, |at, asked, res| [ConduitApp.pages.update(|m| store(m, at, asked, res))]),
	)

	store_feed : M, Here, LoadReq, Engine.Result -> M
	store_feed = |m, w, r, res| if (ConduitApp.feed_req(w).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, feed: { key: r.key, value: Api.decode_feed_response(Api.response_of(res)) } })

	store_tags : M, Here, LoadReq, Engine.Result -> M
	store_tags = |m, _, r, res| ConduitApp.set_loads(m, |l| { ..l, tags: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_tags) } })

	store_profile : M, Here, LoadReq, Engine.Result -> M
	store_profile = |m, w, r, res| if (ConduitApp.profile_req(w, m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, profile: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_profile) } })

	store_articles : M, Here, LoadReq, Engine.Result -> M
	store_articles = |m, w, r, res| if (ConduitApp.articles_req(w).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, articles: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_feed) } })

	feed_remote : Here, M -> Api.Remote(Api.FeedPage)
	feed_remote = |w, m| ConduitApp.remote(m.loads.feed, ConduitApp.feed_req(w).key)

	edit_req : Here -> LoadReq
	edit_req = |w| {
		slug = Route.article_slug(ConduitApp.route_of(w))
		if (slug.is_empty()) ConduitApp.no_req else { key: Api.article_uri(slug), uri: Api.article_uri(slug), token: "" }
	}

	store_edit : M, Here, LoadReq, Engine.Result -> M
	store_edit = |m, w, r, res| if (ConduitApp.edit_req(w).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, article: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_article) } })

	## ------------------------------------------------------------------
	## Mutations.

	plan_submit : Submit -> List(Engine.Request)
	plan_submit = |s| {
		if s.serial == 0 {
			[]
		} else if s.method == "GET" or s.method == "DELETE" {
			[Http({ method: s.method, url: s.url, headers: Api.auth_headers(s.token), body: s.body, timeout_ms: Api.timeout_ms })]
		} else {
			[Http({ method: s.method, url: s.url, headers: Api.json_headers(s.token), body: s.body, timeout_ms: Api.timeout_ms })]
		}
	}

	next : Submit, Str, Str, Str, Str -> Submit
	next = |prev, method, url, body, token| { serial: prev.serial + 1, method, url, body, token }

	submit_site : Signal(Engine.StoreRoot(_), Submit), Reaction(Engine.StoreRoot(_), Submit) -> Elem(Engine.StoreRoot(_))
	submit_site = |sub, react| Engine.watch(sub, ConduitApp.plan_submit, react)

	classify_favorite : Api.ResponseState, Str -> FavoriteResult
	classify_favorite = |response, empty_message| {
		if !response.error.is_empty() {
			FavoriteRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_article(response.body) {
				Ready(article) => FavoriteAccepted(article)
				Failed(message) => FavoriteRejected(message)
				Loading => FavoriteRejected(empty_message)
			}
		} else if response.status == 401 {
			FavoriteRejected("Please sign in to favorite articles.")
		} else if response.status == 404 {
			FavoriteRejected("Article was not found.")
		} else {
			FavoriteRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_article : Api.ResponseState -> ArticleResult
	classify_article = |response| {
		if !response.error.is_empty() {
			ArticleErrored("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 201 {
			match Api.decode_article(response.body) {
				Ready(article) => ArticleAccepted(article)
				Failed(message) => ArticleErrored(message)
				Loading => ArticleErrored("The server response could not be read.")
			}
		} else if response.status == 422 {
			ArticleRejected(Api.parse_errors(response.body))
		} else if response.status == 401 {
			ArticleErrored("Please sign in to edit articles.")
		} else {
			ArticleErrored("The server responded with status ${response.status.to_str()}.")
		}
	}

	classify_follow : Api.ResponseState -> FollowResult
	classify_follow = |response| {
		if !response.error.is_empty() {
			FollowRejected("Request failed: ${response.error}")
		} else if response.status == 200 {
			match Api.decode_profile(response.body) {
				Ready(profile) => FollowAccepted(profile)
				Failed(message) => FollowRejected(message)
				Loading => FollowRejected("The server returned an empty profile response.")
			}
		} else if response.status == 401 {
			FollowRejected("Please sign in to follow profiles.")
		} else if response.status == 404 {
			FollowRejected("Profile was not found.")
		} else {
			FollowRejected("The server responded with status ${response.status.to_str()}.")
		}
	}

	## Auth (sign in / sign up).
	submit_auth : M, Bool -> M
	submit_auth = |m, is_register| {
		a = m.auth
		(url, body) = if (is_register) ("/api/users", Api.register_body(a.username, a.email, a.password)) else ("/api/users/login", Api.login_body(a.email, a.password))
		{ ..m, auth: { ..a, sub: ConduitApp.next(a.sub, "POST", url, body, "") } }
	}

	## What an answer to a sign-in or sign-up writes, decided once from the
	## pages as they are when it arrives: the form records the answer, and
	## an accepted one asks to go home and brings in the user it names. An
	## answer to anything but the latest submission writes nothing.
	##
	## The navigation comes first and the session a turn later, applied by
	## a root follow-up turn (`incoming`): home mounts anonymous (feed and
	## tags) and then asks for the feed again with the token. The sign-in
	## spec pins that order.
	auth_answered : M, Submit, Engine.Result -> List(Engine.Write(_))
	auth_answered = |m, req, res| {
		if req.serial != m.auth.sub.serial {
			[]
		} else {
			result = Api.classify_auth(Api.response_of(res))
			recorded = ConduitApp.pages.update(|p| { ..p, auth: { ..p.auth, result } })
			match result {
				AuthAccepted(user) => [recorded, AppStore.asking(ConduitApp.home_url), AppStore.cells.incoming.set(SignedIn({ token: user.token, username: user.username }))]
				_ => [recorded]
			}
		}
	}

	update_body : SettingsForm -> Str
	update_body = |form| Json.to_str({ user: { image: form.image, bio: form.bio, email: form.email, password: form.password } })

	submit_settings : M, Here -> M
	submit_settings = |m, w| {
		s = m.settings
		{ ..m, settings: { ..s, sub: ConduitApp.next(s.sub, "PUT", "/api/user", ConduitApp.update_body(s), ConduitApp.token_of(w.session)) } }
	}

	react_settings : M, Submit, Engine.Result -> M
	react_settings = |m, req, res| if (req.serial != m.settings.sub.serial) m else { ..m, settings: { ..m.settings, result: Api.classify_auth(Api.response_of(res)) } }

	parse_tags : Str -> List(Str)
	parse_tags = |raw| raw.split_on(",").map(|part| part.trim()).keep_if(|tag| !tag.is_empty())

	article_body : Str, Str, Str, List(Str) -> Str
	article_body = |title, description, body, tags| {
		encoded_tags = Str.join_with(tags.map(|tag| Json.to_str(tag)), ",")
		"{\"article\":{\"title\":${Json.to_str(title)},\"description\":${Json.to_str(description)},\"body\":${Json.to_str(body)},\"tagList\":[${encoded_tags}]}}"
	}

	submit_editor : M, Here -> M
	submit_editor = |m, w| {
		e = m.editor
		body = ConduitApp.article_body(e.title.trim(), e.description.trim(), e.body, ConduitApp.parse_tags(e.tags))
		slug = Route.article_slug(ConduitApp.route_of(w))
		(method, url) = if (slug.is_empty()) ("POST", "/api/articles") else ("PUT", Api.article_uri(slug))
		{ ..m, editor: { ..e, sub: ConduitApp.next(e.sub, method, url, body, ConduitApp.token_of(w.session)) } }
	}

	## What an answer to a published article writes: the form records it,
	## and an accepted article is where the reader asks to go next. An
	## answer to anything but the latest submission writes nothing.
	editor_answered : M, Submit, Engine.Result -> List(Engine.Write(_))
	editor_answered = |m, req, res| {
		if req.serial != m.editor.sub.serial {
			[]
		} else {
			result = ConduitApp.classify_article(Api.response_of(res))
			recorded = ConduitApp.pages.update(|p| { ..p, editor: { ..p.editor, result } })
			match result {
				ArticleAccepted(article) => [recorded, AppStore.asking(Route.to_url(Route.article_location(article.slug)))]
				_ => [recorded]
			}
		}
	}

	profile_remote : Here, M -> Api.Remote(Api.Profile)
	profile_remote = |w, m| ConduitApp.remote(m.loads.profile, ConduitApp.profile_req(w, m).key)

	follow : M, Here -> M
	follow = |m, w| match ConduitApp.profile_remote(w, m) {
		Ready(p) => {
			method = if (p.following) "DELETE" else "POST"
			{ ..m, prof: { ..m.prof, follow: ConduitApp.next(m.prof.follow, method, Api.follow_uri(p.username), "", ConduitApp.token_of(w.session)), follow_result: FollowIdle } }
		}
		_ => m
	}

	react_follow : M, Submit, Engine.Result -> M
	react_follow = |m, req, res| {
		if req.serial != m.prof.follow.serial {
			m
		} else {
			result = ConduitApp.classify_follow(Api.response_of(res))
			match result {
				FollowAccepted(_) => { ..m, prof: { ..m.prof, follow_result: result, refetch: m.prof.refetch + 1 } }
				_ => { ..m, prof: { ..m.prof, follow_result: result } }
			}
		}
	}

	## Feed row favorites (row-local state).
	row_state : Api.ArticleSummary, FavoriteResult -> Api.ArticleSummary
	row_state = |article, result| match result {
		FavoriteAccepted(updated) => { ..article, favorited: updated.favorited, favorites_count: updated.favorites_count }
		_ => article
	}

	favorite_button_label : Api.ArticleSummary -> Str
	favorite_button_label = |article| {
		prefix = if (article.favorited) "Unfavorite" else "Favorite"
		"${prefix} ${article.title} (${article.favorites_count.to_str()})"
	}

	react_row_fav : FavState, Submit, Engine.Result -> FavState
	react_row_fav = |s, req, res| if (req.serial != s.req.serial) s else { ..s, result: ConduitApp.classify_favorite(Api.response_of(res), "The server response could not be read.") }

	## Pagination.
	PageItem : { key : Str, active : Bool }

	page_items : Api.Remote(Api.FeedPage), Route.Feed -> List(PageItem)
	page_items = |r, feed| match r {
		Ready(page) => {
			count = Api.page_count(page.articles_count)
			if count <= 1 {
				[]
			} else {
				var $items = []
				var $n = 1.U64
				while $n <= count {
					$items = $items.append({ key: ConduitApp.page_key($n, feed.tag), active: $n == feed.page })
					$n = $n + 1
				}
				$items
			}
		}
		_ => []
	}

	page_key : U64, [AllTags, Tagged(Str)] -> Str
	page_key = |number, tag| match tag {
		Tagged(name) => "${number.to_str()}|${name}"
		AllTags => "${number.to_str()}|"
	}

	page_label : Str -> Str
	page_label = |key| key.split_first("|").map_ok(|split| split.before) ?? key

	key_url : Str -> Str
	key_url = |key| {
		loc = key.split_first("|").map_ok(
			|split| {
				page = U64.from_str(split.before) ?? 1
				tag = if (split.after.is_empty()) AllTags else Tagged(split.after)
				Route.feed_location({ page, tag, source: Global })
			},
		)
			?? Route.home_location
		Route.to_url(loc)
	}

	tag_url : Str -> Str
	tag_url = |tag| Route.to_url(Route.feed_location({ page: 1, tag: Tagged(tag), source: Global }))

	profile_url : Str -> Str
	profile_url = |name| Route.to_url(Route.profile_location(name))

	article_url : Str -> Str
	article_url = |slug| Route.to_url(Route.article_location(slug))

	keyed_lines : List(Str) -> List({ key : Str, text : Str })
	keyed_lines = |lines| {
		var $out = []
		var $i = 0.U64
		for line in lines {
			$out = $out.append({ key: "e:${$i.to_str()}", text: line })
			$i = $i + 1
		}
		$out
	}

	auth_errors : Api.AuthResult -> List(Str)
	auth_errors = |result| match result {
		AuthRejected(lines) => lines
		AuthErrored(message) => [message]
		_ => []
	}

	article_errors : ArticleResult -> List(Str)
	article_errors = |result| match result {
		ArticleRejected(lines) => lines
		ArticleErrored(message) => [message]
		_ => []
	}

	is_loading : Api.Remote(a) -> Bool
	is_loading = |r| match r {
		Loading => True
		_ => False
	}

	is_failed : Api.Remote(a) -> Bool
	is_failed = |r| match r {
		Failed(_) => True
		_ => False
	}

	failure : Api.Remote(a) -> Str
	failure = |r| match r {
		Failed(message) => message
		_ => ""
	}

	## ------------------------------------------------------------------
	## View helpers (generic in the context).

	button : Str, Str, Engine.Handler(ctx) -> Elem(ctx)
	button = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text(label)])

	button_s : Signal(ctx, Str), Str, Engine.Handler(ctx) -> Elem(ctx)
	button_s = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text_s(label)])

	input : Str, Str, Signal(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	input = |name, kind, v, h| Engine.element("input", [Engine.attr("aria-label", name), Engine.attr("type", kind), Engine.class(Styles.field), Engine.prop_s(Engine.Prop.value, v), Engine.on("input", h)], [])

	textarea : Str, Signal(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	textarea = |name, v, h| Engine.element("textarea", [Engine.attr("aria-label", name), Engine.class(Styles.field), Engine.prop_s(Engine.Prop.value, v), Engine.on("input", h)], [])

	heading : Str, Str -> Elem(ctx)
	heading = |t, cls| Engine.element("h1", [Engine.class(cls)], [Engine.text(t)])

	error_list : Signal(ctx, List(Str)) -> Elem(ctx)
	error_list = |errors| Engine.element(
		"div",
		[],
		[
			Engine.when(
				errors.map(|l| !l.is_empty()),
				|| Engine.element("ul", [Engine.class(Styles.error_list)], [Engine.each(errors.map(ConduitApp.keyed_lines), |i| i.key, |row| Engine.element("li", [], [Engine.text_s(row.field(|i| i.text))]))]),
				|| Engine.text(""),
			),
		],
	)

	## ------------------------------------------------------------------
	## Shared article list.

	tag_pill : RowRef(ctx, Str) -> Elem(Row(ctx, Str))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	tag_pill = |row| {
		key = row.key()
		Engine.element("a", [Engine.class("border border-zinc-400 px-2 py-0.5 font-mono text-xs text-zinc-600 no-underline"), Engine.attr_s("href", key.map(ConduitApp.tag_url)), Engine.on_with("click", { prevent: True }, AppStore.go_by(key.map(ConduitApp.tag_url)))], [Engine.text_s(key)])
	}

	preview_body : Signal(Engine.In(Row(Engine.StoreRoot(_), Api.ArticleSummary), FavState), Api.ArticleSummary), State(Engine.In(Row(Engine.StoreRoot(_), Api.ArticleSummary), FavState), FavState) -> Elem(Engine.In(Row(Engine.StoreRoot(_), Api.ArticleSummary), FavState))
	preview_body = |art, fst| {
		shown = art.map2(fst.signal(), |a, s| ConduitApp.row_state(a, s.result))
		session = AppStore.cells.session.signal()
		token = session.map(ConduitApp.token_of)
		author = art.map(|a| a.author.username)
		Engine.element(
			"div",
			[],
			[
				Engine.watch(fst.signal().map(|s| s.req), ConduitApp.plan_submit, fst.on_result(ConduitApp.react_row_fav)),
				Html.div(
					"mb-3 flex flex-wrap items-center gap-2 text-sm text-zinc-500",
					[
						Links.link_s(author, "font-medium text-emerald-600", author.map(ConduitApp.profile_url)),
						Engine.text_s(art.map(|a| Format.display_date(a.created_at))),
					],
				),
				Engine.element(
					"a",
					[Engine.class("block text-2xl font-semibold tracking-normal text-zinc-900 no-underline"), Engine.attr_s("href", art.map(|a| ConduitApp.article_url(a.slug))), Engine.on_with("click", { prevent: True }, AppStore.go_by(art.map(|a| ConduitApp.article_url(a.slug))))],
					[Engine.text_s(shown.map(|a| a.title))],
				),
				Html.p_s(shown.map(|a| a.description), [Engine.class("mt-2 leading-7 text-zinc-600")]),
				Html.div(
					"mt-4 flex flex-wrap items-center justify-between gap-3 text-sm text-zinc-500",
					[
						Engine.when(
							session.map(ConduitApp.is_signed_in),
							|| ConduitApp.button_s(
								shown.map(ConduitApp.favorite_button_label),
								"border border-emerald-600 bg-white px-3 py-1.5 font-medium text-emerald-700",
								fst.update_by(shown.map2(token, |a, t| (a, t)), |s, (a, t)| { ..s, req: ConduitApp.next(s.req, if (a.favorited) "DELETE" else "POST", Api.favorite_uri(a.slug), "", t) }),
							),
							|| Engine.text_s(shown.map(|a| "${a.favorites_count.to_str()} favorites")),
						),
						Engine.element("div", [Engine.class("flex flex-wrap gap-1")], [Engine.each(art.map(|a| a.tag_list), |t| t, |row| ConduitApp.tag_pill(row))]),
					],
				),
				Html.p_s(
					fst.signal().map(
						|s| match s.result {
							FavoriteRejected(message) => message
							_ => ""
						},
					),
					[Engine.class("mt-3 text-sm text-red-700 empty:hidden")],
				),
			],
		)
	}

	preview_row : RowRef(Engine.StoreRoot(_), Api.ArticleSummary) -> Elem(Row(Engine.StoreRoot(_), Api.ArticleSummary))
	preview_row = |row| {
		art = row.item()
		Engine.element(
			"article",
			[Engine.class("border border-zinc-950 bg-white px-5 py-5 sm:px-6")],
			[Engine.state({ req: ConduitApp.no_submit, result: FavoriteIdle }, |fst| ConduitApp.preview_body(art.lift(), fst))],
		)
	}

	## Keep the one stored answer visible while another feed is pending. The
	## status identifies it as previous results; only a matching response can
	## replace it. The keyed rows stay mounted across the loading transition.
	feed_view : { current : Signal(Engine.StoreRoot(_), Api.Remote(Api.FeedPage)), stored : Signal(Engine.StoreRoot(_), Api.Remote(Api.FeedPage)) } -> Elem(Engine.StoreRoot(_))
	feed_view = |{ current, stored }| {
		articles = current.map2(
			stored,
			|requested, loaded| match requested {
				Ready(page) => page.articles
				Loading => match loaded {
					Ready(page) => page.articles
					_ => []
				}
				Failed(_) => []
			},
		)
		loading = current.map(ConduitApp.is_loading)
		Engine.element(
			"section",
			[Engine.attr("data-conduit", "article-list"), Html.aria_label("Articles"), Engine.attr_s("aria-busy", loading.map(|pending| if (pending) "true" else "false"))],
			[
				Engine.element(
					"p",
					[Engine.attr("role", "status"), Engine.class("min-h-6 text-sm leading-6 text-zinc-600")],
					[
						Engine.text_s(loading.map(|pending| if (pending) "Loading articles..." else "")),
						Engine.text_s(loading.map2(articles, |pending, rows| if (pending and !rows.is_empty()) " Showing previous results." else "")),
					],
				),
				Engine.when(
					current.map(ConduitApp.is_failed),
					|| Html.p_s(current.map(ConduitApp.failure), [Engine.class(Styles.status_error)]),
					|| Engine.text(""),
				),
				Engine.when(
					current.map(
						|requested| match requested {
							Ready(page) => page.articles.is_empty()
							_ => False
						},
					),
					|| Html.p("No articles are here... yet.", "border border-dashed border-zinc-400 bg-white p-8 text-center text-zinc-500"),
					|| Engine.text(""),
				),
				Engine.element("div", [Engine.class("grid gap-4")], [Engine.each(articles, |a| a.slug, |row| ConduitApp.preview_row(row))]),
			],
		)
	}

	pagination : {} -> Elem(Engine.StoreRoot(_))
	pagination = |{}| {
		items = ConduitApp.here.map2(ConduitApp.pages.signal(), |w, m| ConduitApp.page_items(m.loads.feed.value, Route.feed_of(ConduitApp.route_of(w))))
		Engine.element(
			"nav",
			[Engine.attr("aria-label", "Pagination"), Engine.class("flex flex-wrap gap-2 py-6")],
			[
				Engine.each(
					items,
					|i| i.key,
					|row| {
						key = row.key()
						cls = row.field(|i| if (i.active) "bg-emerald-600 px-3 py-2 text-sm font-medium text-white no-underline" else "border border-zinc-950 bg-white px-3 py-2 text-sm text-zinc-700 no-underline")
						Engine.element("a", [Engine.class_s(cls), Engine.attr_s("href", key.map(ConduitApp.key_url)), Engine.on_with("click", { prevent: True }, AppStore.go_by(key.map(ConduitApp.key_url)))], [Engine.text_s(key.map(ConduitApp.page_label))])
					},
				),
			],
		)
	}

	## ------------------------------------------------------------------
	## Pages.

	home_page : {} -> Elem(Engine.StoreRoot(_))
	home_page = |{}| {
		mv = ConduitApp.pages.signal()
		w = ConduitApp.here
		feed = w.map(|x| Route.feed_of(ConduitApp.route_of(x)))
		signed_in = AppStore.cells.session.signal().map(ConduitApp.is_signed_in)
		tags = mv.map(|m| ConduitApp.remote(m.loads.tags, "tags"))
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline"
		idle = "border-b-2 border-transparent px-4 py-3 text-zinc-500 no-underline"
		Html.section(
			"Home",
			"pb-12",
			[
				ConduitApp.load_site(w.map(ConduitApp.feed_req), ConduitApp.store_feed),
				ConduitApp.load_site(w.map(ConduitApp.tags_req), ConduitApp.store_tags),
				Html.div(
					"bg-emerald-700 px-5 py-12 text-center text-white sm:py-16",
					[
						ConduitApp.heading("conduit", "text-5xl font-bold tracking-normal text-white sm:text-6xl"),
						Html.p("A place to share your knowledge.", "mt-3 text-lg text-emerald-50 sm:text-xl"),
					],
				),
				Html.div(
					"mx-auto grid w-full max-w-6xl gap-8 px-5 py-10 sm:px-8 lg:grid-cols-[minmax(0,1fr)_16rem]",
					[
						Html.div(
							"min-w-0",
							[
								Engine.element(
									"nav",
									[Engine.attr("aria-label", "Feed tabs"), Engine.class("mb-4 flex border-b border-zinc-200")],
									[
										Engine.when(
											signed_in,
											|| Links.link_c("Your Feed", feed.map(|f| if (f.source == Yours) active else idle), Route.to_url(Route.feed_location({ page: 1, tag: AllTags, source: Yours }))),
											|| Engine.text(""),
										),
										Links.link_c("Global Feed", feed.map(|f| if (f.source == Global and f.tag == AllTags) active else idle), ConduitApp.home_url),
									],
								),
								Html.p_s(
									feed.map(
										|f| match f.source {
											Yours => "Your Feed"
											Global => match f.tag {
												Tagged(tag) => "Tag: ${tag}"
												AllTags => "Global Feed"
											}
										},
									),
									[Engine.class("text-sm font-medium text-emerald-700")],
								),
								ConduitApp.feed_view({ current: w.map2(mv, ConduitApp.feed_remote), stored: mv.map(|m| m.loads.feed.value) }),
								ConduitApp.pagination({}),
							],
						),
						Engine.element(
							"aside",
							[Engine.class("h-fit border border-zinc-950 bg-zinc-50 p-5")],
							[
								Html.p("Popular Tags", "mb-3 font-semibold text-zinc-900"),
								Engine.when(
									tags.map(ConduitApp.is_loading),
									|| Html.p("Loading tags...", ""),
									|| Engine.when(
										tags.map(ConduitApp.is_failed),
										|| Html.p("Tags are unavailable.", "text-red-700"),
										|| Html.div(
											"flex flex-wrap gap-1",
											[
												Engine.each(
													tags.map(
														|t| match t {
															Ready(l) => l
															_ => []
														},
													),
													|t| t,
													|row| ConduitApp.tag_pill(row),
												),
											],
										),
									),
								),
							],
						),
					],
				),
			],
		)
	}

	auth_page : Bool -> Elem(Engine.StoreRoot(_))
	auth_page = |is_register| {
		st = ConduitApp.pages
		af = st.signal().map(|m| m.auth)
		title = if (is_register) "Sign up" else "Sign in"
		Html.section(
			title,
			Styles.narrow_page,
			[
				ConduitApp.submit_site(af.map(|a| a.sub), Engine.react_by(st.signal(), ConduitApp.auth_answered)),
				ConduitApp.heading(title, "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Html.div(
					"mb-7 mt-2 text-center",
					[
						if is_register {
							Links.link("Have an account?", "font-medium text-emerald-700", Route.to_url(Route.login_location))
						} else {
							Links.link("Need an account?", "font-medium text-emerald-700", Route.to_url(Route.register_location))
						},
					],
				),
				ConduitApp.error_list(af.map(|a| ConduitApp.auth_errors(a.result))),
				Engine.element(
					"form",
					[Engine.class(Styles.form)],
					[
						if is_register {
							ConduitApp.input("Username", "text", af.map(|a| a.username), ConduitApp.fill(|m, v| { ..m, auth: { ..m.auth, username: v } }))
						} else {
							Engine.text("")
						},
						ConduitApp.input("Email", "email", af.map(|a| a.email), ConduitApp.fill(|m, v| { ..m, auth: { ..m.auth, email: v } })),
						ConduitApp.input("Password", "password", af.map(|a| a.password), ConduitApp.fill(|m, v| { ..m, auth: { ..m.auth, password: v } })),
						ConduitApp.button(title, Styles.primary_button, Engine.does([st.update(|m| ConduitApp.submit_auth(m, is_register))])),
					],
				),
			],
		)
	}

	settings_page : {} -> Elem(Engine.StoreRoot(_))
	settings_page = |{}| {
		st = ConduitApp.pages
		mv = st.signal()
		sf = mv.map(|m| m.settings)
		Html.section(
			"Settings",
			Styles.narrow_page,
			[
				ConduitApp.submit_site(sf.map(|f| f.sub), Engine.react(|sent, res| [st.update(|m| ConduitApp.react_settings(m, sent, res))])),
				ConduitApp.heading("Settings", "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Html.p_s(AppStore.cells.session.signal().map(|x| "Signed in as ${ConduitApp.username_of(x)}"), [Engine.class("mb-7 mt-2 text-center text-sm text-zinc-500")]),
				ConduitApp.error_list(sf.map(|s| ConduitApp.auth_errors(s.result))),
				Html.p_s(
					sf.map(
						|s| match s.result {
							AuthAccepted(_) => "Settings saved."
							_ => ""
						},
					),
					[Engine.class("font-medium text-emerald-700")],
				),
				Engine.element(
					"form",
					[Engine.class(Styles.form)],
					[
						ConduitApp.input("Profile picture URL", "text", sf.map(|s| s.image), ConduitApp.fill(|m, v| { ..m, settings: { ..m.settings, image: v } })),
						ConduitApp.textarea("Bio", sf.map(|s| s.bio), ConduitApp.fill(|m, v| { ..m, settings: { ..m.settings, bio: v } })),
						ConduitApp.input("Email", "email", sf.map(|s| s.email), ConduitApp.fill(|m, v| { ..m, settings: { ..m.settings, email: v } })),
						ConduitApp.input("New password", "password", sf.map(|s| s.password), ConduitApp.fill(|m, v| { ..m, settings: { ..m.settings, password: v } })),
						ConduitApp.button("Update Settings", Styles.primary_button, Engine.handle_by(ConduitApp.here, |at, _| [st.update(|m| ConduitApp.submit_settings(m, at))])),
					],
				),
				ConduitApp.button("Sign out", "mt-8 ${Styles.danger_button}", Engine.does([AppStore.cells.session.set(Anonymous)])),
			],
		)
	}

	editor_form : Str -> Elem(Engine.StoreRoot(_))
	editor_form = |label| {
		st = ConduitApp.pages
		ef = st.signal().map(|m| m.editor)
		Engine.element(
			"form",
			[Engine.class(Styles.form)],
			[
				ConduitApp.input("Title", "text", ef.map(|e| e.title), ConduitApp.fill(|m, v| { ..m, editor: { ..m.editor, title: v } })),
				ConduitApp.input("Description", "text", ef.map(|e| e.description), ConduitApp.fill(|m, v| { ..m, editor: { ..m.editor, description: v } })),
				ConduitApp.textarea("Body", ef.map(|e| e.body), ConduitApp.fill(|m, v| { ..m, editor: { ..m.editor, body: v } })),
				ConduitApp.input("Tags", "text", ef.map(|e| e.tags), ConduitApp.fill(|m, v| { ..m, editor: { ..m.editor, tags: v } })),
				ConduitApp.button(label, Styles.primary_button, Engine.handle_by(ConduitApp.here, |at, _| [st.update(|m| ConduitApp.submit_editor(m, at))])),
			],
		)
	}

	editor_new_page : {} -> Elem(Engine.StoreRoot(_))
	editor_new_page = |{}| Html.section(
		"New article",
		Styles.wide_page,
		[
			ConduitApp.submit_site(ConduitApp.pages.signal().map(|m| m.editor.sub), Engine.react_by(ConduitApp.pages.signal(), ConduitApp.editor_answered)),
			ConduitApp.heading("New article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
			ConduitApp.error_list(ConduitApp.pages.signal().map(|m| ConduitApp.article_errors(m.editor.result))),
			ConduitApp.editor_form("Publish Article"),
		],
	)

	editor_edit_page : {} -> Elem(Engine.StoreRoot(_))
	editor_edit_page = |{}| {
		mv = ConduitApp.pages.signal()
		w = ConduitApp.here
		article = w.map2(mv, |x, m| ConduitApp.remote(m.loads.article, ConduitApp.edit_req(x).key))
		current = |f| article.map(
			|r| match r {
				Ready(a) => f(a)
				_ => ""
			},
		)
		Html.section(
			"Edit article",
			Styles.wide_page,
			[
				ConduitApp.load_site(w.map(ConduitApp.edit_req), ConduitApp.store_edit),
				ConduitApp.submit_site(mv.map(|m| m.editor.sub), Engine.react_by(mv, ConduitApp.editor_answered)),
				ConduitApp.heading("Edit article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Engine.when(
					article.map(ConduitApp.is_loading),
					|| Html.p("Loading article...", ""),
					|| Engine.when(
						article.map(ConduitApp.is_failed),
						|| Html.p_s(article.map(ConduitApp.failure), [Engine.class("text-red-700")]),
						|| Html.div(
							"mb-4 space-y-1 border border-zinc-950 bg-zinc-50 p-3 text-sm text-zinc-700",
							[
								Html.p_s(current(|a| "Current title: ${a.title}"), []),
								Html.p_s(current(|a| "Current description: ${a.description}"), []),
								Html.p_s(current(|a| "Current body: ${a.body}"), []),
								Html.p_s(current(|a| "Current tags: ${Str.join_with(a.tag_list, ", ")}"), []),
							],
						),
					),
				),
				ConduitApp.error_list(mv.map(|m| ConduitApp.article_errors(m.editor.result))),
				ConduitApp.editor_form("Update Article"),
			],
		)
	}

	## The article page: its state is cells of the store, so it takes nothing.
	article_page : {} -> Elem(Engine.StoreRoot(_))
	article_page = |{}| ArticlePage.view({})

	profile_page : Bool -> Elem(Engine.StoreRoot(_))
	profile_page = |favorites| {
		st = ConduitApp.pages
		mv = st.signal()
		w = ConduitApp.here
		profile = w.map2(mv, ConduitApp.profile_remote)
		field = |f| profile.map(
			|r| match r {
				Ready(p) => f(p)
				_ => ""
			},
		)
		username = w.map(|x| Route.profile_username(ConduitApp.route_of(x)))
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline"
		idle = "border-b-2 border-transparent px-4 py-3 text-zinc-500 no-underline"
		Html.section(
			"Profile",
			Styles.page,
			[
				ConduitApp.load_site(w.map2(mv, ConduitApp.profile_req), ConduitApp.store_profile),
				ConduitApp.load_site(w.map(ConduitApp.articles_req), ConduitApp.store_articles),
				ConduitApp.submit_site(mv.map(|m| m.prof.follow), Engine.react(|sent, res| [st.update(|m| ConduitApp.react_follow(m, sent, res))])),
				Engine.when(
					profile.map(ConduitApp.is_loading),
					|| Html.p("Loading profile...", "border border-zinc-950 bg-white p-6 text-zinc-500"),
					|| Engine.when(
						profile.map(ConduitApp.is_failed),
						|| Html.p_s(profile.map(ConduitApp.failure), [Engine.class(Styles.status_error)]),
						|| Engine.element(
							"div",
							[Engine.attr("data-conduit", "profile"), Engine.class("mb-8 border border-zinc-950 bg-white p-6 text-center sm:p-8")],
							[
								Engine.element("h2", [Engine.class("text-3xl font-semibold tracking-normal text-zinc-950")], [Engine.text_s(field(|p| "@${p.username}"))]),
								Html.p_s(field(|p| p.bio), [Engine.class("mx-auto mt-2 max-w-2xl leading-7 text-zinc-600")]),
								Engine.when(
									w.map2(
										mv,
										|x, m| match ConduitApp.profile_remote(x, m) {
											Ready(p) => ConduitApp.is_signed_in(x.session) and p.username != ConduitApp.username_of(x.session)
											_ => False
										},
									),
									|| ConduitApp.button_s(
										profile.map(
											|r| match r {
												Ready(p) => if (p.following) "Unfollow ${p.username}" else "Follow ${p.username}"
												_ => "Follow"
											},
										),
										"mt-4 border border-emerald-600 bg-white px-4 py-2 text-sm font-medium text-emerald-700",
										Engine.handle_by(w, |at, _| [st.update(|m| ConduitApp.follow(m, at))]),
									),
									|| Engine.text(""),
								),
								Html.p_s(
									mv.map(
										|m| match m.prof.follow_result {
											FollowRejected(message) => message
											_ => ""
										},
									),
									[Engine.class("text-red-700")],
								),
							],
						),
					),
				),
				Engine.element(
					"nav",
					[Engine.attr("aria-label", "Profile tabs"), Engine.class("flex border-b border-zinc-200")],
					[
						Html.div(
							"flex",
							[
								Links.link_s(Engine.const("My Articles"), if (favorites) idle else active, username.map(ConduitApp.profile_url)),
								Links.link_s(Engine.const("Favorited Articles"), if (favorites) active else idle, username.map(|u| Route.to_url(Route.profile_favorites_location(u)))),
							],
						),
					],
				),
				ConduitApp.feed_view({ current: w.map2(mv, |x, m| ConduitApp.remote(m.loads.articles, ConduitApp.articles_req(x).key)), stored: mv.map(|m| m.loads.articles.value) }),
			],
		)
	}

	not_found_page : {} -> Elem(Engine.StoreRoot(_))
	not_found_page = |{}| Html.section(
		"Page not found",
		Styles.page,
		[
			ConduitApp.heading("Page not found", Styles.heading),
			Html.p("This address does not match any conduit page.", "mt-3 text-zinc-600"),
			Html.div("mt-6", [Links.link("Take me home", Styles.secondary_button, ConduitApp.home_url)]),
		],
	)

	page : Route.Kind -> Elem(Engine.StoreRoot(_))
	page = |kind| match kind {
		Home => ConduitApp.home_page({})
		Login => ConduitApp.auth_page(False)
		Register => ConduitApp.auth_page(True)
		Settings => ConduitApp.settings_page({})
		EditorNew => ConduitApp.editor_new_page({})
		EditorEdit => ConduitApp.editor_edit_page({})
		Article => ConduitApp.article_page({})
		Profile => ConduitApp.profile_page(False)
		ProfileFavorites => ConduitApp.profile_page(True)
		NotFound => ConduitApp.not_found_page({})
	}

	header : {} -> Elem(Engine.StoreRoot(_))
	header = |{}| {
		session = AppStore.cells.session.signal()
		item = "px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline"
		username = session.map(|s| s.username())
		Engine.element(
			"header",
			[Engine.class(Styles.header)],
			[
				Links.link("conduit", "text-2xl font-bold tracking-normal text-emerald-600 no-underline", ConduitApp.home_url),
				Engine.element(
					"nav",
					[Engine.attr("aria-label", "Site"), Engine.class("flex flex-wrap items-center text-sm font-medium")],
					[
						Links.link("Home", item, ConduitApp.home_url),
						Engine.when(
							session.map(|s| s.is_signed_in()),
							|| Html.div(
								"inline-flex",
								[
									Links.link("New Article", item, Route.to_url(Route.location_for("/editor", ""))),
									Links.link("Settings", item, Route.to_url(Route.location_for("/settings", ""))),
									Links.link_s(username, "px-3 py-2 text-emerald-700 no-underline", username.map(ConduitApp.profile_url)),
								],
							),
							|| Html.div(
								"inline-flex",
								[
									Links.link("Sign in", item, Route.to_url(Route.login_location)),
									Links.link("Sign up", item, Route.to_url(Route.register_location)),
								],
							),
						),
					],
				),
			],
		)
	}

	all_kinds : List(Route.Kind)
	all_kinds = [Home, Login, Register, Settings, EditorNew, EditorEdit, Article, Profile, ProfileFavorites, NotFound]

	storage_plan : Session -> List(Engine.Request)
	storage_plan = |s| match s {
		SignedIn(u) => [StorageSet(AppStore.jwt_key, u.token), StorageSet(AppStore.username_key, u.username)]
		Anonymous => [StorageRemove(AppStore.jwt_key), StorageRemove(AppStore.username_key)]
	}

	## The whole app. Who is signed in, where the reader is, the navigation
	## asked for and the incoming session are cells of the store, so a
	## change elsewhere wakes none of their readers.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		session = AppStore.cells.session.signal()
		loc = AppStore.cells.loc.signal()
		Html.div(
			Styles.shell,
			[
				## Root effects: popstate, history push, guard redirect, title, session storage.
				Engine.watch(
					Engine.const(0.U8),
					|_| [Popstate],
					Engine.react_by(
						ConduitApp.here,
						|at, _, res| match res {
							Location(url) => AppStore.moved(at, url)
							_ => []
						},
					),
				),
				Engine.on_post(AppStore.cells.nav.signal(), |url| [Push(url), Self], Engine.react_by(ConduitApp.here, |at, url, _| AppStore.moved(at, url))),
				Engine.watch(ConduitApp.here.map(|w| ConduitApp.guard_for(w.loc, w.session)), |u| if (u.is_empty()) [] else [Replace(u), Self], Engine.react_by(ConduitApp.here, |at, u, _| if (!u.is_empty() and ConduitApp.guard_for(at.loc, at.session) == u) AppStore.moved(at, u) else [])),
				Engine.watch(ConduitApp.here.map2(AppStore.cells.article.cells.story.signal(), ConduitApp.title_of), |t| [Title(t)], Engine.ignore({})),
				Engine.watch_changes(session, ConduitApp.storage_plan, Engine.ignore({})),
				Engine.watch_changes(
					AppStore.cells.incoming.signal(),
					|s| match s {
						SignedIn(_) => [Self]
						Anonymous => []
					},
					Engine.react(|s, _| [AppStore.cells.session.set(s), AppStore.cells.incoming.set(Anonymous)]),
				),
				ConduitApp.header({}),
				Engine.element("main", [Engine.class(Styles.main)], [Engine.switch(loc.map(|url| Route.kind(Route.of_url(url))), ConduitApp.all_kinds, |k| ConduitApp.page(k))]),
				Engine.element(
					"footer",
					[Engine.class(Styles.footer)],
					[
						Engine.element("span", [Engine.class("font-semibold text-emerald-600")], [Engine.text("conduit")]),
						Engine.text(" - the RealWorld demo app, built with Roc Signals."),
					],
				),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: ["conduit.jwt", "conduit.username"], max_inflight: 32 }, AppStore.start, |_| ConduitApp.view({}))

}

## An answer to an older sign-in writes nothing.
expect ConduitApp.auth_answered(Pages.init(""), { ..Pages.no_submit, serial: 7 }, Timeout).is_empty()

## An accepted sign-in records the answer, asks to go home and brings the user in.
expect {
	body = "{\"user\":{\"email\":\"kim@conduit.test\",\"token\":\"jwt\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}"
	after = AppStore.store.after(ConduitApp.auth_answered(Pages.init(""), Pages.no_submit, Http({ status: 200, headers: [], body })))
	after.read(AppStore.cells.incoming) == Session.SignedIn({ token: "jwt", username: "kim" }) and after.read(AppStore.cells.nav).last() == Posted(AppStore.home_url)
}

## A rejected sign-in records the answer and nothing else.
expect ConduitApp.auth_answered(Pages.init(""), Pages.no_submit, Http({ status: 422, headers: [], body: "{\"errors\":{\"body\":[\"bad\"]}}" })).len() == 1
