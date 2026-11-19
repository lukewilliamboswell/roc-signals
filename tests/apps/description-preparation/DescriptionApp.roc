import pf.Engine exposing [Elem, Signal]
import pf.Html

## One prepared root whose live cells, local state and rows belong to each
## instance. Its initializer deliberately reads runtime boot data.
DescriptionApp := [Page].{
	store = Engine.store(Page, { stamp: Engine.cell(0.I64), score: Engine.cell(0.I64), shown: Engine.cell(True), rows: Engine.cell(["one", "two"]) }.Engine.Cells)
	cells = store.cells()

	program : Engine.Program
	program = Engine.program_store({}, |boot| store.with_initial(cells.stamp, boot.now_ms), |_boot| prepared_page)
}

## This value contains readers and handlers, never the values they will read.
prepared_page : Elem(Engine.StoreRoot(_))
prepared_page = Engine.element(
	"main",
	[],
	[
		Html.p_s(DescriptionApp.cells.stamp.signal().to_text_signal(), [Engine.test_id("stamp")]),
		Html.button("Score", [], Engine.does([DescriptionApp.cells.score.update(|n| n + 1)])),
		Html.button("Reverse", [], Engine.does([DescriptionApp.cells.rows.update(|rows| rows.fold([], |out, row| [row].concat(out)))])),
		Html.button("Toggle", [], Engine.does([DescriptionApp.cells.shown.update(Bool.not)])),
		Engine.when(DescriptionApp.cells.shown.signal(), || region({}), || Engine.text("")),
		Engine.each(
			DescriptionApp.cells.rows.signal(),
			|key| key,
			|row| Engine.element(
				"div",
				[],
				[
					Engine.state(
						0.I64,
						|clicks| Engine.element(
							"div",
							[],
							[
								Html.button_s(row.key().lift().map(|key| "Tap ${key}"), [], clicks.update(|n| n + 1)),
								Html.p_s(row.key().lift().map2(clicks.signal(), |key, count| "${key}:${count.to_str()}"), [Engine.test_id_s(row.key().lift().map(|key| "row-${key}"))]),
							],
						),
					),
				],
			),
		),
	],
)

## A fresh local count below a derived cell, and a derived local count beside
## the cell: both composed writes must settle before the shared reader runs.
region : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
region = |_args| Engine.element(
	"section",
	[Engine.test_id("region")],
	[
		Engine.derive(
			DescriptionApp.cells.score.signal().map(|n| n * 2),
			|score| Engine.state(
				0.I64,
				|local| Engine.element(
					"div",
					[],
					[
						Html.button("Cell above", [], local.update(|n| n + 1).also(Engine.does([DescriptionApp.cells.score.update(|n| n + 1)]))),
						Html.p_s(local.signal().map2(score.lift(), |count, doubled| "${count.to_str()}/${doubled.to_str()}"), [Engine.test_id("cell-above")]),
					],
				),
			),
		),
		Engine.state(
			0.I64,
			|local| Engine.derive(
				local.signal().map(|n| n * 2),
				|doubled| Engine.element(
					"div",
					[],
					[
						Html.button("Local above", [], local.lift().update(|n| n + 1).also(Engine.does([DescriptionApp.cells.score.update(|n| n + 1)]))),
						Html.p_s(doubled.map2(DescriptionApp.cells.score.signal(), |count, score| "${count.to_str()}/${score.to_str()}"), [Engine.test_id("local-above")]),
					],
				),
			),
		),
	],
)
