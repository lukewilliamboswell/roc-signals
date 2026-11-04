app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Row : { id : Str, label : Str }

Model : { rows : Rows(Row), next_id : U64, seed : U64, selected : Str }

adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]

colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]

nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]

## Linear congruential step; the real fixture uses roc-random.
next_seed : U64 -> U64
next_seed = |seed| (seed * 6364136223846793005 + 1442695040888963407) % 18446744073709551557

pick : List(Str), U64 -> Str
pick = |words, seed| words.get(seed % words.len()) ?? "?"

make_rows : U64, U64, U64 -> { seed : U64, rows : List(Row) }
make_rows = |seed, start, count| {
	var $seed = seed
	var $rows = List.with_capacity(count)
	var $index = 0.U64
	while $index < count {
		$seed = next_seed($seed)
		adjective = pick(adjectives, $seed)
		$seed = next_seed($seed)
		colour = pick(colours, $seed)
		$seed = next_seed($seed)
		noun = pick(nouns, $seed)
		id = start + $index
		$rows = $rows.append({ id: id.to_str(), label: "${adjective} ${colour} ${noun}" })
		$index = $index + 1
	}
	{ seed: $seed, rows: $rows }
}

replace_with : Model, U64 -> Model
replace_with = |model, count| {
	generated = make_rows(model.seed, model.next_id, count)
	rows = Rows.replace_all(model.rows, generated.rows) ?? crash "benchmark generated duplicate row keys"
	{ rows, next_id: model.next_id + count, seed: generated.seed, selected: "" }
}

append_rows : Model, U64 -> Model
append_rows = |model, count| {
	generated = make_rows(model.seed, model.next_id, count)
	rows = Rows.apply(model.rows, [Append(generated.rows)]) ?? crash "benchmark generated duplicate row keys"
	{ ..model, rows, next_id: model.next_id + count, seed: generated.seed }
}

update_every_tenth : Model -> Model
update_every_tenth = |model| {
	count = (model.rows.len() + 9).div_trunc_by(10)
	var $edits = List.with_capacity(count)
	var $remaining = count
	while $remaining > 0 {
		$remaining = $remaining - 1
		index = $remaining * 10
		row = Rows.get(model.rows, index) ?? crash "benchmark row index was invalid"
		$edits = $edits.append(SetAt({ at: index, item: { ..row, label: "${row.label} !!!" } }))
	}
	rows = Rows.apply(model.rows, $edits) ?? crash "benchmark row update was invalid"
	{ ..model, rows }
}

swap_rows : Model -> Model
swap_rows = |model| {
	rows =
		if model.rows.len() <= 998 {
			model.rows
		} else {
			Rows.apply(model.rows, [MoveRange({ from: 998, count: 1, to: 1 }), MoveRange({ from: 2, count: 1, to: 998 })]) ?? crash "benchmark swap was invalid"
		}
	{ ..model, rows }
}

clear_rows : Model -> Model
clear_rows = |model| { ..model, rows: Rows.apply(model.rows, [Clear]) ?? model.rows, selected: "" }

## Handlers receive the row key when they fire: no per-row closure.
remove_row : Model, Str -> Model
remove_row = |model, id| { ..model, rows: Rows.apply(model.rows, [RemoveKey(id)]) ?? model.rows }

select_row : Model, Str -> Model
select_row = |model, id| { ..model, selected: id }

## Described once for the site. `row` is an accessor, not a row.
render_row : Ui.State(Model), Html.Attr(Ui.Site(Ui.Root, Row)), Ui.RowRef(Ui.Root, Row) -> Elem(Ui.Site(Ui.Root, Row))
render_row = |model, selected_class, row| {
	key = row.key()
	Html.element(
		"tr",
		[selected_class, Html.attr_s("data-row-id", key), Html.test_id_s(key.map(|k| "row-${k}"))],
		[
			Html.element("td", [Html.class_attr("col-md-1")], [Html.text_s(key)]),
			Html.element(
				"td",
				[Html.class_attr("col-md-4")],
				[
					Html.element(
						"a",
						[Html.on_click(model.update_by(key, select_row)), Html.aria_label_s(key.map(|k| "Select row ${k}"))],
						[Html.text_s(row.field(|r| r.label))],
					),
				],
			),
			Html.element(
				"td",
				[Html.class_attr("col-md-1")],
				[
					Html.element(
						"a",
						[Html.on_click(model.update_by(key, remove_row)), Html.aria_label_s(key.map(|k| "Remove row ${k}"))],
						[Html.element("span", [Html.class_attr("glyphicon glyphicon-remove"), Html.attr("aria-hidden", "true")], [])],
					),
				],
			),
			Html.element("td", [Html.class_attr("col-md-6")], []),
		],
	)
}

control : Str, Str, Ui.Handler(Ui.Root) -> Elem(Ui.Root)
control = |id, label, handler|
	Html.element(
		"div",
		[Html.class_attr("col-sm-6 smallpad")],
		[Html.button_attrs(label, [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", id)], handler)],
	)

main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		{ rows: Rows.empty(|row| row.id), next_id: 1.U64, seed: 0, selected: "" },
		|model| {
			model_signal = model.signal()
			rows = model_signal.map(|value| value.rows)
			selected = model_signal.map(|value| value.selected).keyed("danger", "")
			Html.div(
				[Html.class_attr("container")],
				[
					Html.element(
						"div",
						[Html.class_attr("jumbotron")],
						[
							Html.element("h1", [], [Html.text("Roc Signals-keyed")]),
							control("run", "Create 1,000 rows", model.update(|value| replace_with(value, 1000))),
							control("runlots", "Create 10,000 rows", model.update(|value| replace_with(value, 10000))),
							control("add", "Append 1,000 rows", model.update(|value| append_rows(value, 1000))),
							control("update", "Update every 10th row", model.update(update_every_tenth)),
							control("clear", "Clear", model.update(clear_rows)),
							control("swaprows", "Swap Rows", model.update(swap_rows)),
						],
					),
					Html.element(
						"table",
						[Html.class_attr("table table-hover table-striped test-data")],
						[
							Html.element(
								"tbody",
								[Html.attr("id", "tbody")],
								[Ui.each(rows, |row| render_row(model, Html.class_attr_s(row.select(selected)), row))],
							),
						],
					),
				],
			)
		},
	)
}

## The root description builds; each row template is described once, with holes.
expect {
	actual = Elem.platform_describe(main())
	actual == "<div:1><div:1><h1:0>Roc Signals-keyed</h1><div:1><button:4>Create 1,000 rows</button></div><div:1><button:4>Create 10,000 rows</button></div><div:1><button:4>Append 1,000 rows</button></div><div:1><button:4>Update every 10th row</button></div><div:1><button:4>Clear</button></div><div:1><button:4>Swap Rows</button></div></div><table:1><tbody:1>{each <tr:3><td:1>{val}</td><td:1><a:2>{val}</a></td><td:1><a:2><span:2></span></a></td><td:1></td></tr>}</tbody></table></div>"
}
