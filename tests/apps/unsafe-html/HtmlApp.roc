import pf.Engine exposing [Elem, Root]
import pf.Html
import pf.Web

HtmlApp := [].{

	## Imported HTML exercises the wrapper's ordinary properties and lifetime.
	initial : Str
	initial = "<h2>Imported heading</h2><table><tbody><tr><td>Imported cell</td></tr></tbody></table><a href='../raw' target='_blank' download><span data-testid='forged' __rn='999'>Imported link</span></a>"

	## The test app keeps content, checked destinations and row order independent.
	view_at : Str -> Elem(Root)
	view_at = |url| Engine.state(
		{ html: if (url == "/empty") "" else HtmlApp.initial, destination: "/valid", has_destination: True, clicks: "none", moves: 0.U64, rows: ["a", "b"], visible: True },
		|state| {
			reading = state.signal()
			clicked = state.set_value(|before, click| { ..before, clicks: Str.inspect(click) })
			Engine.element(
				"main",
				[Engine.on_document_key({ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("F8")])) }, state.update(|before| { ..before, moves: before.moves + 1 }))],
				[
					Html.p_s(reading.map(|before| before.moves.to_str()), [Engine.test_id("moves")]),
					Html.textarea("HTML source", reading.map(|before| before.html), [], state.set_value(|before, html| { ..before, html })),
					Html.button("Remove destination", [], state.update(|before| { ..before, has_destination: False })),
					Html.button("Restore destination", [], state.update(|before| { ..before, has_destination: True })),
					Html.button("Refuse again", [], state.update(|before| { ..before, destination: "javascript:alert(1)" })),
					Html.button("Equal HTML", [], state.update(|before| { ..before, html: HtmlApp.initial })),
					Html.button("Replace HTML", [], state.update(|before| { ..before, html: "<p>Replaced</p>" })),
					Html.button("Empty HTML", [], state.update(|before| { ..before, html: "" })),
					Html.button("Reverse rows", [], state.update(|before| { ..before, rows: if (before.rows == ["a", "b"]) ["b", "a"] else ["a", "b"] })),
					Html.button("Toggle HTML", [], state.update(|before| { ..before, visible: !before.visible })),
					Html.text_input("Destination", Text, reading.map(|before| before.destination), [], state.set_value(|before, text| { ..before, destination: text })),
					Engine.element(
						"a",
						[
							Engine.test_id("checked"),
							Html.href_s(
								reading.map(
									|before| if (!before.has_destination) Absent else match Web.Link.from_str(before.destination) {
										Ok(destination) => Present(destination)
										Err(UnsupportedScheme(_)) => Absent
									},
								),
							),
							Engine.on_click_with({ prevent: True }, clicked),
						],
						[Engine.element("span", [Engine.test_id("nested")], [Engine.text("Managed link")])],
					),
					Html.button("No link", [], clicked),
					Engine.element("output", [Engine.test_id("clicks")], [Engine.text_s(reading.map(|before| before.clicks))]),
					Engine.when(reading.map(|before| before.visible), || Html.unsafe_html("section", [Engine.test_id("opaque"), Html.aria_label("Imported"), Html.on_pointer_move_paced(state.update(|before| { ..before, moves: before.moves + 1 })), Engine.on_click_with({ prevent: True }, clicked)], reading.map(|before| before.html)), || Engine.text("")),
					Engine.each(reading.map(|before| before.rows), |key| key, |row| Html.unsafe_html("article", [Engine.test_id_s(row.key())], row.field(|key| "<b>${key}</b>"))),
				],
			)
		},
	)
}
