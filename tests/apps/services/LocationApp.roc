import pf.Engine exposing [Elem, Root]
import pf.Html

## A URL fixture that keeps the raw values an author wrote separate from
## locations received at boot and on history traversal. The browser, or the
## native oracle, performs serialization; this app has no URL encoder.
LocationApp := [].{
	view : Engine.Boot -> Elem(Root)
	view = |boot| Engine.state(
		{ location: boot.url, pushes: 0.U64, replacements: 0.U64, normalizes: 0.U64, empty_pushes: 0.U64, empty_replaces: 0.U64, blanks: 0.U64, empty_queries: 0.U64, empty_fragments: 0.U64, traversals: 0.U64 },
		|st| Html.div(
			"locations",
			[
				Html.p_s(st.signal().map(|s| s.location), [Engine.test_id("received-location")]),
				Html.p_s(st.signal().map(|s| s.replacements.to_str()), [Engine.test_id("url-replacements")]),
				Html.p_s(st.signal().map(|s| s.traversals.to_str()), [Engine.test_id("url-traversals")]),
				Engine.watch(
					Engine.const({}),
					|_| [Popstate],
					st.on_result(
						|s, _, result| match result {
							Location(location) => { ..s, location, traversals: s.traversals + 1 }
							_ => s
						},
					),
				),
				Html.button("Push raw URL", [], st.update(|s| { ..s, pushes: s.pushes + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.pushes), |_| [Push("?p=café au lait\"'`{}#p=\"<>`{}")], Engine.ignore({})),
				Html.button("Replace raw URL", [], st.update(|s| { ..s, replacements: s.replacements + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.replacements), |_| [Replace("#r=café au lait\"<>`{}'?#")], Engine.ignore({})),
				Html.button("Push preprocessed query", [], st.update(|s| { ..s, normalizes: s.normalizes + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.normalizes), |_| [Push("\u(0001) \t?clean=ca\tfé au\r lait\n#value=é\u(001f) ")], Engine.ignore({})),
				Html.link("Follow preprocessed relative path", " \u(0001)\t next ca\tfé?word=ça\r va\n#tag=é\u(001f) ", [Engine.attr("style", "display:block")]),
				Html.button("Push empty URL", [], st.update(|s| { ..s, empty_pushes: s.empty_pushes + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.empty_pushes), |_| [Push("")], Engine.ignore({})),
				Html.button("Replace empty URL", [], st.update(|s| { ..s, empty_replaces: s.empty_replaces + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.empty_replaces), |_| [Replace("")], Engine.ignore({})),
				Html.button("Push blank URL", [], st.update(|s| { ..s, blanks: s.blanks + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.blanks), |_| [Push(" \t\n\r ")], Engine.ignore({})),
				Html.button("Push empty query", [], st.update(|s| { ..s, empty_queries: s.empty_queries + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.empty_queries), |_| [Push("?")], Engine.ignore({})),
				Html.button("Push empty fragment", [], st.update(|s| { ..s, empty_fragments: s.empty_fragments + 1 })),
				Engine.watch_changes(st.signal().map(|s| s.empty_fragments), |_| [Push("#")], Engine.ignore({})),
				Html.link("Follow empty fragment", "#", [Engine.attr("style", "display:block")]),
				Html.link("Drop empty query", "/url-probe/query#link", [Engine.attr("style", "display:block")]),
				Html.link("Follow raw fragment", "#l=café au lait\"<>`{}'?#", [Engine.attr("style", "display:block")]),
				Html.link("Follow raw relative path", "next café?word=ça va'\"#tag=é \"`", [Engine.attr("style", "display:block")]),
			],
		),
	)
}
