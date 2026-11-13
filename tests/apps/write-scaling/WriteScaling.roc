import pf.Engine
import pf.Html

## A bounded fixture whose sparse writes have no data-size-dependent work.
WriteScaling := [Rows].{

	## Heap strings make a copied table's per-row ownership cost observable.
	Row : { name : Str, detail : Str }
	store = Engine.store(Rows, { rows: Engine.table([]), count: Engine.cell(0.U64) }.Engine.Cells)
	cells = store.cells()

	## Construct a whole replacement only when the explicit fill button asks.
	rows : U64 -> List({ key : U64, row : Row })
	rows = |count| (0.U64..<count).iter().map(|key| { key, row: { name: "a long row name ${key.to_str()}", detail: "a long unchanged detail ${key.to_str()}" } }).fold([], |out, row| out.append(row))

	## Sparse rename keeps ordering and the ten-row window unchanged.
	view : {} -> Engine.Elem(Engine.StoreRoot(_))
	view = |_| Engine.element(
		"div",
		[],
		[
			Html.button("Fill 1000", [], Engine.does([cells.rows.update(|table| table.load(rows(1000)))])),
			Html.button("Fill 10000", [], Engine.does([cells.rows.update(|table| table.load(rows(10000)))])),
			Html.button("Rename", [], Engine.does([cells.rows.update(|table| table.update(7, |row| { ..row, name: "${row.name}!" }))])),
			Html.button("Count", [], Engine.does([cells.count.update(|count| count + 1)])),
			Html.p_s(cells.count.signal().map(|count| "Count ${count.to_str()}"), []),
			Engine.table_view(
				cells.rows,
				{
					query: Engine.const({}),
					plan: |_| {
						keep: |_, _| True,
						sort: |key, _| key,
						compare: |a, b| if a < b {
							Before
						} else if a == b {
							Same
						} else {
							After
						},
					},
					window: Engine.const({ start: 0, count: 10 }),
				},
				|_, row| Html.p_s(row.signal().map(|value| value.name), []),
			),
		],
	)

	## The store starts empty; filling is an ordinary whole-table write.
	program : Engine.Program
	program = Engine.program_store({}, |_| store, |_| view({}))
}
