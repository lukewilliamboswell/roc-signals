import pf.Engine exposing [Cell, Elem, Signal, State]
import pf.Html

## Store test app: a root store of 100 cells under a view ten local layers
## deep, with specs in `specs/` that pin which readers a write wakes.
##
## - The store is ten groups of ten cells. A group is a description a
##   feature module would export; the app nests the ten with the record
##   builder and writes no lens.
## - Ten nested `state` layers, each with a reader and a button of its
##   own. Below the tenth, every cell has a reader and a button, so a
##   cell is read and written ten layers down with no `lift`.
## - Cell 7 also has a reader at the root and one five layers down;
##   cell 50 is read in each row of an `each` ten layers down; one
##   button writes the tenth layer and cell 3 as one event.
##
## Cells are at signature bits 64 + i % 64, apart from every layer's, so
## a store of any size leaves the layers' precision as it was. Cells 64
## apart share a bit: a write of cell 7 also evaluates cell 71's reader,
## and equality pruning discards it.
StoreApp := [Hundred].{

	## Ten counters, as one description. Its handles are a list, the
	## shape this app wants.
	group : {} -> Engine.Cells(whole, _, List(Cell(whole, I64)))
	group = |{}| {
		a: Engine.cell(0),
		b: Engine.cell(0),
		c: Engine.cell(0),
		d: Engine.cell(0),
		e: Engine.cell(0),
		f: Engine.cell(0),
		g: Engine.cell(0),
		h: Engine.cell(0),
		i: Engine.cell(0),
		j: Engine.cell(0),
	}.Engine.Cells.map(|r| [r.a, r.b, r.c, r.d, r.e, r.f, r.g, r.h, r.i, r.j])

	store = Engine.store(
		StoreApp.Hundred,
		{
			g0: StoreApp.group({}),
			g1: StoreApp.group({}),
			g2: StoreApp.group({}),
			g3: StoreApp.group({}),
			g4: StoreApp.group({}),
			g5: StoreApp.group({}),
			g6: StoreApp.group({}),
			g7: StoreApp.group({}),
			g8: StoreApp.group({}),
			g9: StoreApp.group({}),
		}.Engine.Cells,
	)

	## The 100 cells, in order.
	cells = {
		cells = StoreApp.store.cells()
		cells.g0.concat(cells.g1).concat(cells.g2).concat(cells.g3).concat(cells.g4).concat(cells.g5).concat(cells.g6).concat(cells.g7).concat(cells.g8).concat(cells.g9)
	}

	## Cell `i`.
	at : U64 -> Cell(_, I64)
	at = |i| StoreApp.cells.get(i) ?? crash "no cell ${i.to_str()}"

	## A line naming a value, read by a reader with test id `name`.
	reader : Str, Signal(ctx, Str) -> Elem(ctx)
	reader = |name, v| Html.p_s(v.map(|s| "${name}=${s}"), [Engine.test_id(name)])

	button : Str, Engine.Handler(ctx) -> Elem(ctx)
	button = |label, h| Engine.element("button", [Engine.on_click(h)], [Engine.text(label)])

	## A reader and a button for one cell, in any scope.
	cell_view : Cell(st, I64), Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	cell_view = |c, name| Html.div(
		"",
		[
			StoreApp.reader(name, c.signal().map(|n| n.to_str())),
			StoreApp.button("Bump ${name}", Engine.handle(|_| [c.update(|n| n + 1)])),
		],
	)

	## A local layer named `name` with its own reader and button, around
	## what `inner` builds below it.
	layer : Str, (State(Engine.In(ctx, I64), I64) -> List(Elem(Engine.In(ctx, I64)))) -> Elem(ctx)
	layer = |name, inner| Engine.state(
		0,
		|s| Html.div(
			name,
			[
				StoreApp.reader(name, s.signal().map(|n| n.to_str())),
				StoreApp.button("Bump ${name}", s.update(|n| n + 1)),
			].concat(inner(s)),
		),
	)

	## Ten layers down: every cell, the rows reading cell 50, and one
	## button that writes the tenth layer and cell 3 as one event.
	bottom : State(ctx, I64) -> List(Elem(ctx))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	bottom = |s10| [
		StoreApp.button("Both", s10.update(|n| n + 1).also(Engine.handle(|_| [StoreApp.at(3).update(|n| n + 1)]))),
		Engine.element(
			"ul",
			[],
			[
				Engine.each(
					Engine.const(["r1", "r2", "r3", "r4", "r5"]),
					|k| k,
					|r| Engine.element("li", [], [StoreApp.reader_row(r.key().map2(StoreApp.at(50).signal(), |k, n| "${k}:${n.to_str()}"))]),
				),
			],
		),
		Html.div("cells", StoreApp.cells.map_with_index(|c, i| StoreApp.cell_view(c, "c${i.to_str()}"))),
	]

	reader_row : Signal(ctx, Str) -> Elem(ctx)
	reader_row = |v| Html.p_s(v, [Engine.test_id("row")])

	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div(
		"app",
		[
			StoreApp.reader("root-c7", StoreApp.at(7).signal().map(|n| n.to_str())),
			StoreApp.layer(
				"L1",
				|_| [
					StoreApp.layer(
						"L2",
						|_| [
							StoreApp.layer(
								"L3",
								|_| [
									StoreApp.layer(
										"L4",
										|_| [
											StoreApp.layer(
												"L5",
												|_| [
													StoreApp.reader("mid-c7", StoreApp.at(7).signal().map(|n| n.to_str())),
													StoreApp.layer(
														"L6",
														|_| [
															StoreApp.layer(
																"L7",
																|_| [
																	StoreApp.layer(
																		"L8",
																		|_| [
																			StoreApp.layer(
																				"L9",
																				|_| [StoreApp.layer("L10", |s10| StoreApp.bottom(s10))],
																			),
																		],
																	),
																],
															),
														],
													),
												],
											),
										],
									),
								],
							),
						],
					),
				],
			),
		],
	)

	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| StoreApp.store, |_| StoreApp.view({}))
}
