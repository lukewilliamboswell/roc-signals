import pf.Engine exposing [Elem, Signal]
import pf.Html
import AppStore
import Designer
import Form
import Preview
import Schema

## Form Builder: design a form on the left and answer the form it
## generates on the right.
##
## The fields, the answers and the count of submissions are cells of the
## app's store (`AppStore`). The fields are a table: the designer and the
## preview each draw a view of it in the form's order, so an edit of one
## field wakes that field's row in each. The form's totals are counted
## once per write, in one `derive` layer that the figures at the top and
## the preview's submit button read. Each part is drawn by its own module
## over the cells this page hands it: the page imports the store, the
## parts do not.
FormApp := [].{

	## The page, over the store.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Engine.derive(Preview.totals(preview), |sums| page(sums))

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| AppStore.store, |_boot| FormApp.view({}))
}

## What the preview is drawn over: the fields it reads, and the cells it
## writes.
preview = { fields: AppStore.cells.schema.fields, answers: AppStore.cells.answers, submissions: AppStore.cells.submissions }

## The page under the form's totals: the figures, the toolbar, the designer
## and the preview.
page : Signal(ctx, Form.Totals) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
page = |sums| Html.div(
	"app-shell app-shell-wide",
	[
		Html.section(
			"Form Builder",
			"app-header",
			[
				Html.h1("Form Builder", "app-title"),
				Html.p("Design a form on the left and answer the form it generates on the right. Field definitions and answers are two independent sources; every preview label, every validation message, and the submit button's disabled state are derived from both.", "app-subtitle"),
			],
		),
		Html.div(
			"stat-grid",
			[
				stat({ caption: "Fields", id: "designer-status" }, sums.map(|now| now.fields.to_str())),
				stat({ caption: "Valid answers", id: "valid-answers" }, sums.map(|now| Form.valid_count(now).to_str())),
				stat({ caption: "Problems", id: "preview-status" }, sums.map(|now| now.problems.to_str())),
				stat({ caption: "Submissions", id: "submissions-count" }, AppStore.cells.submissions.signal().map(|count| count.to_str())),
			],
		),
		Html.section(
			"Field toolbar",
			"panel grid gap-3 p-4",
			[
				Html.h2("Add a field", "panel-title"),
				Html.div(
					"toolbar",
					[
						add_button("Add text field", Form.text_kind),
						add_button("Add number field", Form.number_kind),
						add_button("Add email field", Form.email_kind),
						add_button("Add select field", Form.select_kind),
						add_button("Add checkbox field", Form.checkbox_kind),
					],
				),
			],
		),
		Html.div(
			"grid gap-5 lg:grid-cols-2",
			[
				Designer.view(AppStore.cells.schema.fields),
				Preview.view(preview, sums),
			],
		),
	],
)

## A button that adds a field of `kind`, under the number the store holds
## for the next field when it is pressed.
add_button : Str, Form.Kind -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
add_button = |label, kind| Html.button(label, [Engine.class("button button-sm")], Engine.handle_by(AppStore.cells.schema.next.signal(), |number, _| Schema.added(AppStore.cells.schema, { kind, number })))

## One figure, under its caption.
stat : { caption : Str, id : Str }, Signal(ctx, Str) -> Elem(ctx)
stat = |{ caption, id }, value| Html.div("stat", [Html.p(caption, "stat-label"), Html.p_s(value, [Engine.class("stat-value numeric"), Engine.test_id(id)])])
