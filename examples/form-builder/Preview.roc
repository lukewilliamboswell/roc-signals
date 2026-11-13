import pf.Engine exposing [Cell, Elem, Row, Signal, State, Table]
import pf.Html
import Form
import Schema

## The live preview: the form the fields generate, with a control for each
## field, a verdict on its answer, and a submit button.
##
## It is drawn over cells of whichever store holds them (`Props`). It
## reads the fields and writes the answers, submission count and feedback
## cells, so it can answer a field and never redefine one.
Preview := [].{

	## What the preview is drawn over, in a store whose type is `st`:
	## the fields it shows, the answers typed into it, and how often the
	## form has been submitted, together with its submission feedback.
	Props(st) := { fields : Cell(st, Schema.Fields), answers : Cell(st, Form.Answers), submissions : Cell(st, U64), ui : Cells(st) }

	## Submission feedback is shared by the button, the problem summary and
	## the answer rows; dismissing the summary does not erase the attempt.
	Cells(st) : {
		attempted : Cell(st, Bool),
		problems_open : Cell(st, Bool),
		reveal : Cell(st, Engine.Outbox(Str)),
	}

	## What typing in a field's control, or choosing one of its options,
	## writes: the text of that field's answer.
	answered_text : Cell(st, Form.Answers), { key : U64, text : Str } -> List(Engine.Write(st))
	answered_text = |answers, { key, text }| [answers.update(|held| Form.set_answer_text(held, key, text))]

	## What ticking a field's checkbox writes: the flag of that field's
	## answer.
	answered_flag : Cell(st, Form.Answers), { key : U64, flag : Bool } -> List(Engine.Write(st))
	answered_flag = |answers, { key, flag }| [answers.update(|held| Form.set_answer_flag(held, key, flag))]

	## What "Clear preview answers" writes: no answers. The fields are not
	## touched, so every verdict is read again against an empty answer.
	cleared : Cell(st, Form.Answers) -> List(Engine.Write(st))
	cleared = |answers| [answers.set(Form.no_answers)]

	## Submit valid answers, or show the problems and reveal the first one
	## in the form's order. The outbox carries an element address, not a row identity.
	submitted : Props(st), { totals : Form.Totals, first : [NoProblem, FirstProblem(U64)] } -> List(Engine.Write(st))
	submitted = |props, reading| {
		ready = Form.is_submittable(reading.totals)
		[
			props.ui.attempted.set(True),
			props.ui.problems_open.set(!ready),
		].concat(
			if ready {
				[props.submissions.update(|count| count + 1)]
			} else match reading.first {
				NoProblem => []
				FirstProblem(key) => [props.ui.reveal.update(|box| box.post("answer-${Form.id_of(key)}"))]
			},
		)
	}

	## Locate a problem by the same declared order the field views use.
	## The reading returns only its key, so no table is kept beside a write.
	first_problem : Props(st) -> Signal(ctx, [NoProblem, FirstProblem(U64)])
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	first_problem = |props| props.fields.signal().map2(props.answers.signal(), first_problem_of)

	## The form's totals: its fields, and those that hold a problem. It
	## reads every field and its answer, so mount it once in an
	## `Engine.derive` and read that layer: the count is then taken once
	## for each write of the fields or the answers.
	totals : Props(st) -> Signal(ctx, Form.Totals)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	totals = |props| props.fields.signal().map2(
		props.answers.signal(),
		|table, answers| table.fold(Form.empty_totals, |sum, key, field| Form.counted(sum, Form.row_of(field, Form.answer_of(answers, key)))),
	)

	## The preview, over its cells. `sums` is the form's totals.
	view : Props(st), Signal(ctx, Form.Totals) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props, sums| {
		ready = sums.map(Form.is_submittable)
		submit = Engine.handle_by({ totals: sums, first: Preview.first_problem(props) }.Signal, |reading, _event| Preview.submitted(props, reading))
		Html.section(
			"Live preview",
			"panel",
			[
				Engine.on_post(
					props.ui.reveal.signal(),
					|name| [Engine.command(Engine.scroll_into_view(name, { block: Center, behavior: Smooth })), Engine.command(FocusInPlace(name))],
					Engine.ignore({}),
				),
				Html.div(
					"panel-head",
					[
						Html.h2("Live preview", "panel-title"),
						Html.div(
							"flex items-center gap-2",
							[
								Html.p_s(ready.map(|ok| if (ok) "Ready to submit" else "Not ready"), [Engine.class_s(ready.map(|ok| if (ok) "badge badge-ok" else "badge badge-warn")), Engine.test_id("submittable-state")]),
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
							[Engine.class("grid gap-4"), Html.on_submit(submit)],
							[
								Engine.when(
									Schema.has_fields(props.fields),
									# The template is a lambda here, not the result of
									# a helper that returns one (roc-lang/roc#12970).
									|| Schema.each_field(props.fields, |key, field| answer_row(props.answers, { key, field, attempted: props.ui.attempted.signal() })),
									|| Html.div("empty-state", [Html.p_attrs("No fields yet. The generated form is empty.", [])]),
								),
								Html.div(
									"flex justify-end border-t border-zinc-200 pt-4",
									[
										Html.submit_button(
											"Submit form",
											[Engine.class("button-primary"), Engine.attr("style", "anchor-name:--preview-submit")],
										),
									],
								),
							],
						),
						Html.popover(
							"Form problems",
							{
								open: props.ui.problems_open.signal().map2(ready, |wanted, valid| wanted and !valid),
								on_toggle: Engine.handle(|open| [props.ui.problems_open.set(open)]),
							},
							[
								Engine.test_id("form-problems"),
								Engine.class("panel max-w-sm p-4"),
								Engine.attr("style", "position-anchor:--preview-submit;position-area:top;inset:auto;margin:0 0 0.5rem;position-try-fallbacks:flip-block"),
							],
							[
								Html.h2("Review your answers", "panel-title"),
								Html.p_s(
									sums.map(|now| if (now.fields == 0) "Add a field before submitting." else "${now.problems.to_str()} problems need attention. Focus has moved to the first problem."),
									[Engine.class("mt-2 text-sm")],
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
answer_row : Cell(st, Form.Answers), { key : Signal(Row(ctx, U64), U64), field : State(Row(ctx, U64), Form.Field), attempted : Signal(Row(ctx, U64), Bool) } -> Elem(Row(ctx, U64))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
answer_row = |answers, { key, field, attempted }| {
	named = |prefix| key.map(|number| "${prefix} ${Form.id_of(number)}")
	defined = field.signal()
	answer = answers.signal().map2(key, Form.answer_of)
	resolved = defined.map2(answer, Form.row_of)
	invalid = Html.aria_invalid(resolved.map(|row| row.error != ""))
	reference = Engine.ref_s(key.map(|number| "answer-${Form.id_of(number)}"))
	text = answer.map(|now| now.text)
	write_text = Engine.handle_by(key, |number, typed| Preview.answered_text(answers, { key: number, text: typed }))
	Html.section_s(
		named("Preview field"),
		"field",
		[
			Html.p_s(defined.map(|now| if (now.required) "${now.label} (required)" else now.label), [Engine.class("field-label"), Engine.test_id_s(key.map(|number| "preview-${Form.id_of(number)}-label"))]),
			Engine.when(
				defined.map(|now| Form.is_checkbox(now.kind)),
				|| Html.div(
					"check-row",
					[
						Html.checkbox(
							named("Answer"),
							answer.map(|now| now.flag),
							[Engine.class("checkbox"), invalid, reference],
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
						[Engine.class("input"), invalid, reference],
						[
							Html.option("", "Choose..."),
							Engine.each(defined.map(|now| Form.options_of(now.options_text)), |option| option, |option| Html.option_s(option.key())),
						],
						write_text,
					),
					|| Html.text_input(
						named("Answer"),
						"text",
						text,
						[Engine.class("input"), Engine.attr_s("placeholder", defined.map(|now| if (Form.is_number(now.kind)) "42" else "Ada Lovelace")), invalid, reference],
						write_text,
					),
				),
			),
			Html.p_s(resolved.map(Form.verdict_text), [Engine.class_s(resolved.map2(attempted, |row, tried| if (tried and row.error != "") "text-xs font-medium text-red-600" else Form.verdict_tone(row))), Engine.test_id_s(key.map(|number| "preview-${Form.id_of(number)}-verdict"))]),
		],
	)
}

## Choose the first invalid definition by place and then key, independently
## of the table's iteration order.
first_problem_of : Schema.Fields, Form.Answers -> [NoProblem, FirstProblem(U64)]
first_problem_of = |table, answers| {
	first = table.fold(
		Err(NoProblem),
		|found, key, field| {
			if Form.row_of(field, Form.answer_of(answers, key)).error.is_empty() {
				return found
			}
			earlier = match found {
				Err(NoProblem) => True
				Ok(previous) => field.place < previous.place or (field.place == previous.place and key < previous.key)
			}
			if (earlier) Ok({ key, place: field.place }) else found
		},
	)
	match first {
		Err(NoProblem) => NoProblem
		Ok(problem) => FirstProblem(problem.key)
	}
}

## A problem follows the form's order, including a tie broken by key;
## valid answers and a form with no fields have no target to reveal.
expect {
	table = Table.from_list(Form.initial_fields)
	reordered = table.update(1, |field| { ..field, place: 3 })
	tied = table.update(2, |field| { ..field, place: 1 })
	answered = Form.set_answer_text(Form.set_answer_text(Form.no_answers, 1, "Ada"), 2, "ada@example.com")
	{
		initial: first_problem_of(table, Form.no_answers),
		reordered: first_problem_of(reordered, Form.no_answers),
		tied: first_problem_of(tied, Form.no_answers),
		answered: first_problem_of(table, answered),
		empty: first_problem_of(Table.from_list([]), Form.no_answers),
	} == {
		initial: FirstProblem(1),
		reordered: FirstProblem(2),
		tied: FirstProblem(1),
		answered: NoProblem,
		empty: NoProblem,
	}
}

## A broken rule is a problem even for an optional field with no answer.
expect first_problem_of(Table.from_list([{ key: 3, row: Form.new_field(Form.select_kind, 3) }]), Form.no_answers) == FirstProblem(3)
