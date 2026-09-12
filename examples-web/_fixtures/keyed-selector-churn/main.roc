app [main] { roc: "nightly-2026-09-11-793f9d8", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui

## Keyed benchmark row shape with two keyed selectors per row, a second each
## site sharing the same selected input and exact keys, and a Ui.when around
## the table so nested disposal retires every membership at once. The specs
## drive one-row structural churn at 1k and 10k rows and assert the selector
## index does work proportional to the changed rows only.
Row : { id : Str, label : Str }

Model : { rows : Rows(Row), pinned : Rows(Row), next_id : U64, selected : Str, hovered : Str, show_table : Bool }

row_key : Row -> Str
row_key = |row| row.id

make_rows : U64, U64 -> List(Row)
make_rows = |start, count| {
	var $rows = List.with_capacity(count)
	var $index = 0.U64
	while $index < count {
		id = start + $index
		$rows = $rows.append({ id: id.to_str(), label: "row ${id.to_str()}" })
		$index = $index + 1
	}
	$rows
}

create : Model, U64 -> Model
create = |model, count| {
	rows = Rows.replace_all(model.rows, make_rows(1, count)) ?? crash "fixture generated duplicate row keys"
	pinned = Rows.replace_all(model.pinned, make_rows(1, 3)) ?? crash "fixture generated duplicate pinned keys"
	{ ..model, rows, pinned, next_id: count + 1, selected: "", hovered: "" }
}

append_one : Model -> Model
append_one = |model| {
	rows = Rows.apply(model.rows, [Append(make_rows(model.next_id, 1))]) ?? crash "fixture appended a duplicate row key"
	{ ..model, rows, next_id: model.next_id + 1 }
}

remove_key : Model, Str -> Model
remove_key = |model, id| { ..model, rows: Rows.apply(model.rows, [RemoveKey(id)]) ?? model.rows }

## Moves the second row to the sixth position so its key changes place
## without changing identity.
move_second_row : Model -> Model
move_second_row = |model| {
	rows =
		if model.rows.len() < 6 {
			model.rows
		} else {
			Rows.apply(model.rows, [MoveRange({ from: 1, count: 1, to: 5 })]) ?? crash "fixture move was invalid"
		}
	{ ..model, rows }
}

render_row : Ui.State(Model), Signal.Keyed(Str), Signal.Keyed(Str), Ui.Row(Row) -> Elem
render_row = |model, selected_keyed, hovered_keyed, row| {
	key = row.key()
	classes = row.select(selected_keyed)
	hover = row.select(hovered_keyed)
	label = row.map(|value| value.label)
	Html.div(
		[Html.class_attr_s(classes), Html.attr_s("data-hover", hover), Html.test_id("row-${key}")],
		[
			Html.text_s(label),
			Html.button("Select row ${key}", model.update(|value| { ..value, selected: key })),
			Html.button("Remove row ${key}", model.update(|value| remove_key(value, key))),
		],
	)
}

render_pinned : Signal.Keyed(Str), Ui.Row(Row) -> Elem
render_pinned = |selected_keyed, row| {
	key = row.key()
	classes = row.select(selected_keyed)
	Html.div([Html.class_attr_s(classes), Html.test_id("pinned-${key}")], [Html.text_s(row.map(|value| value.label))])
}

main : () -> Elem
main = ||
	Ui.state(
		{ rows: Rows.empty(row_key), pinned: Rows.empty(row_key), next_id: 1.U64, selected: "", hovered: "", show_table: True },
		|model| {
			model_signal = model.signal()
			rows = Signal.map(model_signal, |value| value.rows)
			pinned = Signal.map(model_signal, |value| value.pinned)
			selected = Signal.map(model_signal, |value| value.selected)
			hovered = Signal.map(model_signal, |value| value.hovered)
			show_table = Signal.map(model_signal, |value| value.show_table)
			selected_keyed = selected.keyed("danger", "")
			hovered_keyed = hovered.keyed("hover", "")
			Html.section(
				"Keyed selector churn",
				[],
				[
					Html.heading("Keyed selector churn"),
					Html.button("Create 8 rows", model.update(|value| create(value, 8))),
					Html.button("Create 1,000 rows", model.update(|value| create(value, 1000))),
					Html.button("Create 10,000 rows", model.update(|value| create(value, 10000))),
					Html.button("Append one row", model.update(append_one)),
					Html.button("Move second row", model.update(move_second_row)),
					Html.button("Hover row 5", model.update(|value| { ..value, hovered: "5" })),
					Html.button("Choose key 2", model.update(|value| { ..value, selected: "2" })),
					Html.button("Choose key 3", model.update(|value| { ..value, selected: "3" })),
					Html.button("Toggle table", model.update(|value| { ..value, show_table: !value.show_table })),
					Html.div([Html.test_id("pinned")], [Ui.each(pinned, |row| render_pinned(selected_keyed, row))]),
					Ui.when(
						show_table,
						|| Html.div([Html.test_id("table")], [Ui.each(rows, |row| render_row(model, selected_keyed, hovered_keyed, row))]),
						|| Html.paragraph_s_attrs(Signal.const("Table hidden"), [Html.test_id("table-hidden")]),
					),
				],
			)
		},
	)
