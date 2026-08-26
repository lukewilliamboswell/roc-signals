## Form Builder — a designer for a form, next to a live preview of the form it
## generates.
##
## The example exists to show signals composing across *two levels*:
##
##   level 1  the designer's schema      (`schema : Ui.State(Form.Schema)`)
##   level 2  the answers typed into the generated form
##            (`answers : Ui.State(List(Form.Answer))`)
##
## Those two sources are independent. Everything the preview shows — each
## field's control, each field's error message, and the single "is this form
## submittable" flag — is *derived* from the pair. No event handler ever writes
## an error, a validity flag, or a copy of a field label.
##
## The graph, top to bottom:
##
##     schema.signal() ─map─> fields ─┐
##                                    ├─map2─> preview_rows ─┬─map─> all_valid ─┐
##     answers.signal() ──────────────┘                      │                  ├─map2─> submittable
##                                    ┌─────────────────map──┴─> status_text    │
##     fields ─map─> has_fields ──────────────────────────────────────────────-─┘
##                                                             submittable ─map─> submit_disabled
##
## `preview_rows` is the cross-level fan-in: two independent `Ui.state` handles
## meeting in one `Signal.map2`. `submittable` is the second fan-in, joining
## "the designer produced at least one field" with "every generated field is
## currently valid". The longest chain is four hops:
## `answers -> preview_rows -> all_valid -> submittable -> submit_disabled`.
app [main] { pf: platform "../../platform/main.roc" }

import Form
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

row_class = "panel grid gap-3 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

controls_class = "flex flex-wrap items-center gap-3"

heading_class = "text-lg font-semibold text-zinc-950"

hint_class = "text-sm text-zinc-600"

## One row of the designer: the controls that edit a single field definition.
##
## The row reads the field through the keyed-list item signal and writes back
## into the *parent* schema handle, so the row itself owns no state.
render_builder_row : Ui.State(Form.Schema), Str, Signal.Signal(Form.Field) -> Elem
render_builder_row = |schema, key, field| {
	summary : Signal.Signal(Str)
	summary = field.map(Form.summary_text)
	label_value : Signal.Signal(Str)
	label_value = field.map(|value| value.label)
	required_value : Signal.Signal(Bool)
	required_value = field.map(|value| value.required)
	min_value : Signal.Signal(Str)
	min_value = field.map(|value| value.min_text)
	max_value : Signal.Signal(Str)
	max_value = field.map(|value| value.max_text)
	options_value : Signal.Signal(Str)
	options_value = field.map(|value| value.options_text)
	select_field : Signal.Signal(Bool)
	select_field = field.map(|value| Form.is_select(value.kind))
	rule_broken : Signal.Signal(Bool)
	rule_broken = field.map(|value| Form.rule_error(value) != "")

	Html.section_c(
		"Field ${key}",
		row_class,
		[
			Html.paragraph_s_attrs(summary, [Html.class_attr(hint_class), Html.test_id("field-${key}-summary")]),
			Html.text_input_attrs(
				"Label ${key}",
				label_value,
				[Html.attr("data-field", key)],
				schema.on_str(|state, value| Form.set_label(state, key, value)),
			),
			Html.checkbox(
				"Required ${key}",
				required_value,
				schema.on_bool(|state, value| Form.set_required(state, key, value)),
			),
			Ui.when(
				select_field,
				|| Html.text_input_attrs(
					"Options ${key}",
					options_value,
					[Html.aria_invalid_s(rule_broken)],
					schema.on_str(|state, value| Form.set_options(state, key, value)),
				),
				|| Html.div_c(
					controls_class,
					[
						Html.number_input_attrs(
							"Minimum ${key}",
							min_value,
							[Html.aria_invalid_s(rule_broken)],
							schema.on_str(|state, value| Form.set_min(state, key, value)),
						),
						Html.number_input_attrs(
							"Maximum ${key}",
							max_value,
							[Html.aria_invalid_s(rule_broken)],
							schema.on_str(|state, value| Form.set_max(state, key, value)),
						),
					],
				),
			),
			Html.div_c(
				controls_class,
				[
					Html.button_c("Move up ${key}", "button", schema.on_unit(|state| Form.move_up(state, key))),
					Html.button_c("Move down ${key}", "button", schema.on_unit(|state| Form.move_down(state, key))),
					Html.button_c("Delete ${key}", "button", schema.on_unit(|state| Form.delete_field(state, key))),
				],
			),
		],
	)
}

