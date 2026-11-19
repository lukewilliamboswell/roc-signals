app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html

store = Engine.store(Page, { count: Engine.cell(0.I64), ready: Engine.cell(False), shown: Engine.cell(True) }.Engine.Cells)

cells = store.cells()

entries = Engine.entries({}, [{ path: "/", route: "home" }, { path: "/about/", route: "about" }])

main : Engine.Program
main = Engine.program_startup_store({ max_inflight: 0 }, entries, |_| store, |route| page(route))

page : Str -> Engine.Elem(Engine.StoreRoot(_))
page = |route| Html.div(
	"",
	[
		Engine.element("p", [Engine.test_id("route")], [Engine.text(route)]),
		Html.button("Increment", [], Engine.does([cells.count.update(|n| n + 1)])),
		Html.button("Ready", [], Engine.does([cells.ready.set(True)])),
		Html.button("Wait", [], Engine.does([cells.ready.set(False)])),
		Html.button("Toggle region", [], Engine.does([cells.shown.update(Bool.not)])),
		Engine.when(
			cells.shown.signal(),
			|| Html.placeholder(
				{ ready: cells.ready.signal() },
				"<p data-testid=\"waiting\">Loading</p>",
				|| Engine.state(
					0.I64,
					|local| Html.div(
						"",
						[
							Html.p_s(cells.count.signal().map2(local.signal(), |count, taps| "${count.to_str()}/${taps.to_str()}"), [Engine.test_id("live")]),
							Html.button("Tap", [], local.update(|n| n + 1)),
							Html.placeholder({}, Html.Static.text("Nested waiting"), || Engine.element("p", [Engine.test_id("nested")], [Engine.text("Nested active")])),
						],
					),
				),
			),
			|| Engine.text(""),
		),
	],
)

mounted : U64
mounted = Engine.mounts(main)
