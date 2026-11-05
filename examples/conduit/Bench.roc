import pf.Engine
import ts.Dom
import ts.Scm
import ts.SpecRunner
import ConduitApp

## The Conduit bench scenario shared by fuzz-main (exact allocations) and
## the browser bench (conduit-bench.mjs): signed in as kim on the home page, answer
## tags (ordinal 2) and a feed of N articles (ordinal 1), favorite article
## N/2, answer that POST (ordinal 3), then click the "signals" tag link.
Bench := [].{
	article_json : U64, Bool, U64, Bool -> Str
	article_json = |i, favorited, count, with_body| {
		author = if (i % 2 == 0) "anna" else "max"
		body = if (with_body) "\"body\":\"\"," else ""
		fav = if (favorited) "true" else "false"
		"{\"slug\":\"article-${i.to_str()}\",\"title\":\"Article ${i.to_str()}\",\"description\":\"Description ${i.to_str()}.\",${body}\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":${fav},\"favoritesCount\":${count.to_str()},\"author\":{\"username\":\"${author}\",\"bio\":\"\",\"image\":\"https://example.test/a.png\",\"following\":false}}"
	}

	feed_json : U64 -> Str
	feed_json = |n| {
		var $parts = []
		var $i = 0.U64
		while $i < n {
			$parts = $parts.append(Bench.article_json($i, False, $i % 5, False))
			$i = $i + 1
		}
		"{\"articles\":[${Str.join_with($parts, ",")}],\"articlesCount\":${n.to_str()}}"
	}

	tags_json : Str
	tags_json = "{\"tags\":[\"signals\",\"roc\",\"webdev\"]}"

	url = "/roc-signals/examples-web/conduit/#/"

	storage : List({ key : Str, value : Str })
	storage = [{ key: "conduit.jwt", value: "jwt.conduit.kim" }, { key: "conduit.username", value: "kim" }]

	boot : Engine.Boot
	boot = { url: Bench.url, storage: Bench.storage.map(|{ key, value }| (key, value)), online: Bool.True, visible: Bool.True, storage_available: Bool.True }

	start_from : Engine.App, List(U8) -> SpecRunner.S(Engine.App)
	start_from = |a, c| SpecRunner.adopt(a, c, Bench.url, Bench.storage)

	## The engine id of spec ordinal n.
	id_of : SpecRunner.S(Engine.App), U64 -> U32
	id_of = |st, n| st.browser.issued.get(n - 1) ?? crash "bench: ordinal ${n.to_str()} not issued"

	## (node, handler) of the click target the locator finds.
	click_target : SpecRunner.S(Engine.App), Scm.Loc -> (U32, U32)
	click_target = |st, loc| {
		i = SpecRunner.find(st.dom, loc) ?? crash "bench: no ${Scm.show_loc(loc)}"
		Dom.target(st.dom, i, "click") ?? crash "bench: no click handler"
	}

	mid : U64 -> U64
	mid = |n| n // 2

	favorite_label : U64 -> Str
	favorite_label = |n| "Favorite Article ${Bench.mid(n).to_str()} (${(Bench.mid(n) % 5).to_str()})"

	favorite_response : U64 -> Str
	favorite_response = |n| "{\"article\":${Bench.article_json(Bench.mid(n), True, Bench.mid(n) % 5 + 1, True)}}"

	expect_visible : SpecRunner.S(Engine.App), Scm.Loc -> {}
	expect_visible = |st, loc| match SpecRunner.find(st.dom, loc) {
		Ok(_) => {}
		Err(_) => crash "bench: expected ${Scm.show_loc(loc)}"
	}
}
