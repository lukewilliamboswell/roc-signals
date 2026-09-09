app [main] { roc: "nightly-2026-09-09-7dadc35", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui

## Size fixture: one keyed list with every supported `Rows` edit reachable
## through a button, plus snapshot replacement. An append-only fixture cannot
## show whether a host change covers the complete edit API.
Row : { id : Str, label : Str }

Model : { rows : Rows(Row), next_id : U64 }

row_key : Row -> Str
row_key = |row| row.id

fresh_row : U64 -> Row
fresh_row = |id| { id: id.to_str(), label: "Row ${id.to_str()}" }

initial_rows : List(Row)
initial_rows = [fresh_row(1), fresh_row(2), fresh_row(3)]

edit : Model, List(Rows.Edit(Row)) -> Model
edit = |model, edits| { ..model, rows: Rows.apply(model.rows, edits) ?? model.rows }

with_fresh : Model, (Row -> Rows.Edit(Row)) -> Model
with_fresh = |model, make| {
	row = fresh_row(model.next_id)
	{ ..edit(model, [make(row)]), next_id: model.next_id + 1 }
}

append : Model -> Model
append = |model| with_fresh(model, |row| Append([row]))

insert_first : Model -> Model
insert_first = |model| with_fresh(model, |row| InsertAt({ at: 0, items: [row] }))

insert_before_last : Model -> Model
insert_before_last = |model|
	match Rows.get(model.rows, model.rows.len() - 1) {
		Ok(last) => with_fresh(model, |row| InsertBefore({ before: last.id, items: [row] }))
		Err(_) => append(model)
	}

remove_first : Model -> Model
remove_first = |model| edit(model, [RemoveRange({ at: 0, count: 1 })])

remove_key : Model, Str -> Model
remove_key = |model, key| edit(model, [RemoveKey(key)])

move_first_to_end : Model -> Model
move_first_to_end = |model|
	if model.rows.len() < 2 {
		model
	} else {
		edit(model, [MoveRange({ from: 0, count: 1, to: model.rows.len() - 1 })])
	}

move_key_to_front : Model, Str -> Model
move_key_to_front = |model, key|
	match Rows.get(model.rows, 0) {
		Ok(first) if first.id != key => edit(model, [MoveKeyBefore({ key, before: Key(first.id) })])
		_ => model
	}

move_key_to_end : Model, Str -> Model
move_key_to_end = |model, key| edit(model, [MoveKeyBefore({ key, before: End })])

rename_first : Model -> Model
rename_first = |model|
	match Rows.get(model.rows, 0) {
		Ok(row) => edit(model, [SetAt({ at: 0, item: { ..row, label: "${row.label} !" } })])
		Err(_) => model
	}

rename_key : Model, Str -> Model
rename_key = |model, key|
	match Rows.get_key(model.rows, key) {
		Ok(row) => edit(model, [SetKey({ key, item: { ..row, label: "${row.label} *" } })])
		Err(_) => model
	}

clear : Model -> Model
clear = |model| edit(model, [Clear])

replace_all : Model -> Model
replace_all = |model| {
	replacement = [fresh_row(model.next_id), fresh_row(model.next_id + 1)]
	rows = Rows.replace_all(model.rows, replacement) ?? model.rows
	{ rows, next_id: model.next_id + 2 }
}

count_label : Model -> Str
count_label = |model| "Rows: ${model.rows.len().to_str()}"

render_row : Ui.State(Model), Ui.Row(Row) -> Elem
render_row = |model, row| {
	key = row.key()
	Html.div(
		[Html.test_id("row-${key}")],
		[
			Html.text_s(row.map(|value| value.label)),
			Html.button("Rename ${key}", model.on_unit(|value| rename_key(value, key))),
			Html.button("Front ${key}", model.on_unit(|value| move_key_to_front(value, key))),
			Html.button("End ${key}", model.on_unit(|value| move_key_to_end(value, key))),
			Html.button("Remove ${key}", model.on_unit(|value| remove_key(value, key))),
		],
	)
}

main : () -> Elem
main = || {
	Ui.state(
		{ rows: Rows.from_list(initial_rows, row_key) ?? Rows.empty(row_key), next_id: 4 },
		|model| {
			rows = model.signal().map(|value| value.rows)

			Html.div_c(
				"grid gap-6",
				[
					Html.heading("Keyed row edits"),
					Html.paragraph_s_attrs(model.signal().map(count_label), [Html.test_id("count")]),
					Html.button("Append", model.on_unit(append)),
					Html.button("Insert first", model.on_unit(insert_first)),
					Html.button("Insert before last", model.on_unit(insert_before_last)),
					Html.button("Remove first", model.on_unit(remove_first)),
					Html.button("Move first to end", model.on_unit(move_first_to_end)),
					Html.button("Rename first", model.on_unit(rename_first)),
					Html.button("Replace all", model.on_unit(replace_all)),
					Html.button("Clear", model.on_unit(clear)),
					Html.div([Html.test_id("rows")], [Ui.each(rows, |row| render_row(model, row))]),
				],
			)
		},
	)
}
