app [main] { roc: "nightly-2026-09-11-793f9d8", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Ui

## Locality fixture: one keyed list grows to 1,000 or 10,000 rows through an
## explicit snapshot, then receives single-row direct-parent deltas whose
## engine bookkeeping must not depend on the site size. Buttons also cover a
## mixed edit batch, remove-then-reinsert churn across events, a lineage fork
## (a delta from a stale sibling generation), and a rollback to an earlier
## generation, so the counted direct path and the counted snapshot path can be
## told apart by their metrics.
Row : { id : Str, label : Str }

Model : { rows : Rows(Row), previous : Rows(Row), parked : List(Row), next_id : U64 }

row_key : Row -> Str
row_key = |row| row.id

fresh_row : U64 -> Row
fresh_row = |id| { id: id.to_str(), label: "Row ${id.to_str()}" }

make_rows : U64, U64 -> List(Row)
make_rows = |start, count| {
	var $rows = List.with_capacity(count)
	var $index = 0.U64
	while $index < count {
		$rows = $rows.append(fresh_row(start + $index))
		$index = $index + 1
	}
	$rows
}

## Explicit snapshot: every row is fresh, so the site reconciles a full list.
create : Model, U64 -> Model
create = |model, count| {
	rows = Rows.replace_all(model.rows, make_rows(model.next_id, count)) ?? crash "fixture generated duplicate row keys"
	{ rows, previous: rows, parked: [], next_id: model.next_id + count }
}

## Direct-parent delta: the new generation's parent is the published one.
edit : Model, List(Rows.Edit(Row)) -> Model
edit = |model, edits| {
	rows = Rows.apply(model.rows, edits) ?? crash "fixture edit was invalid"
	{ ..model, rows, previous: model.rows }
}

append_one : Model -> Model
append_one = |model| { ..edit(model, [Append([fresh_row(model.next_id)])]), next_id: model.next_id + 1 }

remove_middle : Model -> Model
remove_middle = |model| {
	at = model.rows.len() // 2
	match Rows.get(model.rows, at) {
		Ok(row) => { ..edit(model, [RemoveRange({ at, count: 1 })]), parked: model.parked.append(row) }
		Err(_) => model
	}
}

move_first_to_end : Model -> Model
move_first_to_end = |model|
	if model.rows.len() < 2 {
		model
	} else {
		edit(model, [MoveRange({ from: 0, count: 1, to: model.rows.len() - 1 })])
	}

## One batch mixing every direct edit kind: append, remove, move, and a
## same-key item update.
mixed_batch : Model -> Model
mixed_batch = |model|
	match Rows.get(model.rows, 2) {
		Ok(row) if model.rows.len() >= 6 =>
			{
				..edit(
					model,
					[
						Append([fresh_row(model.next_id)]),
						RemoveRange({ at: 1, count: 1 }),
						MoveRange({ from: 0, count: 1, to: 4 }),
						SetKey({ key: row.id, item: { ..row, label: "${row.label} !" } }),
					],
				),
				next_id: model.next_id + 1,
			}
		_ => model
	}

## Reinserts the most recently removed row in a later event, so the key
## returns under a fresh slot and row scope rather than a same-batch move.
reinsert_parked : Model -> Model
reinsert_parked = |model|
	match model.parked {
		[.., row] => { ..edit(model, [Append([row])]), parked: model.parked.drop_last(1) }
		_ => model
	}

## Lineage fork: a delta from the generation before the published one. Its
## parent token does not match the site, so the engine must reconcile it as a
## snapshot rather than trust the stale delta.
stale_sibling_append : Model -> Model
stale_sibling_append = |model| {
	rows = Rows.apply(model.previous, [Append([fresh_row(model.next_id)])]) ?? crash "fixture stale edit was invalid"
	{ ..model, rows, previous: model.rows, next_id: model.next_id + 1 }
}

## Rollback: republishes an earlier generation whose parent is not the site's
## current generation.
rollback : Model -> Model
rollback = |model| { ..model, rows: model.previous, previous: model.rows }

count_label : Model -> Str
count_label = |model| "Rows: ${model.rows.len().to_str()}"

render_row : Ui.Row(Row) -> Elem
render_row = |row| {
	key = row.key()
	Html.div([Html.test_id("row-${key}")], [Html.text_s(row.map(|value| value.label))])
}

main : () -> Elem
main = || {
	Ui.state(
		{ rows: Rows.empty(row_key), previous: Rows.empty(row_key), parked: [], next_id: 1 },
		|model| {
			rows = model.signal().map(|value| value.rows)
			Html.div(
				[],
				[
					Html.heading("Rows direct delta locality"),
					Html.paragraph_s_attrs(model.signal().map(count_label), [Html.test_id("count")]),
					Html.button_attrs("Create 1,000 rows", [Html.test_id("create-1k")], model.update(|value| create(value, 1000))),
					Html.button_attrs("Create 10,000 rows", [Html.test_id("create-10k")], model.update(|value| create(value, 10000))),
					Html.button_attrs("Append one row", [Html.test_id("append-one")], model.update(append_one)),
					Html.button_attrs("Remove middle row", [Html.test_id("remove-middle")], model.update(remove_middle)),
					Html.button_attrs("Move first row to end", [Html.test_id("move-first-to-end")], model.update(move_first_to_end)),
					Html.button_attrs("Apply mixed batch", [Html.test_id("mixed-batch")], model.update(mixed_batch)),
					Html.button_attrs("Reinsert removed row", [Html.test_id("reinsert-removed")], model.update(reinsert_parked)),
					Html.button_attrs("Append from stale sibling", [Html.test_id("stale-sibling-append")], model.update(stale_sibling_append)),
					Html.button_attrs("Roll back", [Html.test_id("roll-back")], model.update(rollback)),
					Html.div([Html.test_id("rows")], [Ui.each(rows, render_row)]),
				],
			)
		},
	)
}
