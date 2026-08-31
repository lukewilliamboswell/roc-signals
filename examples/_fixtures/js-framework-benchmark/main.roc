app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Row : { id : Str, label : Str }

Model : { rows : List(Row), next_id : U64, selected : Str }

adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]

colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]

nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]

label_for : U64 -> Str
label_for = |id| {
	adjective = adjectives.get((id * 17 + 11) % 25) ?? "pretty"
	colour = colours.get((id * 7 + 3) % 11) ?? "red"
	noun = nouns.get((id * 13 + 5) % 13) ?? "table"
	"${adjective} ${colour} ${noun}"
}

make_rows : U64, U64 -> List(Row)
make_rows = |start, count|
	List.repeat(0.U64, count).map_with_index(
		|_, index| {
			id: (start + index).to_str(),
			label: label_for(start + index),
		},
	)

replace_with : Model, U64 -> Model
replace_with = |model, count| {
	rows = make_rows(model.next_id, count)
	{ rows, next_id: model.next_id + count, selected: "" }
}

append_rows : Model, U64 -> Model
append_rows = |model, count| {
	rows = List.concat(model.rows, make_rows(model.next_id, count))
	{ ..model, rows, next_id: model.next_id + count }
}

update_every_tenth : Model -> Model
update_every_tenth = |model| {
	rows = model.rows.map_with_index(
		|row, index|
			if index % 10 == 0 {
				{ ..row, label: "${row.label} !!!" }
			} else {
				row
			},
	)
	{ ..model, rows }
}

swap_rows : Model -> Model
swap_rows = |model| {
	rows = List.swap(model.rows, 1, 998) ?? model.rows
	{ ..model, rows }
}

remove_row : Model, Str -> Model
remove_row = |model, id| { ..model, rows: model.rows.keep_if(|row| row.id != id) }

element : Str, List(Html.Attr), List(Elem) -> Elem
element = |tag, attrs, children| Elem.Element({ tag, attrs, children })

render_row : Ui.State(Model), Signal.Signal(Str), Str, Signal.Signal(Row) -> Elem
render_row = |model, selected, key, row| {
	label = row.map(|value| value.label)
	classes = Signal.select(selected, key).map(
		|is_selected| if is_selected {
			"danger"
		} else {
			""
		},
	)
	element(
		"tr",
		[Html.class_attr_s(classes), Html.attr("data-row-id", key), Html.test_id("row-${key}")],
		[
			element("td", [Html.class_attr("col-md-1")], [Html.text(key)]),
			element(
				"td",
				[Html.class_attr("col-md-4")],
				[
					element("a", [Html.on_event("click", Html.event_policy_none, model.on_unit(|value| { ..value, selected: key })), Html.aria_label("Select row ${key}")], [Html.text_s(label)]),
				],
			),
			element(
				"td",
				[Html.class_attr("col-md-1")],
				[
					element(
						"a",
						[Html.on_event("click", Html.event_policy_none, model.on_unit(|value| remove_row(value, key))), Html.aria_label("Remove row ${key}")],
						[element("span", [Html.class_attr("glyphicon glyphicon-remove"), Html.attr("aria-hidden", "true")], [])],
					),
				],
			),
			element("td", [Html.class_attr("col-md-6")], []),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		{ rows: [], next_id: 1.U64, selected: "" },
		|model| {
			model_signal = model.signal()
			rows = Signal.map(model_signal, |value| value.rows)
			selected = Signal.map(model_signal, |value| value.selected)
			Html.div(
				[Html.class_attr("container")],
				[
					element(
						"div",
						[Html.class_attr("jumbotron")],
						[
							element(
								"div",
								[Html.class_attr("row")],
								[
									element("div", [Html.class_attr("col-md-6")], [element("h1", [], [Html.text("Roc Signals-keyed")])]),
									element(
										"div",
										[Html.class_attr("col-md-6")],
										[
											element(
												"div",
												[Html.class_attr("row")],
												[
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Create 1,000 rows", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "run")], model.on_unit(|value| replace_with(value, 1000)))]),
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Create 10,000 rows", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "runlots")], model.on_unit(|value| replace_with(value, 10000)))]),
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Append 1,000 rows", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "add")], model.on_unit(|value| append_rows(value, 1000)))]),
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Update every 10th row", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "update")], model.on_unit(update_every_tenth))]),
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Clear", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "clear")], model.on_unit(|value| { ..value, rows: [], selected: "" }))]),
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Swap Rows", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "swaprows")], model.on_unit(swap_rows))]),
												],
											),
										],
									),
								],
							),
						],
					),
					element(
						"table",
						[Html.class_attr("table table-hover table-striped test-data")],
						[
							element("tbody", [Html.attr("id", "tbody")], [Ui.each_str(rows, |row| row.id.to_str(), |key, row| render_row(model, selected, key, row))]),
						],
					),
					element("span", [Html.class_attr("preloadicon glyphicon glyphicon-remove"), Html.attr("aria-hidden", "true")], []),
				],
			)
		},
	)
