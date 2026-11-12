import pf.Engine exposing [Cell, Elem, Row, State, Val]
import pf.Html
import Form
import Schema

## The live preview: the form the fields generate, with a control for each
## field, a verdict on its answer, and a submit button.
##
## It is drawn over cells of whichever store holds them (`Props`). It
## reads the fields and writes only the answers and the count of
## submissions, so it can answer a field and never redefine one.
Preview := [].{

	## What the preview is drawn over, in a store whose storage is `st`:
	## the fields it shows, the answers typed into it, and how often the
	## form has been submitted.
	Props(st) : { fields : Cell(st, Schema.Fields), answers : Cell(st, Form.Answers), submissions : Cell(st, U64) }

	## What typing in a field's control, or choosing one of its options,
	## writes: the text of that field's answer.
	answered_text : Cell(st, Form.Answers), { key : U64, text : Str } -> List(Engine.Write(st))
	answered_text = |answers, { key, text }| [answers.change(|held| Form.set_answer_text(held, key, text))]

	## What ticking a field's checkbox writes: the flag of that field's
	## answer.
	answered_flag : Cell(st, Form.Answers), { key : U64, flag : Bool } -> List(Engine.Write(st))
	answered_flag = |answers, { key, flag }| [answers.change(|held| Form.set_answer_flag(held, key, flag))]

	## What "Clear preview answers" writes: no answers. The fields are not
	## touched, so every verdict is read again against an empty answer.
	cleared : Cell(st, Form.Answers) -> List(Engine.Write(st))
	cleared = |answers| [answers.put(Form.no_answers)]

	## What "Submit form" writes, given the form's totals when it is
	## pressed: one more submission of a form that can be submitted, and
	## nothing for one that cannot.
	submitted : Cell(st, U64), Form.Totals -> List(Engine.Write(st))
	submitted = |submissions, sums| if (Form.is_submittable(sums)) [submissions.change(|count| count + 1)] else []

	## The form's totals: its fields, and those that hold a problem. It
	## reads every field and its answer, so mount it once in an
	## `Engine.derive` and read that layer: the count is then taken once
	## for each write of the fields or the answers.
	totals : Props(st) -> Val(ctx, Form.Totals)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	totals = |props| props.fields.val().map2(
		props.answers.val(),
		|table, answers| table.fold(Form.empty_totals, |sum, key, field| Form.counted(sum, Form.row_of(field, Form.answer_of(answers, key)))),
	)

	## The preview, over its cells. `sums` is the form's totals.
	view : Props(st), Val(ctx, Form.Totals) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props, sums| {
		ready = sums.map(Form.is_submittable)
		Html.section(
			"Live preview",
			"panel",
			[
				Html.div(
					"panel-head",
					[
						Html.h2("Live preview", "panel-title"),
						Html.div(
							"flex items-center gap-2",
							[
								Html.p_v(ready.map(|ok| if (ok) "Ready to submit" else "Not ready"), [Engine.class_v(ready.map(|ok| if (ok) "badge badge-ok" else "badge badge-warn")), Engine.test_id("submittable-state")]),
								Html.button("Clear preview answers", [Engine.attr("type", "button"), Engine.class("button-ghost")], Engine.does(Preview.cleared(props.answers))),
							],
						),
					],
				),
				Html.div(
					"panel-body",
					[
						Html.form(
							"Preview form",
							[Engine.class("grid gap-4")],
							[
								Engine.when(
									Schema.has_fields(props.fields),
									# The template is a lambda here, not the result of
									# a helper that returns one (roc-lang/roc#12970).
									|| Schema.each_field(props.fields, |key, field| answer_row(props.answers, key, field)),
									|| Html.div("empty-state", [Html.p_attrs("No fields yet. The generated form is empty.", [])]),
								),
								Html.div(
									"flex justify-end border-t border-zinc-200 pt-4",
									[
										Html.button(
											"Submit form",
											[Engine.attr("type", "button"), Engine.class("button-primary"), Html.disabled(ready.map(|ok| !ok))],
											Engine.handle_by(sums, |now, _| Preview.submitted(props.submissions, now)),
										),
									],
								),
							],
						),
					],
				),
			],
		)
	}
}

## One field of the generated form: its label, the control its kind asks
## for, and the verdict on its answer.
##
## The row is a row of a view of the fields, so what it shows of the
## definition wakes only when its own field is written. Its answer is one
## entry of the answers' cell, which it reads by its number: that reading
## is evaluated on every write of the answers, and pruned where it is the
## same.
answer_row : Cell(st, Form.Answers), Val(Row(ctx, U64), U64), State(Row(ctx, U64), Form.Field) -> Elem(Row(ctx, U64))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
answer_row = |answers, key, field| {
	named = |prefix| key.map(|number| "${prefix} ${Form.id_of(number)}")
	defined = field.val()
	answer = answers.val().map2(key, Form.answer_of)
	resolved = defined.map2(answer, Form.row_of)
	invalid = Html.aria_invalid(resolved.map(|row| row.error != ""))
	text = answer.map(|now| now.text)
	write_text = Engine.handle_by(key, |number, typed| Preview.answered_text(answers, { key: number, text: typed }))
	Html.section_v(
		named("Preview field"),
		"field",
		[
			Html.p_v(defined.map(|now| if (now.required) "${now.label} (required)" else now.label), [Engine.class("field-label"), Engine.test_id_v(key.map(|number| "preview-${Form.id_of(number)}-label"))]),
			Engine.when(
				defined.map(|now| Form.is_checkbox(now.kind)),
				|| Html.div(
					"check-row",
					[
						Html.checkbox(
							named("Answer"),
							answer.map(|now| now.flag),
							[Engine.class("checkbox"), invalid],
							Engine.handle_by(key, |number, checked| Preview.answered_flag(answers, { key: number, flag: checked == "true" })),
						),
						Engine.text("Yes"),
					],
				),
				|| Engine.when(
					defined.map(|now| Form.is_select(now.kind)),
					|| Html.select(
						named("Answer"),
						text,
						[Engine.class("input"), invalid],
						[
							Html.option("", "Choose..."),
							Engine.each(defined.map(|now| Form.options_of(now.options_text)), |option| option, |option| Html.option_v(option.key())),
						],
						write_text,
					),
					|| Html.text_input(
						named("Answer"),
						"text",
						text,
						[Engine.class("input"), Engine.attr_v("placeholder", defined.map(|now| if (Form.is_number(now.kind)) "42" else "Ada Lovelace")), invalid],
						write_text,
					),
				),
			),
			Html.p_v(resolved.map(Form.verdict_text), [Engine.class_v(resolved.map(Form.verdict_tone)), Engine.test_id_v(key.map(|number| "preview-${Form.id_of(number)}-verdict"))]),
		],
	)
}
