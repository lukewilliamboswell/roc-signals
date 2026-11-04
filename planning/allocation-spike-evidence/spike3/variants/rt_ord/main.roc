app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../../../../../../../../home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a9954894a6aa838c9/platform-web/main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

Item : { id : Str }

Model : { rows : Rows(Item), mounted : Bool }

element : Str, List(Html.Attr), List(Elem) -> Elem
element = |tag, attrs, children| Elem.Element({ namespace: Html, tag, attrs, children })

## The row a template site declares once: static text and attributes, with the
## exact key placed by symbol rather than interpolated.
template_row : Str, Ui.TemplateRow -> Elem
template_row = |site, row|
	element(
		"li",
		[row.keyed_attr(Html.test_id("${site}-")), row.keyed_attr(Html.attr("data-key", ""))],
		[
			element("span", [Html.class_attr("name")], [row.key_text()]),
			element("a", [row.keyed_attr_with(Html.aria_label("Open ${site} "), " now"), Html.attr("href", "#")], [row.key_text_with({ prefix: "<", suffix: ">" })]),
			Html.text("static"),
		],
	)

## The same row written as an ordinary builder, so both sites must render alike.
ordinary_row : Str, Str -> Elem
ordinary_row = |site, key|
	element(
		"li",
		[Html.test_id("${site}-${key}"), Html.attr("data-key", key)],
		[
			element("span", [Html.class_attr("name")], [Html.text(key)]),
			element("a", [Html.aria_label("Open ${site} ${key} now"), Html.attr("href", "#")], [Html.text("<${key}>")]),
			Html.text("static"),
		],
	)

initial : Model
initial = {
	rows: Rows.from_list([{ id: "a" }, { id: "b" }, { id: "c" }], |item| item.id) ?? crash "fixture keys are unique",
	mounted: True,
}

edit : Model, List(Rows.Edit(Item)) -> Model
edit = |model, edits| { ..model, rows: Rows.apply(model.rows, edits) ?? crash "fixture edit was valid" }

main : () -> Elem
main = ||
	Ui.state(
		initial,
		|model| {
			rows = Signal.map(model.signal(), |value| value.rows)
			mounted = Signal.map(model.signal(), |value| value.mounted)
			Html.div(
				[],
				[
					Html.button("Append", model.update(|value| edit(value, [Append([{ id: "d" }, { id: "e" }])]))),
					Html.button("Reorder", model.update(|value| edit(value, [MoveRange({ from: 0, count: 1, to: 2 })]))),
					Html.button("Remove", model.update(|value| edit(value, [RemoveKey("b")]))),
					Html.button("Toggle", model.update(|value| { ..value, mounted: !value.mounted })),
					element("ul", [Html.test_id("first")], [Ui.each_template(rows, |row| template_row("first", row))]),
					element("ul", [Html.test_id("second")], [Ui.each_template(rows, |row| template_row("second", row))]),
					element("ul", [Html.test_id("ordinary")], [Ui.each(rows, |row| ordinary_row("ordinary", row.key()))]),
					Ui.when(
						mounted,
						|| element("ul", [Html.test_id("nested")], [Ui.each(rows, |row| ordinary_row("nested", row.key()))]),
						|| Html.text("unmounted"),
					),
				],
			)
		},
	)
