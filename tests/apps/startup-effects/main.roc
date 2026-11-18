app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html

store = Engine.store(Page, { shown: Engine.cell(True), http: Engine.cell(0.U64), timer: Engine.cell(0.U64) }.Engine.Cells)

cells = store.cells()

Store : Engine.Stored([Page], (Bool, (U64, U64)))

entries = Engine.entries({}, [{ path: "/", route: {} }])

main : Engine.Program
main = Engine.program_startup_store({ max_inflight: 2 }, entries, |_| store, |_| view({}))

view : {} -> Engine.Elem(Engine.StoreRoot(_))
view = |_| Html.div(
	"",
	[
		Html.button("Toggle", [], Engine.does([cells.shown.update(Bool.not)])),
		Html.button("Reset", [], Engine.does([cells.shown.set(True), cells.http.set(0), cells.timer.set(0)])),
		Html.p_s(cells.http.signal().to_text_signal(), [Engine.test_id("http")]),
		Html.p_s(cells.timer.signal().to_text_signal(), [Engine.test_id("timer")]),
		Engine.when(
			cells.shown.signal(),
			|| Html.placeholder({}, "<p data-testid=\"waiting\">Waiting</p>", || body({})),
			|| Engine.text(""),
		),
	],
)

body : {} -> Engine.Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
body = |_| Engine.element(
	"section",
	[Engine.test_id("body")],
	[
		Engine.text("Active"),
		Engine.watch(
			Engine.const({}),
			|_| [Engine.http({ url: "/kept" })],
			Engine.react(
				|_, result| match result {
					Ok(_) => [cells.http.update(|n| n + 1)]
					Err(_) => []
				},
			),
		),
		Engine.watch(
			Engine.const({}),
			|_| [Engine.timer(60000)],
			Engine.react(
				|_, result| match result {
					Ok(_) => [cells.timer.update(|n| n + 1)]
					Err(_) => []
				},
			),
		),
		Engine.cleanup("body"),
	],
)

mounted : U64
mounted = Engine.mounts(main)
