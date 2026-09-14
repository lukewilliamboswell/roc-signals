app [main] { pf: platform "../../platform-web/main.roc", roc: "nightly-2026-09-12-220fd47" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Ui

Row : { id : Str, value : U64 }

Action : [Fresh, Updated, UpdatedAll, ReplacedKey, Moved, Appended, AppendedAll, Mixed, Cleared]

Model : { rows : Rows(Row), previous : Rows(Row), action : Action }

row_key : Row -> Str
row_key = |row| row.id

create_rows : U64 -> Model
create_rows = |count| {
	var $items = List.with_capacity(count)
	var $index = 0.U64
	while $index < count {
		$items = $items.append({ id: $index.to_str(), value: 0.U64 })
		$index = $index + 1
	}
	rows = Rows.from_list($items, row_key) ?? crash "scaling fixture keys were not unique"
	{ rows, previous: rows, action: Fresh }
}

update_one : Model -> Model
update_one = |model| {
	before = Rows.get(model.rows, 0) ?? crash "scaling fixture has no first row"
	rows = Rows.apply(model.rows, [SetAt({ at: 0, item: { ..before, value: before.value + 1 } })]) ?? crash "scaling fixture update failed"
	{ ..model, rows, action: Updated }
}

key_change : Model -> Model
key_change = |model| {
	rows = Rows.apply(model.rows, [SetAt({ at: 0, item: { id: "changed", value: 1 } })]) ?? crash "scaling key replacement failed"
	{ ..model, rows, action: ReplacedKey }
}

move_one : Model -> Model
move_one = |model| {
	rows = Rows.apply(model.rows, [MoveRange({ from: 0, count: 1, to: model.rows.len() - 1 })]) ?? crash "scaling move failed"
	{ ..model, rows, action: Moved }
}

append_one : Model -> Model
append_one = |model| {
	rows = Rows.apply(model.rows, [Append([{ id: model.rows.len().to_str(), value: 0 }])]) ?? crash "scaling append failed"
	{ ..model, rows, action: Appended }
}

clear_rows : Model -> Model
clear_rows = |model| { ..model, action: Cleared, rows: Rows.apply(model.rows, [Clear]) ?? crash "scaling clear failed" }

update_all : Model -> Model
update_all = |model| {
	var $edits = List.with_capacity(model.rows.len())
	var $index = 0.U64
	while $index < model.rows.len() {
		row = Rows.get(model.rows, $index) ?? crash "scaling update index missing"
		$edits = $edits.append(SetAt({ at: $index, item: { ..row, value: 1 } }))
		$index = $index + 1
	}
	{ ..model, action: UpdatedAll, rows: Rows.apply(model.rows, $edits) ?? crash "scaling bulk update failed" }
}

append_all : Model -> Model
append_all = |model| {
	var $items = List.with_capacity(model.rows.len())
	var $index = model.rows.len()
	while $index < model.rows.len() * 2 {
		$items = $items.append({ id: $index.to_str(), value: 0.U64 })
		$index = $index + 1
	}
	{ ..model, action: AppendedAll, rows: Rows.apply(model.rows, [Append($items)]) ?? crash "scaling bulk append failed" }
}

replace_all : Model, Bool -> Model
replace_all = |model, snapshot| {
	var $items = List.with_capacity(model.rows.len())
	var $index = 0.U64
	while $index < model.rows.len() {
		$items = $items.append({ id: $index.to_str(), value: 1.U64 })
		$index = $index + 1
	}
	rows = if snapshot {
		Rows.replace_all(model.rows, $items) ?? crash "scaling snapshot replacement failed"
	} else {
		Rows.apply(model.rows, [RemoveRange({ at: 0, count: model.rows.len() }), Append($items)]) ?? crash "scaling remove and reinsert failed"
	}
	{ ..model, rows, action: UpdatedAll }
}

mixed_edits : Model -> Model
mixed_edits = |model| {
	var $edits = List.with_capacity(model.rows.len() * 2 + 1)
	var $index = 0.U64
	while $index < model.rows.len() {
		$edits = $edits.append(SetAt({ at: $index, item: { id: $index.to_str(), value: 1 } }))
		$edits = $edits.append(Append([{ id: ($index + model.rows.len()).to_str(), value: 0 }]))
		$index = $index + 1
	}
	$edits = $edits.append(MoveRange({ from: 0, count: 1, to: model.rows.len() * 2 - 1 }))
	{ ..model, action: Mixed, rows: Rows.apply(model.rows, $edits) ?? crash "scaling mixed edits failed" }
}

## Executed by the runner only after timing and metric capture. Every row and
## every retained original is checked, so skipped bulk updates cannot satisfy
## the allocation budget by doing less semantic work.
validate_model : Model -> Model
validate_model = |model| {
	var $index = 0.U64
	while $index < model.rows.len() {
		row = Rows.get(model.rows, $index) ?? crash "oracle current row missing"
		expected_id = match model.action {
			ReplacedKey if $index == 0 => "changed"
			Moved | Mixed => (($index + 1).rem_by(model.rows.len())).to_str()
			_ => $index.to_str()
		}
		expected_value = match model.action {
			UpdatedAll => 1
			Mixed if ($index + 1).rem_by(model.rows.len()) < model.previous.len() => 1
			Updated if $index == 0 => 1
			ReplacedKey if $index == 0 => 1
			_ => 0
		}
		if row.id != expected_id or row.value != expected_value {
			crash "Rows scaling current collection differs from its reference model"
		}
		$index = $index + 1
	}
	$index = 0
	while $index < model.previous.len() {
		row = Rows.get(model.previous, $index) ?? crash "oracle retained row missing"
		if row.id != $index.to_str() or row.value != 0 {
			crash "Rows scaling mutated its retained generation"
		}
		$index = $index + 1
	}
	model
}

summary : Model -> Str
summary = |model| {
	len = model.rows.len()
	if len == 0 {
		"empty"
	} else {
		current = Rows.get(model.rows, 0) ?? crash "scaling fixture current row absent"
		previous = Rows.get(model.previous, 0) ?? crash "scaling fixture previous row absent"
		last = Rows.get(model.rows, len - 1) ?? crash "scaling fixture last row absent"
		"${len.to_str()}:${current.id}:${current.value.to_str()}:${last.id}:${previous.id}:${previous.value.to_str()}"
	}
}

main : () -> Elem
main = || Ui.state(
	{ rows: Rows.empty(row_key), previous: Rows.empty(row_key), action: Fresh },
	|model| {
		Html.div(
			[],
			[
				Html.button_attrs("Create 1,000", [Html.attr("id", "create-1000")], model.update(|_| create_rows(1000))),
				Html.button_attrs("Create 10,000", [Html.attr("id", "create-10000")], model.update(|_| create_rows(10000))),
				Html.button_attrs("Create 100,000", [Html.attr("id", "create-100000")], model.update(|_| create_rows(100000))),
				Html.button_attrs("Change first key", [Html.attr("id", "key")], model.update(key_change)),
				Html.button_attrs("Move first row", [Html.attr("id", "move")], model.update(move_one)),
				Html.button_attrs("Append one row", [Html.attr("id", "append")], model.update(append_one)),
				Html.button_attrs("Clear rows", [Html.attr("id", "clear")], model.update(clear_rows)),
				Html.button_attrs("Update all rows", [Html.attr("id", "update-all")], model.update(update_all)),
				Html.button_attrs("Append all rows", [Html.attr("id", "append-all")], model.update(append_all)),
				Html.button_attrs("Replace all rows", [Html.attr("id", "replace-all")], model.update(|value| replace_all(value, False))),
				Html.button_attrs("Snapshot all rows", [Html.attr("id", "snapshot-all")], model.update(|value| replace_all(value, True))),
				Html.button_attrs("Mixed edits", [Html.attr("id", "mixed")], model.update(mixed_edits)),
				Html.button_attrs("Validate all rows", [Html.attr("id", "validate")], model.update(validate_model)),
				Html.button_attrs("Update first row", [Html.attr("id", "update")], model.update(update_one)),
				Html.div([Html.test_id("summary")], [Html.text_s(model.signal().map(summary))]),
			],
		)
	},
)
