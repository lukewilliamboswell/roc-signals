import pf.Url
import pf.Engine
import Api
import Route
import Locations

## The pages' own state, one cell of the app's store (`AppStore`): every
## page's loads and forms but the article page's (`Article`). Where the
## reader is, who is signed in and the navigation in flight are cells of
## their own beside it.
##
## Store state never resets by itself: changing the route's kind resets
## these models, in `moved`, which every navigation applies.
Pages := [].{

	Loaded(a) : { key : Str, value : Api.Remote(a) }

	LoadReq : { key : Str, uri : Str, token : Str }

	## A mutation request snapshot; serial 0 = nothing submitted.
	Submit : { serial : U64, method : Engine.Method, url : Try(Str, Url.SegmentErr), body : Str, token : Str }

	Loads : {
		feed : Loaded(Api.FeedPage),
		tags : Loaded(List(Str)),
		article : Loaded(Api.Article),
		profile : Loaded(Api.Profile),
		articles : Loaded(Api.FeedPage),
	}

	ArticleResult : [ArticleIdle, ArticleAccepted(Api.Article), ArticleRejected(List(Str)), ArticleErrored(Str)]

	FollowResult : [FollowIdle, FollowAccepted(Api.Profile), FollowRejected(Str)]

	AuthForm : { username : Str, email : Str, password : Str, sub : Submit, result : Api.AuthResult }

	SettingsForm : { image : Str, bio : Str, email : Str, password : Str, sub : Submit, result : Api.AuthResult }

	EditorForm : { title : Str, description : Str, body : Str, tags : Str, sub : Submit, result : ArticleResult }

	ProfileModel : { follow : Submit, follow_result : FollowResult, refetch : U64 }

	Model : {
		loads : Loads,
		auth : AuthForm,
		settings : SettingsForm,
		editor : EditorForm,
		prof : ProfileModel,
	}

	no_submit : Submit
	no_submit = { serial: 0, method: "GET", url: Err(EmptySegment), body: "", token: "" }

	no_load : {} -> Loaded(a)
	no_load = |_| { key: "", value: Loading }

	empty_loads : Loads
	empty_loads = { feed: Pages.no_load({}), tags: Pages.no_load({}), article: Pages.no_load({}), profile: Pages.no_load({}), articles: Pages.no_load({}) }

	auth0 : AuthForm
	auth0 = { username: "", email: "", password: "", sub: Pages.no_submit, result: AuthIdle }

	settings0 : SettingsForm
	settings0 = { image: "", bio: "", email: "", password: "", sub: Pages.no_submit, result: AuthIdle }

	editor0 : EditorForm
	editor0 = { title: "", description: "", body: "", tags: "", sub: Pages.no_submit, result: ArticleIdle }

	prof0 : ProfileModel
	prof0 = { follow: Pages.no_submit, follow_result: FollowIdle, refetch: 0 }

	## The pages for a reader arriving at `loc`.
	init : Str -> Model
	init = |_| { loads: Pages.empty_loads, auth: Pages.auth0, settings: Pages.settings0, editor: Pages.editor0, prof: Pages.prof0 }

	## The pages after a move from `from` to `url`: the same kind of page
	## keeps its models; another kind starts every page again.
	moved : Model, Str, Str -> Model
	moved = |m, from, url| if (Route.kind(Locations.of_url(url)) == Route.kind(Locations.of_url(from))) m else Pages.init(url)
}

expect Pages.moved(Pages.init("/#/login"), "/#/login", "/#/register").auth == Pages.auth0