## One row of the generated form.
##
## The row's value is held in the parent `answers` handle rather than in
## row-local `Ui.state`, for two reasons: the submittable signal has to be able
## to see every answer, and row-local `Ui.state` combined with reading the
## keyed-list item signal aborts the host on this platform build with
## "text read extension capability did not match its signal value".
render_preview_row : Ui.State(List(Form.Answer)), Str, Signal.Signal(Form.Row) -> Elem
render_preview_row = |answers, key, row| {
	label_text : Signal.Signal(Str)
	label_text =
		row.map(
			|value| if value.required { "${value.label} (required)" } else { value.label },
		)
	verdict : Signal.Signal(Str)
	verdict = row.map(Form.verdict_text)
	invalid : Signal.Signal(Bool)
	invalid = row.map(|value| value.error != "")
	text_value : Signal.Signal(Str)
	text_value = row.map(|value| value.text)
	flag_value : Signal.Signal(Bool)
	flag_value = row.map(|value| value.flag)
	options : Signal.Signal(List(Str))
	options = row.map(|value| value.options)
	checkbox_field : Signal.Signal(Bool)
	checkbox_field = row.map(|value| Form.is_checkbox(value.kind))
	select_field : Signal.Signal(Bool)
	select_field = row.map(|value| Form.is_select(value.kind))
	number_field : Signal.Signal(Bool)
	number_field = row.map(|value| Form.is_number(value.kind))

	write_text = answers.on_str(|state, value| Form.set_answer_text(state, key, value))

	Html.section_c(
		"Preview field ${key}",
		row_class,
		[
			Html.paragraph_s_attrs(label_text, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("preview-${key}-label")]),
			Ui.when(
				checkbox_field,
				|| Html.checkbox_attrs(
					"Answer ${key}",
					flag_value,
					[Html.aria_invalid_s(invalid)],
					answers.on_bool(|state, value| Form.set_answer_flag(state, key, value)),
				),
				|| Ui.when(
					select_field,
					|| Html.select_attrs(
						"Answer ${key}",
						text_value,
						[Html.aria_invalid_s(invalid)],
						[
							Html.option("", "Choose..."),
							Ui.each_str(options, |option| option, |option, _signal| Html.option(option, option)),
						],
						write_text,
					),
					|| Ui.when(
						number_field,
						|| Html.number_input_attrs(
							"Answer ${key}",
							text_value,
							[Html.aria_invalid_s(invalid)],
							write_text,
						),
						|| Html.text_input_attrs(
							"Answer ${key}",
							text_value,
							[Html.aria_invalid_s(invalid)],
							write_text,
						),
					),
				),
			),
			Html.paragraph_s_attrs(verdict, [Html.class_attr(hint_class), Html.test_id("preview-${key}-verdict")]),
		],
	)
}

designer_panel : Ui.State(Form.Schema), Signal.Signal(List(Form.Field)), Signal.Signal(Bool), Signal.Signal(Str) -> Elem
designer_panel = |schema, fields, has_fields, designer_status|
	Html.section_c(
		"Field designer",
		panel_class,
		[
			Html.heading_c("Field designer", heading_class),
			Html.paragraph_s_attrs(designer_status, [Html.class_attr(hint_class), Html.test_id("designer-status")]),
			Ui.when(
				has_fields,
				|| Ui.each_str(fields, |field| field.id, |key, field| render_builder_row(schema, key, field)),
				|| Html.paragraph_c("No fields yet. Add a field to start designing.", hint_class),
			),
		],
	)

