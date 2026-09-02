app [main] {
	pf: platform "../../../platform/main.roc",
	rand: "https://github.com/kili-ilo/roc-random/releases/download/0.9.2/2ZXLX8WRqrosGu1V3VL5aXqgtfTRvJmjFPx8a26ecVmc.tar.zst",
}

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows exposing [Rows]
import pf.Signal
import pf.Ui
import rand.Random

Row : { id : Str, label : Str }

Model : { rows : Rows(Row), next_id : U64, random : Random.State, selected : Str }

adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]

colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]

nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]

adjective_generator = Random.choice("pretty", adjectives.drop_first(1))

colour_generator = Random.choice("red", colours.drop_first(1))

noun_generator = Random.choice("table", nouns.drop_first(1))

make_rows : Random.State, U64, U64 -> { random : Random.State, rows : List(Row) }
make_rows = |random, start, count| {
	var $random = random
	var $rows = List.with_capacity(count)
	var $index = 0.U64
	while $index < count {
		{ value: adjective, state: $random } = Random.step($random, adjective_generator)
		{ value: colour, state: $random } = Random.step($random, colour_generator)
		{ value: noun, state: $random } = Random.step($random, noun_generator)
		id = start + $index
		$rows = $rows.append({ id: id.to_str(), label: "${adjective} ${colour} ${noun}" })
		$index = $index + 1
	}
	{ random: $random, rows: $rows }
}

replace_with : Model, U64 -> Model
replace_with = |model, count| {
	generated = make_rows(model.random, model.next_id, count)
	rows = Rows.replace_all(model.rows, generated.rows) ?? crash "benchmark generated duplicate row keys"
	{ rows, next_id: model.next_id + count, random: generated.random, selected: "" }
}

append_rows : Model, U64 -> Model
append_rows = |model, count| {
	generated = make_rows(model.random, model.next_id, count)
	rows = Rows.apply(model.rows, [Append(generated.rows)]) ?? crash "benchmark generated duplicate row keys"
	{ ..model, rows, next_id: model.next_id + count, random: generated.random }
}

update_every_tenth : Model -> Model
update_every_tenth = |model| {
	var $edits = []
	var $index = 0
	while $index < model.rows.len() {
		row = Rows.get(model.rows, $index) ?? crash "benchmark row index was invalid"
		$edits = $edits.prepend(SetAt({ at: $index, item: { ..row, label: "${row.label} !!!" } }))
		$index = $index + 10
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

remove_row : Model, Str -> Model
remove_row = |model, id| { ..model, rows: Rows.apply(model.rows, [RemoveKey(id)]) ?? model.rows }

element : Str, List(Html.Attr), List(Elem) -> Elem
element = |tag, attrs, children| Elem.Element({ tag, attrs, children })

render_row : Ui.State(Model), Signal.Keyed(Str), Str, Ui.Row(Row) -> Elem
render_row = |model, selected, key, row| {
	label = row.map(|value| value.label)
	classes = row.select(selected)
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
main = || {
	entropy_seed = Browser.entropy_seed()
	Ui.state(
		{ rows: Rows.empty(|row| row.id), next_id: 1.U64, random: Random.seed(0), selected: "" },
		|model| {
			model_signal = model.signal()
			rows = Signal.map(model_signal, |value| value.rows)
			selected = Signal.map(model_signal, |value| value.selected)
			selected_keyed = selected.keyed("danger", "")
			Html.div(
				[Html.class_attr("container")],
				[
					Ui.on_change_initial(entropy_seed, |seed| model.set_cmd({ rows: Rows.empty(|row| row.id), next_id: 1.U64, random: Random.seed(seed), selected: "" })),
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
													element("div", [Html.class_attr("col-sm-6 smallpad")], [Html.button_attrs("Clear", [Html.attr("type", "button"), Html.class_attr("btn btn-primary btn-block"), Html.attr("id", "clear")], model.on_unit(|value| { ..value, rows: Rows.apply(value.rows, [Clear]) ?? value.rows, selected: "" }))]),
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
							element("tbody", [Html.attr("id", "tbody")], [Ui.each(rows, |each_row| render_row(model, selected_keyed, each_row.key(), each_row))]),
						],
					),
					element("span", [Html.class_attr("preloadicon glyphicon glyphicon-remove"), Html.attr("aria-hidden", "true")], []),
				],
			)
		},
	)
}
