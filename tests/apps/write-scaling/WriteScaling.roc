import pf.Engine
import pf.Html

## A bounded fixture whose sparse writes have no data-size-dependent work:
## a keyed write of a table, a write of one element of a list held in a
## store cell and of one held in local state, and a small write beside them.
WriteScaling := [Rows].{

	## Heap strings make a copied table's per-row ownership cost observable.
	Row : { name : Str, detail : Str }
	store = Engine.store(Rows, { rows: Engine.table(Engine.Table.empty({})), count: Engine.cell(0.U64), values: Engine.cell([]) }.Engine.Cells)
	cells = store.cells()

	## Construct a whole replacement only when the explicit fill button asks.
	rows : U64 -> List({ key : U64, row : Row })
	rows = |count| (0.U64..<count).iter().map(|key| { key, row: { name: "a long row name ${key.to_str()}", detail: "a long unchanged detail ${key.to_str()}" } }).fold([], |out, row| out.append(row))

	## A whole replacement of `count` rows, built inside the modifier that
	## writes it so that no other holder keeps the table. Keys are the
	## numbers below `count`, so none repeats.
	filled : U64 -> Engine.Table(U64, Row)
	filled = |count| match Engine.Table.from_list(rows(count)) {
		Ok(table) => table
		Err(DuplicateKey(key)) => crash "WriteScaling.filled: the key ${key.to_str()} repeats"
	}

	## One element of a list, written in place: its slot 7 counts the bumps.
	## A list too short to have that slot (before a fill) is left as it is.
	bump : List(U64) -> List(U64)
	bump = |values| if values.len() <= 7 {
		values
	} else {
		values.update(7, |value| value + 1) ?? crash "internal: a list longer than 7 has index 7"
	}

	## The element a list's reader draws; constant time at every length.
	shown : Str, List(U64) -> Str
	shown = |label, values| "${label} ${(values.get(7) ?? 0).to_str()}"

	## Sparse rename keeps ordering and the ten-row window unchanged.
	view : {} -> Engine.Elem(Engine.StoreRoot(_))
	view = |_| Engine.element(
		"div",
		[],
		[
			Html.button("Fill 1000", [], Engine.does([cells.rows.update(|_| filled(1000))])),
			Html.button("Fill 10000", [], Engine.does([cells.rows.update(|_| filled(10000))])),
			Html.button("Rename", [], Engine.does([cells.rows.update(|table| table.update(7, |row| { ..row, name: "${row.name}!" }))])),
			Html.button("Count", [], Engine.does([cells.count.update(|count| count + 1)])),
			Html.p_s(cells.count.signal().map(|count| "Count ${count.to_str()}"), []),
			Html.button("Values 1000", [], Engine.does([cells.values.set(List.repeat(0, 1000))])),
			Html.button("Values 10000", [], Engine.does([cells.values.set(List.repeat(0, 10000))])),
			Html.button("Bump value", [], Engine.does([cells.values.update(bump)])),
			Html.p_s(cells.values.signal().map(|values| shown("Value", values)), []),
			Engine.state(
				[],
				|local| Engine.element(
					"div",
					[],
					[
						Html.button("Local 1000", [], local.update(|_| List.repeat(0, 1000))),
						Html.button("Local 10000", [], local.update(|_| List.repeat(0, 10000))),
						Html.button("Bump local", [], local.update(bump)),
						Html.p_s(local.signal().map(|values| shown("Local", values)), []),
					],
				),
			),
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