preview_panel : Ui.State(List(Form.Answer)), Ui.State(U64), Signal.Signal(List(Form.Row)), Signal.Signal(Bool), Signal.Signal(Str), Signal.Signal(Bool), Signal.Signal(Str), Signal.Signal(Str) -> Elem
preview_panel = |answers, submits, rows, has_fields, preview_status, submit_disabled, submittable_text, submissions_text|
	Html.section_c(
		"Live preview",
		panel_class,
		[
			Html.heading_c("Live preview", heading_class),
			Html.paragraph_s_attrs(preview_status, [Html.class_attr(hint_class), Html.test_id("preview-status")]),
			Html.form_label(
				"Preview form",
				[Html.on_submit_prevent_default(submits.on_unit(|count| count))],
				[
					Ui.when(
						has_fields,
						|| Ui.each_str(rows, |row| row.id, |key, row| render_preview_row(answers, key, row)),
						|| Html.paragraph_c("No fields yet. The generated form is empty.", hint_class),
					),
					Html.paragraph_s_attrs(submittable_text, [Html.class_attr(hint_class), Html.test_id("submittable-state")]),
					Html.action_button_attrs(
						Signal.const("Submit form"),
						submit_disabled,
						[Html.attr("type", "button")],
						submits.on_unit(|count| count + 1),
					),
					Html.paragraph_s_attrs(submissions_text, [Html.class_attr(hint_class), Html.test_id("submissions-count")]),
				],
			),
		],
	)

main : () -> Elem
main = ||
	Ui.state(
		Form.initial_schema,
		|schema|
			Ui.state(
				Form.initial_answers,
				|answers|
					Ui.state(
						0,
						|submits| {
							# ---- level 1: the designer's schema
							fields : Signal.Signal(List(Form.Field))
							fields = schema.signal().map(|state| state.fields)

							has_fields : Signal.Signal(Bool)
							has_fields = fields.map(|list| !list.is_empty())

							designer_status : Signal.Signal(Str)
							designer_status =
								fields.map(
									|list| {
										count = list.len()
										if count == 1 {
											"Designer status: 1 field"
										} else {
											"Designer status: ${count.to_str()} fields"
										}
									},
								)

							# ---- the cross-level join: schema x answers -> preview rows
							preview_rows : Signal.Signal(List(Form.Row))
							preview_rows = Signal.map2(fields, answers.signal(), Form.rows_of)

							preview_status : Signal.Signal(Str)
							preview_status = preview_rows.map(Form.status_text)

							all_valid : Signal.Signal(Bool)
							all_valid = preview_rows.map(Form.all_valid)

							# ---- level 2 fan-in: "has fields" AND "every field valid"
							submittable : Signal.Signal(Bool)
							submittable = Signal.map2(has_fields, all_valid, |any, valid| any and valid)

							submit_disabled : Signal.Signal(Bool)
							submit_disabled = submittable.map(|ok| !ok)

							submittable_text : Signal.Signal(Str)
							submittable_text =
								submittable.map(
									|ok| if ok { "Form is submittable" } else { "Form is not submittable" },
								)

							submissions_text : Signal.Signal(Str)
							submissions_text =
								submits.signal().map(|count| "Submissions: ${count.to_str()}")

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Form Builder",
										hero_class,
										[
											Html.heading_c("Form Builder", "text-3xl font-semibold text-zinc-950"),
											Html.paragraph_c(
												"Design a form on the left and answer the form it generates on the right. Field definitions and answers are two independent sources; every preview label, every validation message, and the submit button's disabled state are derived from both.",
												"max-w-3xl text-sm text-zinc-700",
											),
										],
									),
									Html.section_c(
										"Field toolbar",
										panel_class,
										[
											Html.heading_c("Add a field", heading_class),
											Html.div_c(
												toolbar_class,
												[
													Html.button_c("Add text field", "button-primary", schema.on_unit(|state| Form.add_field(state, Form.text_kind))),
													Html.button_c("Add number field", "button-primary", schema.on_unit(|state| Form.add_field(state, Form.number_kind))),
													Html.button_c("Add email field", "button-primary", schema.on_unit(|state| Form.add_field(state, Form.email_kind))),
													Html.button_c("Add select field", "button-primary", schema.on_unit(|state| Form.add_field(state, Form.select_kind))),
													Html.button_c("Add checkbox field", "button-primary", schema.on_unit(|state| Form.add_field(state, Form.checkbox_kind))),
													Html.button_c("Clear preview answers", "button", answers.on_unit(|_state| Form.initial_answers)),
												],
											),
										],
									),
									designer_panel(schema, fields, has_fields, designer_status),
									preview_panel(
										answers,
										submits,
										preview_rows,
										has_fields,
										preview_status,
										submit_disabled,
										submittable_text,
										submissions_text,
									),
								],
							)
						},
					),
			),
	)
