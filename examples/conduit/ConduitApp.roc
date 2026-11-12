import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Api
import Route
import Format
import Markdown
import Styles

## Conduit (RealWorld) on the pure Roc engine: ported from the previous engine with its original specs.
##
## One root state holds the location, the session and every page's model;
## changing the route's kind resets the page models (the original remounted
## its per-page `Ui.state`s). Pages are a `switch` over the route kind, so
## leaving a page disposes its effect sites and cancels their requests.
##
## Effects are sites that watch state:
## - loads watch a request record ({ key, uri, token }); a result is stored
##   only while its key is still the page's current key (the original
##   `Load` generation check), so an older response never overwrites a newer
##   one;
## - mutations watch a submission snapshot ({ serial, method, url, body,
##   token }) written by the click; a result applies only while its serial is
##   the latest (the original serial checks);
## - the root owns the popstate subscription, history push (an `on_post`
##   site sending each navigation the app posts), the guard redirect
##   (Replace plus a `Self` follow-up that moves the location), the
##   document title and the session's storage keys.
ConduitApp := [].{
	C : In(Root, M)

	Session : [Anonymous, SignedIn({ token : Str, username : Str })]

	Loaded(a) : { key : Str, value : Api.Remote(a) }

	LoadReq : { key : Str, uri : Str, token : Str }

	## A mutation request snapshot; serial 0 = nothing submitted.
	Submit : { serial : U64, method : Str, url : Str, body : Str, token : Str }

	Loads : {
		feed : Loaded(Api.FeedPage),
		tags : Loaded(List(Str)),
		article : Loaded(Api.Article),
		comments : Loaded(List(Api.Comment)),
		profile : Loaded(Api.Profile),
		articles : Loaded(Api.FeedPage),
	}

	ArticleResult : [ArticleIdle, ArticleAccepted(Api.Article), ArticleRejected(List(Str)), ArticleErrored(Str)]

	FavoriteResult : [FavoriteIdle, FavoriteAccepted(Api.Article), FavoriteRejected(Str)]

	DeleteResult : [DeleteIdle, DeleteAccepted, DeleteRejected(Str)]

	CommentResult : [CommentIdle, CommentAccepted, CommentRejected(List(Str)), CommentErrored(Str)]

	FollowResult : [FollowIdle, FollowAccepted(Api.Profile), FollowRejected(Str)]

	AuthForm : { username : Str, email : Str, password : Str, sub : Submit, result : Api.AuthResult }

	SettingsForm : { image : Str, bio : Str, email : Str, password : Str, sub : Submit, result : Api.AuthResult }

	EditorForm : { title : Str, description : Str, body : Str, tags : Str, sub : Submit, result : ArticleResult }

	ArticleModel : {
		fav : Submit,
		fav_result : FavoriteResult,
		del : Submit,
		del_result : DeleteResult,
		comment_body : Str,
		comment : Submit,
		comment_result : CommentResult,
		cdel : Submit,
		cdel_result : DeleteResult,
		refetch_article : U64,
		refetch_comments : U64,
	}

	ProfileModel : { follow : Submit, follow_result : FollowResult, refetch : U64 }

	M : {
		loc : Str,
		nav : Engine.Outbox(Str),
		session : Session,

		## A session accepted by a login, applied in the turn after the
		## navigation it triggers (as the original's storage-backed session
		## source refreshed after the home page mounted).
		incoming : Session,
		loads : Loads,
		auth : AuthForm,
		settings : SettingsForm,
		editor : EditorForm,
		art : ArticleModel,
		prof : ProfileModel,
	}

	FavState : { req : Submit, result : FavoriteResult }

	## ------------------------------------------------------------------
	## Model.

	no_submit : Submit
	no_submit = { serial: 0, method: "", url: "", body: "", token: "" }

	no_load : {} -> Loaded(a)
	no_load = |_| { key: "", value: Loading }

	empty_loads : Loads
	empty_loads = { feed: ConduitApp.no_load({}), tags: ConduitApp.no_load({}), article: ConduitApp.no_load({}), comments: ConduitApp.no_load({}), profile: ConduitApp.no_load({}), articles: ConduitApp.no_load({}) }

	auth0 : AuthForm
	auth0 = { username: "", email: "", password: "", sub: ConduitApp.no_submit, result: AuthIdle }

	settings0 : SettingsForm
	settings0 = { image: "", bio: "", email: "", password: "", sub: ConduitApp.no_submit, result: AuthIdle }

	editor0 : EditorForm
	editor0 = { title: "", description: "", body: "", tags: "", sub: ConduitApp.no_submit, result: ArticleIdle }

	art0 : ArticleModel
	art0 = {
		fav: ConduitApp.no_submit,
		fav_result: FavoriteIdle,
		del: ConduitApp.no_submit,
		del_result: DeleteIdle,
		comment_body: "",
		comment: ConduitApp.no_submit,
		comment_result: CommentIdle,
		cdel: ConduitApp.no_submit,
		cdel_result: DeleteIdle,
		refetch_article: 0,
		refetch_comments: 0,
	}

	prof0 : ProfileModel
	prof0 = { follow: ConduitApp.no_submit, follow_result: FollowIdle, refetch: 0 }

	jwt_key : Str
	jwt_key = "conduit.jwt"

	username_key : Str
	username_key = "conduit.username"

	home_url : Str
	home_url = Route.to_url(Route.home_location)

	initial : Engine.Boot -> M
	initial = |boot| {
		session = match (Engine.boot_storage(boot, ConduitApp.jwt_key), Engine.boot_storage(boot, ConduitApp.username_key)) {
			(Ok(token), Ok(username)) => SignedIn({ token, username })
			_ => Anonymous
		}
		{
			loc: if (boot.url.is_empty()) ConduitApp.home_url else boot.url,
			nav: Engine.outbox({}),
			session,
			incoming: Anonymous,
			loads: ConduitApp.empty_loads,
			auth: ConduitApp.auth0,
			settings: ConduitApp.settings0,
			editor: ConduitApp.editor0,
			art: ConduitApp.art0,
			prof: ConduitApp.prof0,
		}
	}

	route_of : M -> Route
	route_of = |m| Route.of_url(m.loc)

	token_of : Session -> Str
	token_of = |s| match s {
		SignedIn(u) => u.token
		Anonymous => ""
	}

	username_of : Session -> Str
	username_of = |s| match s {
		SignedIn(u) => u.username
		Anonymous => ""
	}

	is_signed_in : Session -> Bool
	is_signed_in = |s| match s {
		SignedIn(_) => True
		Anonymous => False
	}

	## Move to `url` (no history entry). Changing the page kind resets every
	## page model, as remounting the original page did.
	set_loc : M, Str -> M
	set_loc = |m, url| {
		if Route.kind(Route.of_url(url)) == Route.kind(ConduitApp.route_of(m)) {
			{ ..m, loc: url }
		} else {
			{ ..m, loc: url, loads: ConduitApp.empty_loads, auth: ConduitApp.auth0, settings: ConduitApp.settings0, editor: ConduitApp.editor0, art: ConduitApp.art0, prof: ConduitApp.prof0 }
		}
	}

	## An in-app navigation: move, and post the URL for a history push.
	navigate : M, Str -> M
	navigate = |m, url| ConduitApp.set_loc({ ..m, nav: m.nav.post(url) }, url)

	guard_url : M -> Str
	guard_url = |m| {
		kind = Route.kind(ConduitApp.route_of(m))
		signed_in = ConduitApp.is_signed_in(m.session)
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

	title_of : M -> Str
	title_of = |m| {
		route = ConduitApp.route_of(m)
		match route {
			Article(_) => match ConduitApp.remote(m.loads.article, ConduitApp.article_req(m).key) {
				Ready(a) => "${a.title} - Conduit"
				_ => Route.title(route)
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

	feed_req : M -> LoadReq
	feed_req = |m| match ConduitApp.route_of(m) {
		Home(feed) => {
			uri = Api.feed_uri(feed)
			token = ConduitApp.token_of(m.session)
			{ key: "${uri}|${token}", uri, token }
		}
		_ => ConduitApp.no_req
	}

	tags_req : M -> LoadReq
	tags_req = |_| { key: "tags", uri: Api.tags_uri, token: "" }

	article_req : M -> LoadReq
	article_req = |m| {
		slug = Route.article_slug(ConduitApp.route_of(m))
		if slug.is_empty() {
			ConduitApp.no_req
		} else {
			uri = Api.article_uri(slug)
			{ key: "${uri}#${m.art.refetch_article.to_str()}", uri, token: "" }
		}
	}

	comments_req : M -> LoadReq
	comments_req = |m| {
		slug = Route.article_slug(ConduitApp.route_of(m))
		if slug.is_empty() {
			ConduitApp.no_req
		} else {
			uri = Api.comments_uri(slug)
			{ key: "${uri}#${m.art.refetch_comments.to_str()}", uri, token: "" }
		}
	}

	profile_req : M -> LoadReq
	profile_req = |m| {
		name = Route.profile_username(ConduitApp.route_of(m))
		if name.is_empty() {
			ConduitApp.no_req
		} else {
			uri = Api.profile_uri(name)
			{ key: "${uri}#${m.prof.refetch.to_str()}", uri, token: "" }
		}
	}

	articles_req : M -> LoadReq
	articles_req = |m| {
		route = ConduitApp.route_of(m)
		name = Route.profile_username(route)
		if name.is_empty() {
			ConduitApp.no_req
		} else {
			uri = if (Route.kind(route) == ProfileFavorites) Api.favorited_articles_uri(name) else Api.author_articles_uri(name)
			{ key: uri, uri, token: "" }
		}
	}

	## A load site: issue a GET whenever the request record changes; store
	## the decoded result only while it is still the current request.
	load_site : State(C, M), (M -> LoadReq), (M, LoadReq, Engine.Res -> M) -> Elem(C)
	load_site = |st, req_of, store| Engine.watch(
		st.val().map(req_of),
		|r| if (r.uri.is_empty()) [] else [Api.get_request(r.uri, r.token)],
		st.on_result(store),
	)

	store_feed : M, LoadReq, Engine.Res -> M
	store_feed = |m, r, res| if (ConduitApp.feed_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, feed: { key: r.key, value: Api.decode_feed_response(Api.response_of(res)) } })

	store_tags : M, LoadReq, Engine.Res -> M
	store_tags = |m, r, res| ConduitApp.set_loads(m, |l| { ..l, tags: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_tags) } })

	store_article : M, LoadReq, Engine.Res -> M
	store_article = |m, r, res| if (ConduitApp.article_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, article: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_article) } })

	store_comments : M, LoadReq, Engine.Res -> M
	store_comments = |m, r, res| if (ConduitApp.comments_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, comments: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_comments) } })

	store_profile : M, LoadReq, Engine.Res -> M
	store_profile = |m, r, res| if (ConduitApp.profile_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, profile: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_profile) } })

	store_articles : M, LoadReq, Engine.Res -> M
	store_articles = |m, r, res| if (ConduitApp.articles_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, articles: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_feed) } })

	feed_remote : M -> Api.Remote(Api.FeedPage)
	feed_remote = |m| ConduitApp.remote(m.loads.feed, ConduitApp.feed_req(m).key)

	article_remote : M -> Api.Remote(Api.Article)
	article_remote = |m| ConduitApp.remote(m.loads.article, ConduitApp.article_req(m).key)

	edit_req : M -> LoadReq
	edit_req = |m| {
		slug = Route.article_slug(ConduitApp.route_of(m))
		if (slug.is_empty()) ConduitApp.no_req else { key: Api.article_uri(slug), uri: Api.article_uri(slug), token: "" }
	}

	store_edit : M, LoadReq, Engine.Res -> M
	store_edit = |m, r, res| if (ConduitApp.edit_req(m).key != r.key) m else ConduitApp.set_loads(m, |l| { ..l, article: { key: r.key, value: Api.decode_get(Api.response_of(res), Api.decode_article) } })

	## ------------------------------------------------------------------
	## Mutations.

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

	next : Submit, Str, Str, Str, Str -> Submit
	next = |prev, method, url, body, token| { serial: prev.serial + 1, method, url, body, token }

	submit_site : State(C, M), (M -> Submit), (M, Submit, Engine.Res -> M) -> Elem(C)
	submit_site = |st, sub_of, react| Engine.watch(st.val().map(sub_of), ConduitApp.plan_submit, st.on_result(react))

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

	classify_comment : Api.ResponseState -> CommentResult
	classify_comment = |response| {
		if !response.error.is_empty() {
			CommentErrored("Request failed: ${response.error}")
		} else if response.status == 200 or response.status == 201 {
			CommentAccepted
		} else if response.status == 422 {
			CommentRejected(Api.parse_errors(response.body))
		} else if response.status == 401 {
			CommentErrored("Please sign in to comment.")
		} else if response.status == 404 {
			CommentErrored("Article was not found.")
		} else {
			CommentErrored("The server responded with status ${response.status.to_str()}.")
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

	react_auth : M, Submit, Engine.Res -> M
	react_auth = |m, req, res| {
		if req.serial != m.auth.sub.serial {
			m
		} else {
			result = Api.classify_auth(Api.response_of(res))
			m1 = { ..m, auth: { ..m.auth, result } }
			match result {
				# Spec fidelity (login-422): the original navigated first and its
				# storage-backed session flipped in a later turn, so home mounted
				# anonymous (feed + tags) and then re-requested the feed with the
				# token. The session is applied by a root follow-up turn.
				AuthAccepted(user) => ConduitApp.navigate({ ..m1, incoming: SignedIn({ token: user.token, username: user.username }) }, ConduitApp.home_url)
				_ => m1
			}
		}
	}

	update_body : SettingsForm -> Str
	update_body = |form| Json.to_str({ user: { image: form.image, bio: form.bio, email: form.email, password: form.password } })

	submit_settings : M -> M
	submit_settings = |m| {
		s = m.settings
		{ ..m, settings: { ..s, sub: ConduitApp.next(s.sub, "PUT", "/api/user", ConduitApp.update_body(s), ConduitApp.token_of(m.session)) } }
	}

	react_settings : M, Submit, Engine.Res -> M
	react_settings = |m, req, res| if (req.serial != m.settings.sub.serial) m else { ..m, settings: { ..m.settings, result: Api.classify_auth(Api.response_of(res)) } }

	parse_tags : Str -> List(Str)
	parse_tags = |raw| raw.split_on(",").map(|part| part.trim()).keep_if(|tag| !tag.is_empty())

	article_body : Str, Str, Str, List(Str) -> Str
	article_body = |title, description, body, tags| {
		encoded_tags = Str.join_with(tags.map(|tag| Json.to_str(tag)), ",")
		"{\"article\":{\"title\":${Json.to_str(title)},\"description\":${Json.to_str(description)},\"body\":${Json.to_str(body)},\"tagList\":[${encoded_tags}]}}"
	}

	submit_editor : M -> M
	submit_editor = |m| {
		e = m.editor
		body = ConduitApp.article_body(e.title.trim(), e.description.trim(), e.body, ConduitApp.parse_tags(e.tags))
		slug = Route.article_slug(ConduitApp.route_of(m))
		(method, url) = if (slug.is_empty()) ("POST", "/api/articles") else ("PUT", Api.article_uri(slug))
		{ ..m, editor: { ..e, sub: ConduitApp.next(e.sub, method, url, body, ConduitApp.token_of(m.session)) } }
	}

	react_editor : M, Submit, Engine.Res -> M
	react_editor = |m, req, res| {
		if req.serial != m.editor.sub.serial {
			m
		} else {
			result = ConduitApp.classify_article(Api.response_of(res))
			m1 = { ..m, editor: { ..m.editor, result } }
			match result {
				ArticleAccepted(article) => ConduitApp.navigate(m1, Route.to_url(Route.article_location(article.slug)))
				_ => m1
			}
		}
	}

	## Article page mutations.
	set_art : M, (ArticleModel -> ArticleModel) -> M
	set_art = |m, f| { ..m, art: f(m.art) }

	article_slug_of : M -> Str
	article_slug_of = |m| Route.article_slug(ConduitApp.route_of(m))

	favorite_article : M -> M
	favorite_article = |m| {
		slug = ConduitApp.article_slug_of(m)
		favorited = match ConduitApp.article_remote(m) {
			Ready(a) => a.favorited
			_ => False
		}
		method = if (favorited) "DELETE" else "POST"
		ConduitApp.set_art(m, |a| { ..a, fav: ConduitApp.next(a.fav, method, Api.favorite_uri(slug), "", ConduitApp.token_of(m.session)), fav_result: FavoriteIdle })
	}

	react_fav : M, Submit, Engine.Res -> M
	react_fav = |m, req, res| {
		if req.serial != m.art.fav.serial {
			m
		} else {
			result = ConduitApp.classify_favorite(Api.response_of(res), "The server returned an empty article response.")
			match result {
				FavoriteAccepted(_) => ConduitApp.set_art(m, |a| { ..a, fav_result: result, refetch_article: a.refetch_article + 1 })
				_ => ConduitApp.set_art(m, |a| { ..a, fav_result: result })
			}
		}
	}

	delete_article : M -> M
	delete_article = |m| ConduitApp.set_art(m, |a| { ..a, del: ConduitApp.next(a.del, "DELETE", Api.article_uri(ConduitApp.article_slug_of(m)), "", ConduitApp.token_of(m.session)), del_result: DeleteIdle })

	react_del : M, Submit, Engine.Res -> M
	react_del = |m, req, res| {
		if req.serial != m.art.del.serial {
			m
		} else {
			result = ConduitApp.classify_delete(Api.response_of(res), "article")
			m1 = ConduitApp.set_art(m, |a| { ..a, del_result: result })
			match result {
				DeleteAccepted => ConduitApp.navigate(m1, ConduitApp.home_url)
				_ => m1
			}
		}
	}

	comment_body_json : Str -> Str
	comment_body_json = |body| "{\"comment\":{\"body\":${Json.to_str(body)}}}"

	post_comment : M -> M
	post_comment = |m| ConduitApp.set_art(m, |a| { ..a, comment: ConduitApp.next(a.comment, "POST", Api.comments_uri(ConduitApp.article_slug_of(m)), ConduitApp.comment_body_json(a.comment_body.trim()), ConduitApp.token_of(m.session)), comment_result: CommentIdle })

	react_comment : M, Submit, Engine.Res -> M
	react_comment = |m, req, res| {
		if req.serial != m.art.comment.serial {
			m
		} else {
			result = ConduitApp.classify_comment(Api.response_of(res))
			match result {
				CommentAccepted => ConduitApp.set_art(m, |a| { ..a, comment_result: result, refetch_comments: a.refetch_comments + 1 })
				_ => ConduitApp.set_art(m, |a| { ..a, comment_result: result })
			}
		}
	}

	delete_comment : M, Str -> M
	delete_comment = |m, key| {
		id = U64.from_str(key) ?? 0
		ConduitApp.set_art(m, |a| { ..a, cdel: ConduitApp.next(a.cdel, "DELETE", Api.comment_uri(ConduitApp.article_slug_of(m), id), "", ConduitApp.token_of(m.session)), cdel_result: DeleteIdle })
	}

	react_cdel : M, Submit, Engine.Res -> M
	react_cdel = |m, req, res| {
		if req.serial != m.art.cdel.serial {
			m
		} else {
			result = ConduitApp.classify_delete(Api.response_of(res), "comment")
			match result {
				DeleteAccepted => ConduitApp.set_art(m, |a| { ..a, cdel_result: result, refetch_comments: a.refetch_comments + 1 })
				_ => ConduitApp.set_art(m, |a| { ..a, cdel_result: result })
			}
		}
	}

	## Profile follow.
	profile_remote : M -> Api.Remote(Api.Profile)
	profile_remote = |m| ConduitApp.remote(m.loads.profile, ConduitApp.profile_req(m).key)

	follow : M -> M
	follow = |m| match ConduitApp.profile_remote(m) {
		Ready(p) => {
			method = if (p.following) "DELETE" else "POST"
			{ ..m, prof: { ..m.prof, follow: ConduitApp.next(m.prof.follow, method, Api.follow_uri(p.username), "", ConduitApp.token_of(m.session)), follow_result: FollowIdle } }
		}
		_ => m
	}

	react_follow : M, Submit, Engine.Res -> M
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

	react_row_fav : FavState, Submit, Engine.Res -> FavState
	react_row_fav = |s, req, res| if (req.serial != s.req.serial) s else { ..s, result: ConduitApp.classify_favorite(Api.response_of(res), "The server response could not be read.") }

	## Pagination.
	PageItem : { key : Str, active : Bool }

	page_items : Api.Remote(Api.FeedPage), Route.Feed -> List(PageItem)
	page_items = |r, feed| match r {
		Ready(page) => {
			pages = Api.page_count(page.articles_count)
			if pages <= 1 {
				[]
			} else {
				var $items = []
				var $n = 1.U64
				while $n <= pages {
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

	comment_errors : CommentResult -> List(Str)
	comment_errors = |result| match result {
		CommentRejected(lines) => lines
		CommentErrored(message) => [message]
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

	link : State(ctx, M), Str, Str, Str -> Elem(ctx)
	link = |st, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr("href", url), Engine.on("click:prevent", st.update(|m| ConduitApp.navigate(m, url)))], [Engine.text(label)])

	link_c : State(ctx, M), Str, Val(ctx, Str), Str -> Elem(ctx)
	link_c = |st, label, cls, url| Engine.element("a", [Engine.class_v(cls), Engine.attr("href", url), Engine.on("click:prevent", st.update(|m| ConduitApp.navigate(m, url)))], [Engine.text(label)])

	link_v : State(ctx, M), Val(ctx, Str), Str, Val(ctx, Str) -> Elem(ctx)
	link_v = |st, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr_v("href", url), Engine.on("click:prevent", st.update_by(url, |m, u| ConduitApp.navigate(m, u)))], [Engine.text_v(label)])

	button : Str, Str, Engine.Handler(ctx) -> Elem(ctx)
	button = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text(label)])

	button_v : Val(ctx, Str), Str, Engine.Handler(ctx) -> Elem(ctx)
	button_v = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text_v(label)])

	input : Str, Str, Val(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	input = |name, kind, v, h| Engine.element("input", [Engine.attr("aria-label", name), Engine.attr("type", kind), Engine.class(Styles.field), Engine.attr_v("value", v), Engine.on("input", h)], [])

	textarea : Str, Val(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	textarea = |name, v, h| Engine.element("textarea", [Engine.attr("aria-label", name), Engine.class(Styles.field), Engine.attr_v("value", v), Engine.on("input", h)], [])

	heading : Str, Str -> Elem(ctx)
	heading = |t, cls| Engine.element("h1", [Engine.class(cls)], [Engine.text(t)])

	error_list : Val(ctx, List(Str)) -> Elem(ctx)
	error_list = |errors| Engine.element(
		"div",
		[],
		[
			Engine.when(
				errors.map(|l| !l.is_empty()),
				|| Engine.element("ul", [Engine.class(Styles.error_list)], [Engine.each(errors.map(ConduitApp.keyed_lines), |i| i.key, |row| Engine.element("li", [], [Engine.text_v(row.field(|i| i.text))]))]),
				|| Engine.text(""),
			),
		],
	)

	## ------------------------------------------------------------------
	## Markdown (generic in the context: rendered inside the article page).

	inline_view : Val(ctx, Str) -> Elem(ctx)
	inline_view = |src| Engine.element("span", [], [Engine.each(src.map(Markdown.inline_segments), |s| s.key, |seg| ConduitApp.md_segment(seg))])

	md_segment : RowRef(ctx, Markdown.Segment) -> Elem(Row(ctx, Markdown.Segment))
	md_segment = |seg| {
		text = seg.field(|s| s.text)
		href = seg.field(|s| s.href)
		Engine.element(
			"span",
			[],
			[
				Engine.switch(
					seg.field(|s| s.kind),
					[Strong, Code, Image, Link, Text],
					|k| match k {
						Strong => Engine.element("strong", [], [Engine.text_v(text)])
						Code => Engine.element("code", [Engine.class("rounded bg-zinc-100 px-1 font-mono")], [Engine.text_v(text)])
						Image => Engine.element("img", [Engine.attr_v("src", href), Engine.attr_v("alt", text)], [])
						Link => Engine.element("a", [Engine.attr_v("href", href)], [Engine.text_v(text)])
						Text => Engine.text_v(text)
					},
				),
			],
		)
	}

	keyed_children : List(Str) -> List({ key : Str, text : Str })
	keyed_children = |texts| {
		var $out = []
		var $i = 0.U64
		for t in texts {
			$out = $out.append({ key: "c:${$i.to_str()}", text: t })
			$i = $i + 1
		}
		$out
	}

	md_item : RowRef(ctx, Markdown.ListItem) -> Elem(Row(ctx, Markdown.ListItem))
	md_item = |item| Engine.element(
		"li",
		[],
		[
			ConduitApp.inline_view(item.field(|i| i.text)),
			Engine.when(
				item.field(|i| !i.children.is_empty()),
				|| Engine.element("ul", [], [Engine.each(item.field(|i| ConduitApp.keyed_children(i.children)), |c| c.key, |child| Engine.element("li", [], [ConduitApp.inline_view(child.field(|c| c.text))]))]),
				|| Engine.text(""),
			),
		],
	)

	md_block : RowRef(ctx, Markdown.Block) -> Elem(Row(ctx, Markdown.Block))
	md_block = |row| {
		text = row.field(|b| b.text)
		Engine.element(
			"div",
			[],
			[
				Engine.switch(
					row.field(|b| b.kind),
					[Heading, Quote, CodeBlock, ListBlock, Paragraph],
					|k| match k {
						Heading => Engine.element("h3", [], [Engine.text_v(text)])
						Quote => Engine.element("blockquote", [], [ConduitApp.inline_view(text)])
						CodeBlock => Engine.element("pre", [Engine.class("overflow-x-auto rounded-lg bg-zinc-900 p-4 font-mono text-sm text-zinc-100")], [Engine.element("code", [], [Engine.text_v(text)])])
						ListBlock => Engine.element("ul", [], [Engine.each(row.field(|b| b.items), |i| i.key, |item| ConduitApp.md_item(item))])
						Paragraph => Engine.element("p", [], [ConduitApp.inline_view(text)])
					},
				),
			],
		)
	}

	markdown : Val(ctx, Str) -> Elem(ctx)
	markdown = |src| Engine.element("div", [Engine.attr("data-conduit", "markdown"), Engine.class("conduit-prose my-10")], [Engine.each(src.map(Markdown.parse), |b| b.key, |row| ConduitApp.md_block(row))])

	## ------------------------------------------------------------------
	## Shared article list.

	tag_pill : State(ctx, M), RowRef(ctx, Str) -> Elem(Row(ctx, Str))
	tag_pill = |st, row| {
		key = row.key()
		Engine.element("a", [Engine.class("rounded-full border border-zinc-300 px-2.5 py-1 text-xs text-zinc-500 no-underline"), Engine.attr_v("href", key.map(ConduitApp.tag_url)), Engine.on("click:prevent", st.lift_row().update_by(key, |m, t| ConduitApp.navigate(m, ConduitApp.tag_url(t))))], [Engine.text_v(key)])
	}

	preview_body : State(In(Row(C, Api.ArticleSummary), FavState), M), Val(In(Row(C, Api.ArticleSummary), FavState), Api.ArticleSummary), State(In(Row(C, Api.ArticleSummary), FavState), FavState) -> Elem(In(Row(C, Api.ArticleSummary), FavState))
	preview_body = |st, art, fst| {
		shown = art.map2(fst.val(), |a, s| ConduitApp.row_state(a, s.result))
		mv = st.val()
		token = mv.map(|m| ConduitApp.token_of(m.session))
		author = art.map(|a| a.author.username)
		Engine.element(
			"div",
			[],
			[
				Engine.watch(fst.val().map(|s| s.req), ConduitApp.plan_submit, fst.on_result(ConduitApp.react_row_fav)),
				Html.div(
					"mb-3 flex flex-wrap items-center gap-2 text-sm text-zinc-500",
					[
						ConduitApp.link_v(st, author, "font-medium text-emerald-600", author.map(ConduitApp.profile_url)),
						Engine.text_v(art.map(|a| Format.display_date(a.created_at))),
					],
				),
				Engine.element(
					"a",
					[Engine.class("block text-2xl font-semibold tracking-normal text-zinc-900 no-underline"), Engine.attr_v("href", art.map(|a| ConduitApp.article_url(a.slug))), Engine.on("click:prevent", st.update_by(art.map(|a| a.slug), |m, slug| ConduitApp.navigate(m, ConduitApp.article_url(slug))))],
					[Engine.text_v(shown.map(|a| a.title))],
				),
				Html.p_v(shown.map(|a| a.description), [Engine.class("mt-2 leading-7 text-zinc-600")]),
				Html.div(
					"mt-4 flex flex-wrap items-center justify-between gap-3 text-sm text-zinc-500",
					[
						Engine.when(
							mv.map(|m| ConduitApp.is_signed_in(m.session)),
							|| ConduitApp.button_v(
								shown.map(ConduitApp.favorite_button_label),
								"rounded-full border border-emerald-500 bg-white px-3 py-1.5 font-medium text-emerald-700",
								fst.update_by(shown.map2(token, |a, t| (a, t)), |s, (a, t)| { ..s, req: ConduitApp.next(s.req, if (a.favorited) "DELETE" else "POST", Api.favorite_uri(a.slug), "", t) }),
							),
							|| Engine.text_v(shown.map(|a| "${a.favorites_count.to_str()} favorites")),
						),
						Engine.element("div", [Engine.class("flex gap-1")], [Engine.each(art.map(|a| a.tag_list), |t| t, |row| ConduitApp.tag_pill(st, row))]),
					],
				),
				Html.p_v(
					fst.val().map(
						|s| match s.result {
							FavoriteRejected(message) => message
							_ => ""
						},
					),
					[Engine.class("mt-3 text-sm text-red-700")],
				),
			],
		)
	}

	preview_row : State(C, M), RowRef(C, Api.ArticleSummary) -> Elem(Row(C, Api.ArticleSummary))
	preview_row = |st, row| {
		art = row.field(|a| a)
		Engine.element(
			"article",
			[Engine.class("border-b border-zinc-200 bg-white py-6 first:border-t")],
			[Engine.state({ req: ConduitApp.no_submit, result: FavoriteIdle }, |fst| ConduitApp.preview_body(st.lift_row().lift(), art.lift(), fst))],
		)
	}

	feed_view : State(C, M), Val(C, Api.Remote(Api.FeedPage)) -> Elem(C)
	feed_view = |st, r| {
		articles = r.map(
			|v| match v {
				Ready(page) => page.articles
				_ => []
			},
		)
		Engine.element(
			"div",
			[Engine.attr("data-conduit", "article-list")],
			[
				Engine.when(
					r.map(ConduitApp.is_loading),
					|| Html.p("Loading articles...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
					|| Engine.when(
						r.map(ConduitApp.is_failed),
						|| Html.p_v(r.map(ConduitApp.failure), [Engine.class(Styles.status_error)]),
						|| Engine.when(
							articles.map(|l| l.is_empty()),
							|| Html.p("No articles are here... yet.", "rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-zinc-500"),
							|| Engine.element("div", [], [Engine.each(articles, |a| a.slug, |row| ConduitApp.preview_row(st, row))]),
						),
					),
				),
			],
		)
	}

	pagination : State(C, M) -> Elem(C)
	pagination = |st| {
		items = st.val().map(|m| ConduitApp.page_items(ConduitApp.feed_remote(m), Route.feed_of(ConduitApp.route_of(m))))
		Engine.element(
			"nav",
			[Engine.attr("aria-label", "Pagination"), Engine.class("flex flex-wrap gap-2 py-6")],
			[
				Engine.each(
					items,
					|i| i.key,
					|row| {
						key = row.key()
						cls = row.field(|i| if (i.active) "rounded-lg bg-emerald-600 px-3 py-2 text-sm font-medium text-white no-underline" else "rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-600 no-underline")
						Engine.element("a", [Engine.class_v(cls), Engine.attr_v("href", key.map(ConduitApp.key_url)), Engine.on("click:prevent", st.lift_row().update_by(key, |m, k| ConduitApp.navigate(m, ConduitApp.key_url(k))))], [Engine.text_v(key.map(ConduitApp.page_label))])
					},
				),
			],
		)
	}

	## ------------------------------------------------------------------
	## Pages.

	home_page : State(C, M) -> Elem(C)
	home_page = |st| {
		mv = st.val()
		feed = mv.map(|m| Route.feed_of(ConduitApp.route_of(m)))
		signed_in = mv.map(|m| ConduitApp.is_signed_in(m.session))
		tags = mv.map(|m| ConduitApp.remote(m.loads.tags, "tags"))
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline"
		idle = "px-4 py-3 text-zinc-500 no-underline"
		Html.section(
			"Home",
			"pb-12",
			[
				ConduitApp.load_site(st, ConduitApp.feed_req, ConduitApp.store_feed),
				ConduitApp.load_site(st, ConduitApp.tags_req, ConduitApp.store_tags),
				Html.div(
					"bg-emerald-700 px-5 py-12 text-center text-white shadow-inner sm:py-16",
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
											|| ConduitApp.link_c(st, "Your Feed", feed.map(|f| if (f.source == Yours) active else idle), Route.to_url(Route.feed_location({ page: 1, tag: AllTags, source: Yours }))),
											|| Engine.text(""),
										),
										ConduitApp.link_c(st, "Global Feed", feed.map(|f| if (f.source == Global and f.tag == AllTags) active else idle), ConduitApp.home_url),
									],
								),
								Html.p_v(
									feed.map(
										|f| match f.source {
											Yours => "Your Feed"
											Global => match f.tag {
												Tagged(tag) => "Tag: ${tag}"
												AllTags => "Global Feed"
											}
										},
									),
									[Engine.class("font-medium text-emerald-700")],
								),
								ConduitApp.feed_view(st, mv.map(ConduitApp.feed_remote)),
								ConduitApp.pagination(st),
							],
						),
						Engine.element(
							"aside",
							[Engine.class("h-fit rounded-xl border border-zinc-200 bg-zinc-100 p-5")],
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
													|row| ConduitApp.tag_pill(st, row),
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

	auth_page : State(C, M), Bool -> Elem(C)
	auth_page = |st, is_register| {
		af = st.val().map(|m| m.auth)
		title = if (is_register) "Sign up" else "Sign in"
		Html.section(
			title,
			Styles.narrow_page,
			[
				ConduitApp.submit_site(st, |m| m.auth.sub, ConduitApp.react_auth),
				ConduitApp.heading(title, "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Html.div(
					"mb-7 mt-2 text-center",
					[
						if is_register {
							ConduitApp.link(st, "Have an account?", "font-medium text-emerald-700", Route.to_url(Route.login_location))
						} else {
							ConduitApp.link(st, "Need an account?", "font-medium text-emerald-700", Route.to_url(Route.register_location))
						},
					],
				),
				ConduitApp.error_list(af.map(|a| ConduitApp.auth_errors(a.result))),
				Engine.element(
					"form",
					[Engine.class(Styles.form)],
					[
						if is_register {
							ConduitApp.input("Username", "text", af.map(|a| a.username), st.set_value(|m, v| { ..m, auth: { ..m.auth, username: v } }))
						} else {
							Engine.text("")
						},
						ConduitApp.input("Email", "email", af.map(|a| a.email), st.set_value(|m, v| { ..m, auth: { ..m.auth, email: v } })),
						ConduitApp.input("Password", "password", af.map(|a| a.password), st.set_value(|m, v| { ..m, auth: { ..m.auth, password: v } })),
						ConduitApp.button(title, Styles.primary_button, st.update(|m| ConduitApp.submit_auth(m, is_register))),
					],
				),
			],
		)
	}

	settings_page : State(C, M) -> Elem(C)
	settings_page = |st| {
		mv = st.val()
		sf = mv.map(|m| m.settings)
		Html.section(
			"Settings",
			Styles.narrow_page,
			[
				ConduitApp.submit_site(st, |m| m.settings.sub, ConduitApp.react_settings),
				ConduitApp.heading("Settings", "text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Html.p_v(mv.map(|m| "Signed in as ${ConduitApp.username_of(m.session)}"), [Engine.class("mb-7 mt-2 text-center text-sm text-zinc-500")]),
				ConduitApp.error_list(sf.map(|s| ConduitApp.auth_errors(s.result))),
				Html.p_v(
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
						ConduitApp.input("Profile picture URL", "text", sf.map(|s| s.image), st.set_value(|m, v| { ..m, settings: { ..m.settings, image: v } })),
						ConduitApp.textarea("Bio", sf.map(|s| s.bio), st.set_value(|m, v| { ..m, settings: { ..m.settings, bio: v } })),
						ConduitApp.input("Email", "email", sf.map(|s| s.email), st.set_value(|m, v| { ..m, settings: { ..m.settings, email: v } })),
						ConduitApp.input("New password", "password", sf.map(|s| s.password), st.set_value(|m, v| { ..m, settings: { ..m.settings, password: v } })),
						ConduitApp.button("Update Settings", Styles.primary_button, st.update(ConduitApp.submit_settings)),
					],
				),
				ConduitApp.button("Sign out", "mt-8 ${Styles.danger_button}", st.update(|m| { ..m, session: Anonymous })),
			],
		)
	}

	editor_form : State(C, M), Str -> Elem(C)
	editor_form = |st, label| {
		ef = st.val().map(|m| m.editor)
		Engine.element(
			"form",
			[Engine.class(Styles.form)],
			[
				ConduitApp.input("Title", "text", ef.map(|e| e.title), st.set_value(|m, v| { ..m, editor: { ..m.editor, title: v } })),
				ConduitApp.input("Description", "text", ef.map(|e| e.description), st.set_value(|m, v| { ..m, editor: { ..m.editor, description: v } })),
				ConduitApp.textarea("Body", ef.map(|e| e.body), st.set_value(|m, v| { ..m, editor: { ..m.editor, body: v } })),
				ConduitApp.input("Tags", "text", ef.map(|e| e.tags), st.set_value(|m, v| { ..m, editor: { ..m.editor, tags: v } })),
				ConduitApp.button(label, Styles.primary_button, st.update(ConduitApp.submit_editor)),
			],
		)
	}

	editor_new_page : State(C, M) -> Elem(C)
	editor_new_page = |st| Html.section(
		"New article",
		Styles.wide_page,
		[
			ConduitApp.submit_site(st, |m| m.editor.sub, ConduitApp.react_editor),
			ConduitApp.heading("New article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
			ConduitApp.error_list(st.val().map(|m| ConduitApp.article_errors(m.editor.result))),
			ConduitApp.editor_form(st, "Publish Article"),
		],
	)

	editor_edit_page : State(C, M) -> Elem(C)
	editor_edit_page = |st| {
		mv = st.val()
		article = mv.map(|m| ConduitApp.remote(m.loads.article, ConduitApp.edit_req(m).key))
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
				ConduitApp.load_site(st, ConduitApp.edit_req, ConduitApp.store_edit),
				ConduitApp.submit_site(st, |m| m.editor.sub, ConduitApp.react_editor),
				ConduitApp.heading("Edit article", "mb-8 text-center text-4xl font-semibold tracking-normal text-zinc-950"),
				Engine.when(
					article.map(ConduitApp.is_loading),
					|| Html.p("Loading article...", ""),
					|| Engine.when(
						article.map(ConduitApp.is_failed),
						|| Html.p_v(article.map(ConduitApp.failure), [Engine.class("text-red-700")]),
						|| Html.div(
							"mb-4 space-y-1 rounded border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-700",
							[
								Html.p_v(current(|a| "Current title: ${a.title}"), []),
								Html.p_v(current(|a| "Current description: ${a.description}"), []),
								Html.p_v(current(|a| "Current body: ${a.body}"), []),
								Html.p_v(current(|a| "Current tags: ${Str.join_with(a.tag_list, ", ")}"), []),
							],
						),
					),
				),
				ConduitApp.error_list(mv.map(|m| ConduitApp.article_errors(m.editor.result))),
				ConduitApp.editor_form(st, "Update Article"),
			],
		)
	}

	comment_row : State(C, M), RowRef(C, Api.Comment) -> Elem(Row(C, Api.Comment))
	comment_row = |st, row| {
		srow = st.lift_row()
		mine = row.field(|c| c.author.username).map2(srow.val(), |name, m| name == ConduitApp.username_of(m.session))
		Html.div(
			"my-4 overflow-hidden rounded-xl border border-zinc-200 bg-white p-4",
			[
				Html.p_v(row.field(|c| c.body), []),
				Html.p_v(row.field(|c| "${c.author.username} on ${Format.display_date(c.created_at)}"), [Engine.class("text-sm text-zinc-500")]),
				Engine.when(
					mine,
					|| ConduitApp.button("Delete Comment", "mt-3 ${Styles.danger_button}", srow.update_by(row.key(), ConduitApp.delete_comment)),
					|| Engine.text(""),
				),
			],
		)
	}

	comments_section : State(C, M) -> Elem(C)
	comments_section = |st| {
		mv = st.val()
		comments = mv.map(|m| ConduitApp.remote(m.loads.comments, ConduitApp.comments_req(m).key))
		Html.div(
			"mt-10 border-t border-zinc-200 pt-8",
			[
				Engine.element("h3", [Engine.class("mb-5 text-2xl font-semibold tracking-normal text-zinc-950")], [Engine.text("Comments")]),
				Engine.when(
					mv.map(|m| ConduitApp.is_signed_in(m.session)),
					|| Engine.element(
						"form",
						[Engine.class("mb-8 grid gap-3 rounded-xl border border-zinc-200 bg-zinc-50 p-4")],
						[
							ConduitApp.error_list(mv.map(|m| ConduitApp.comment_errors(m.art.comment_result))),
							ConduitApp.textarea("Comment", mv.map(|m| m.art.comment_body), st.set_value(|m, v| ConduitApp.set_art(m, |a| { ..a, comment_body: v }))),
							ConduitApp.button("Post Comment", Styles.primary_button, st.update(ConduitApp.post_comment)),
						],
					),
					|| Html.p("Sign in to add a comment.", ""),
				),
				Html.p_v(
					mv.map(
						|m| match m.art.cdel_result {
							DeleteRejected(message) => message
							_ => ""
						},
					),
					[Engine.class("text-red-700")],
				),
				Engine.when(
					comments.map(ConduitApp.is_loading),
					|| Html.p("Loading comments...", ""),
					|| Engine.when(
						comments.map(ConduitApp.is_failed),
						|| Html.p_v(comments.map(ConduitApp.failure), [Engine.class("text-red-700")]),
						|| Engine.element(
							"div",
							[],
							[
								Engine.each(
									comments.map(
										|r| match r {
											Ready(l) => l
											_ => []
										},
									),
									|c| c.id.to_str(),
									|row| ConduitApp.comment_row(st, row),
								),
							],
						),
					),
				),
			],
		)
	}

	article_page : State(C, M) -> Elem(C)
	article_page = |st| {
		mv = st.val()
		article = mv.map(ConduitApp.article_remote)
		field = |f| article.map(
			|r| match r {
				Ready(a) => f(a)
				_ => ""
			},
		)
		author = field(|a| a.author.username)
		Html.section(
			"Article",
			Styles.wide_page,
			[
				ConduitApp.load_site(st, ConduitApp.article_req, ConduitApp.store_article),
				ConduitApp.load_site(st, ConduitApp.comments_req, ConduitApp.store_comments),
				ConduitApp.submit_site(st, |m| m.art.del, ConduitApp.react_del),
				ConduitApp.submit_site(st, |m| m.art.comment, ConduitApp.react_comment),
				ConduitApp.submit_site(st, |m| m.art.cdel, ConduitApp.react_cdel),
				ConduitApp.submit_site(st, |m| m.art.fav, ConduitApp.react_fav),
				Engine.when(
					article.map(ConduitApp.is_loading),
					|| Html.p("Loading article...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
					|| Engine.when(
						article.map(ConduitApp.is_failed),
						|| Html.p_v(article.map(ConduitApp.failure), [Engine.class(Styles.status_error)]),
						|| Engine.element(
							"div",
							[Engine.attr("data-conduit", "article"), Engine.class("rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm sm:p-10")],
							[
								Engine.element("h2", [Engine.class("text-4xl font-semibold leading-tight tracking-normal text-zinc-950 sm:text-5xl")], [Engine.text_v(field(|a| a.title))]),
								Html.div(
									"flex flex-wrap items-center gap-2 py-4 text-sm text-zinc-500",
									[
										ConduitApp.link_v(st, author, "font-medium text-emerald-600", author.map(ConduitApp.profile_url)),
										Engine.text_v(field(|a| "${Format.display_date(a.created_at)} | ${a.favorites_count.to_str()} favorites")),
									],
								),
								Engine.when(
									mv.map(|m| ConduitApp.is_signed_in(m.session)),
									|| ConduitApp.button_v(
										article.map(
											|r| match r {
												Ready(a) => if (a.favorited) "Unfavorite Article (${a.favorites_count.to_str()})" else "Favorite Article (${a.favorites_count.to_str()})"
												_ => "Favorite Article"
											},
										),
										"mb-4 mr-2 rounded-lg border border-emerald-500 bg-white px-4 py-2 text-sm font-medium text-emerald-700",
										st.update(ConduitApp.favorite_article),
									),
									|| Engine.text(""),
								),
								Html.p_v(
									mv.map(
										|m| match m.art.fav_result {
											FavoriteRejected(message) => message
											_ => ""
										},
									),
									[Engine.class("text-red-700")],
								),
								Engine.when(
									mv.map(
										|m| match ConduitApp.article_remote(m) {
											Ready(a) => a.author.username == ConduitApp.username_of(m.session)
											_ => False
										},
									),
									|| ConduitApp.button("Delete Article", "mb-4 ${Styles.danger_button}", st.update(ConduitApp.delete_article)),
									|| Engine.text(""),
								),
								Html.p_v(
									mv.map(
										|m| match m.art.del_result {
											DeleteRejected(message) => message
											_ => ""
										},
									),
									[Engine.class("text-red-700")],
								),
								ConduitApp.markdown(field(|a| a.body)),
								ConduitApp.comments_section(st),
							],
						),
					),
				),
			],
		)
	}

	profile_page : State(C, M), Bool -> Elem(C)
	profile_page = |st, favorites| {
		mv = st.val()
		profile = mv.map(ConduitApp.profile_remote)
		field = |f| profile.map(
			|r| match r {
				Ready(p) => f(p)
				_ => ""
			},
		)
		username = mv.map(|m| Route.profile_username(ConduitApp.route_of(m)))
		active = "border-b-2 border-emerald-600 px-4 py-3 font-medium text-emerald-700 no-underline"
		idle = "px-4 py-3 text-zinc-500 no-underline"
		Html.section(
			"Profile",
			Styles.page,
			[
				ConduitApp.load_site(st, ConduitApp.profile_req, ConduitApp.store_profile),
				ConduitApp.load_site(st, ConduitApp.articles_req, ConduitApp.store_articles),
				ConduitApp.submit_site(st, |m| m.prof.follow, ConduitApp.react_follow),
				Engine.when(
					profile.map(ConduitApp.is_loading),
					|| Html.p("Loading profile...", "rounded-xl border border-zinc-200 bg-white p-6 text-zinc-500"),
					|| Engine.when(
						profile.map(ConduitApp.is_failed),
						|| Html.p_v(profile.map(ConduitApp.failure), [Engine.class(Styles.status_error)]),
						|| Engine.element(
							"div",
							[Engine.attr("data-conduit", "profile"), Engine.class("mb-8 rounded-2xl border border-zinc-200 bg-white p-6 text-center shadow-sm sm:p-8")],
							[
								Engine.element("h2", [Engine.class("text-3xl font-semibold tracking-normal text-zinc-950")], [Engine.text_v(field(|p| "@${p.username}"))]),
								Html.p_v(field(|p| p.bio), [Engine.class("mx-auto mt-2 max-w-2xl leading-7 text-zinc-600")]),
								Engine.when(
									mv.map(
										|m| match ConduitApp.profile_remote(m) {
											Ready(p) => ConduitApp.is_signed_in(m.session) and p.username != ConduitApp.username_of(m.session)
											_ => False
										},
									),
									|| ConduitApp.button_v(
										profile.map(
											|r| match r {
												Ready(p) => if (p.following) "Unfollow ${p.username}" else "Follow ${p.username}"
												_ => "Follow"
											},
										),
										"mt-4 rounded-lg border border-emerald-500 bg-white px-4 py-2 text-sm font-medium text-emerald-700",
										st.update(ConduitApp.follow),
									),
									|| Engine.text(""),
								),
								Html.p_v(
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
								ConduitApp.link_v(st, Engine.const("My Articles"), if (favorites) idle else active, username.map(ConduitApp.profile_url)),
								ConduitApp.link_v(st, Engine.const("Favorited Articles"), if (favorites) active else idle, username.map(|u| Route.to_url(Route.profile_favorites_location(u)))),
							],
						),
					],
				),
				ConduitApp.feed_view(st, mv.map(|m| ConduitApp.remote(m.loads.articles, ConduitApp.articles_req(m).key))),
			],
		)
	}

	not_found_page : State(C, M) -> Elem(C)
	not_found_page = |st| Html.section(
		"Page not found",
		Styles.page,
		[
			ConduitApp.heading("Page not found", Styles.heading),
			Html.p("This address does not match any conduit page.", "mt-3 text-zinc-600"),
			Html.div("mt-6", [ConduitApp.link(st, "Take me home", Styles.secondary_button, ConduitApp.home_url)]),
		],
	)

	page : State(C, M), Route.Kind -> Elem(C)
	page = |st, kind| match kind {
		Home => ConduitApp.home_page(st)
		Login => ConduitApp.auth_page(st, False)
		Register => ConduitApp.auth_page(st, True)
		Settings => ConduitApp.settings_page(st)
		EditorNew => ConduitApp.editor_new_page(st)
		EditorEdit => ConduitApp.editor_edit_page(st)
		Article => ConduitApp.article_page(st)
		Profile => ConduitApp.profile_page(st, False)
		ProfileFavorites => ConduitApp.profile_page(st, True)
		NotFound => ConduitApp.not_found_page(st)
	}

	header : State(C, M) -> Elem(C)
	header = |st| {
		mv = st.val()
		item = "rounded-md px-3 py-2 text-zinc-600 no-underline hover:bg-zinc-100 hover:no-underline"
		username = mv.map(|m| ConduitApp.username_of(m.session))
		Engine.element(
			"header",
			[Engine.class(Styles.header)],
			[
				ConduitApp.link(st, "conduit", "text-2xl font-bold tracking-normal text-emerald-600 no-underline", ConduitApp.home_url),
				Engine.element(
					"nav",
					[Engine.attr("aria-label", "Site"), Engine.class("flex flex-wrap items-center text-sm font-medium")],
					[
						ConduitApp.link(st, "Home", item, ConduitApp.home_url),
						Engine.when(
							mv.map(|m| ConduitApp.is_signed_in(m.session)),
							|| Html.div(
								"inline-flex",
								[
									ConduitApp.link(st, "New Article", item, Route.to_url(Route.location_for("/editor", ""))),
									ConduitApp.link(st, "Settings", item, Route.to_url(Route.location_for("/settings", ""))),
									ConduitApp.link_v(st, username, "rounded-md px-3 py-2 text-emerald-700 no-underline", username.map(ConduitApp.profile_url)),
								],
							),
							|| Html.div(
								"inline-flex",
								[
									ConduitApp.link(st, "Sign in", item, Route.to_url(Route.login_location)),
									ConduitApp.link(st, "Sign up", item, Route.to_url(Route.register_location)),
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

	storage_plan : Session -> List(Engine.Req)
	storage_plan = |s| match s {
		SignedIn(u) => [StorageSet(ConduitApp.jwt_key, u.token), StorageSet(ConduitApp.username_key, u.username)]
		Anonymous => [StorageRemove(ConduitApp.jwt_key), StorageRemove(ConduitApp.username_key)]
	}

	view : State(C, M) -> Elem(C)
	view = |st| {
		mv = st.val()
		Html.div(
			Styles.shell,
			[
				## Root effects: popstate, history push, guard redirect, title, session storage.
				Engine.watch(
					Engine.const(0.U8),
					|_| [Popstate],
					st.on_result(
						|m, _, r| match r {
							Location(url) => ConduitApp.set_loc(m, url)
							_ => m
						},
					),
				),
				Engine.on_post(mv.map(|m| m.nav), |url| [Push(url)], Engine.ignore({})),
				Engine.watch(mv.map(ConduitApp.guard_url), |u| if (u.is_empty()) [] else [Replace(u), Self], st.on_result(|m, u, _| if (!u.is_empty() and ConduitApp.guard_url(m) == u) ConduitApp.set_loc(m, u) else m)),
				Engine.watch(mv.map(ConduitApp.title_of), |t| [Title(t)], Engine.ignore({})),
				Engine.on_change(mv.map(|m| m.session), ConduitApp.storage_plan, Engine.ignore({})),
				Engine.on_change(
					mv.map(|m| m.incoming),
					|s| match s {
						SignedIn(_) => [Self]
						Anonymous => []
					},
					st.on_result(|m, s, _| { ..m, session: s, incoming: Anonymous }),
				),
				ConduitApp.header(st),
				Engine.element("main", [Engine.class(Styles.main)], [Engine.switch(mv.map(|m| Route.kind(ConduitApp.route_of(m))), ConduitApp.all_kinds, |k| ConduitApp.page(st, k))]),
				Engine.element(
					"footer",
					[Engine.class(Styles.footer)],
					[
						Engine.element("span", [Engine.class("font-semibold text-emerald-600")], [Engine.text("conduit")]),
						Engine.text(" - a RealWorld evidence app built on roc-signals."),
					],
				),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: ["conduit.jwt", "conduit.username"], max_inflight: 32 }, ConduitApp.main)

	main : Engine.Boot -> Elem(Root)
	main = |boot| Engine.state(ConduitApp.initial(boot), |st| ConduitApp.view(st))
}
