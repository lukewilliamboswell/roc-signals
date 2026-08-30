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
##                                    ┌─────────────────map──┴─> problem_count  │
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

# ---------------------------------------------------------------- domain tests
#
# These sit next to the pure functions the UI derives everything from, and they
# pin the exact strings the specs assert.

## An empty bound box means "no bound", which is distinct from a bound of zero.
expect Form.bound_of("") == NoBound

## Surrounding whitespace is trimmed before a bound is read.
expect Form.bound_of("  7 ") == HasBound(7)

## A leading minus sign is part of the number, so bounds can be negative.
expect Form.bound_of("-3") == HasBound(-3)

## Trailing non-digits reject the bound rather than parsing the leading digits.
expect Form.bound_of("2x") == BadBound

## A lone minus sign has no digits, so it is not a number.
expect Form.bound_of("-") == BadBound

## A leading plus is outside the rule syntax this example documents.
expect Form.bound_of("+5") == BadBound

## An empty options box yields no options at all, not one blank option.
expect Form.options_of("") == []

## Options are trimmed and empty entries between commas are discarded.
expect Form.options_of(" Small , Medium ,, Large ") == ["Small", "Medium", "Large"]

## Each field kind has a human-readable title used in headings and default labels.
expect Form.kind_title(Form.select_kind) == "Select"

## A field kind equals itself.
expect Form.text_kind.is_eq(Form.text_kind)

## Two different field kinds are never equal.
expect !Form.text_kind.is_eq(Form.email_kind)

sample_number_field : Form.Field
sample_number_field = {
	id: "f1",
	kind: Form.number_kind,
	label: "Age",
	required: True,
	min_text: "2",
	max_text: "10",
	options_text: "",
}

## A consistent min/max pair is not a rule error.
expect Form.rule_error(sample_number_field) == ""

## An unparseable minimum is reported against the minimum box by name.
expect Form.rule_error({ ..sample_number_field, min_text: "2x" }) == "Rule error: minimum is not a number"

## An unparseable maximum is reported against the maximum box by name.
expect Form.rule_error({ ..sample_number_field, max_text: "2x" }) == "Rule error: maximum is not a number"

## A minimum above the maximum is a rule no answer could ever satisfy.
expect Form.rule_error({ ..sample_number_field, min_text: "20" }) == "Rule error: minimum is greater than maximum"

## A number inside the configured range is accepted.
expect Form.answer_error(sample_number_field, "5", False) == ""

## A required field with no answer asks for one.
expect Form.answer_error(sample_number_field, "", False) == "This field is required"

## A number field rejects text that is not a whole number.
expect Form.answer_error(sample_number_field, "x", False) == "Enter a whole number"

## A number below the minimum names the minimum it fell short of.
expect Form.answer_error(sample_number_field, "1", False) == "Must be at least 2"

## A number above the maximum names the maximum it exceeded.
expect Form.answer_error(sample_number_field, "11", False) == "Must be at most 10"

sample_text_field : Form.Field
sample_text_field = { ..sample_number_field, kind: Form.text_kind, min_text: "2", max_text: "4" }

## On a text field the same bounds measure length, so the message says characters.
expect Form.answer_error(sample_text_field, "a", False) == "Must be at least 2 characters"

## Text longer than the maximum is reported in characters too.
expect Form.answer_error(sample_text_field, "abcde", False) == "Must be at most 4 characters"

## Text whose length sits inside the bounds is accepted.
expect Form.answer_error(sample_text_field, "abc", False) == ""

## Writing an answer for a field with no entry yet adds one that reads back.
expect Form.answer_text(Form.set_answer_text([], "f1", "hi"), "f1") == "hi"

## A field with no answer entry reads as empty rather than failing.
expect Form.answer_text([], "f1") == ""

## Checking a box for a field with no entry yet records the flag.
expect Form.answer_flag(Form.set_answer_flag([], "f1", True), "f1")

page_class = "app-shell app-shell-wide"

panel_class = "panel"

hint_class = "hint"

## The builder and the preview sit side by side on a wide screen: seeing the
## definition next to the thing it generates is the whole point of the example.
panes_class = "grid gap-5 lg:grid-cols-2"

## A metric tile. Every number in this app is a label and a figure, never a
## sentence, so the specs address the figure itself.
stat : Str, Signal.Signal(Str), Str -> Elem
stat = |caption, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(caption, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value numeric"), Html.test_id(id)]),
		],
	)

## A labelled control. The control's first argument is only its *accessible*
## name (and the handle the specs address it by), so the visible caption has to
## be drawn separately.
labelled : Str, Elem -> Elem
labelled = |caption, control|
	Html.div_c("field", [Html.paragraph_c(caption, "field-label"), control])

## The dashed box a list shows instead of rendering nothing.
empty_state : Str -> Elem
empty_state = |message| Html.div_c("empty-state", [Html.paragraph(message)])

## A compact secondary control in a builder row. The visible text is a glyph so
## three of them fit on one line, and `aria_label` keeps the descriptive name
## for assistive tech and for the specs.
row_button : Str, Str, Str, _ -> Elem
row_button = |glyph, name, classes, msg|
	Html.button_attrs(glyph, [Html.aria_label(name), Html.attr("type", "button"), Html.class_attr(classes)], msg)

## One row of the designer: the controls that edit a single field definition.
##
## The row reads the field through the keyed-list item signal and writes back
## into the *parent* schema handle, so the row itself owns no state.
render_builder_row : Ui.State(Form.Schema), Str, Signal.Signal(Form.Field) -> Elem
render_builder_row = |schema, key, field| {
	summary : Signal.Signal(Str)
	summary = field.map(Form.summary_text)
	summary_tone : Signal.Signal(Str)
	summary_tone = field.map(Form.summary_tone)
	kind_name : Signal.Signal(Str)
	kind_name = field.map(|value| Form.kind_title(value.kind))
	kind_class : Signal.Signal(Str)
	kind_class = field.map(|value| Form.kind_badge_class(value.kind))
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
		"card gap-3",
		[
			Html.div_c(
				"flex flex-wrap items-start justify-between gap-2",
				[
					Html.div_c(
						"grid min-w-0 gap-1",
						[
							Html.div_c(
								"flex items-center gap-2",
								[
									Html.paragraph_s_attrs(kind_name, [Html.class_attr_s(kind_class)]),
									Html.paragraph_s_attrs(label_value, [Html.class_attr("card-title truncate")]),
								],
							),
							Html.paragraph_s_attrs(
								summary,
								[Html.class_attr_s(summary_tone), Html.test_id("field-${key}-summary")],
							),
						],
					),
					Html.div_c(
						"flex shrink-0 items-center gap-1",
						[
							row_button("↑", "Move up ${key}", "button button-sm", schema.on_unit(|state| Form.move_up(state, key))),
							row_button("↓", "Move down ${key}", "button button-sm", schema.on_unit(|state| Form.move_down(state, key))),
							row_button("✕", "Delete ${key}", "button-danger button-sm", schema.on_unit(|state| Form.delete_field(state, key))),
						],
					),
				],
			),
			labelled(
				"Label",
				Html.text_input_attrs(
					"Label ${key}",
					label_value,
					[Html.class_attr("input"), Html.attr("placeholder", "Work email"), Html.attr("data-field", key)],
					schema.on_str(|state, value| Form.set_label(state, key, value)),
				),
			),
			Html.div_c(
				"check-row",
				[
					Html.checkbox_c(
						"Required ${key}",
						required_value,
						"checkbox",
						schema.on_bool(|state, value| Form.set_required(state, key, value)),
					),
					Html.text("Required"),
				],
			),
			Ui.when(
				select_field,
				|| labelled(
					"Options",
					Html.text_input_attrs(
						"Options ${key}",
						options_value,
						[Html.class_attr("input"), Html.attr("placeholder", "Small, Medium, Large"), Html.aria_invalid_s(rule_broken)],
						schema.on_str(|state, value| Form.set_options(state, key, value)),
					),
				),
				|| Html.div_c(
					"grid gap-3 sm:grid-cols-2",
					[
						labelled(
							"Minimum",
							Html.number_input_attrs(
								"Minimum ${key}",
								min_value,
								[Html.class_attr("input"), Html.attr("placeholder", "2"), Html.aria_invalid_s(rule_broken)],
								schema.on_str(|state, value| Form.set_min(state, key, value)),
							),
						),
						labelled(
							"Maximum",
							Html.number_input_attrs(
								"Maximum ${key}",
								max_value,
								[Html.class_attr("input"), Html.attr("placeholder", "40"), Html.aria_invalid_s(rule_broken)],
								schema.on_str(|state, value| Form.set_max(state, key, value)),
							),
						),
					],
				),
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
	verdict_tone : Signal.Signal(Str)
	verdict_tone = row.map(Form.verdict_tone)
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
		"field",
		[
			Html.paragraph_s_attrs(label_text, [Html.class_attr("field-label"), Html.test_id("preview-${key}-label")]),
			Ui.when(
				checkbox_field,
				|| Html.div_c(
					"check-row",
					[
						Html.checkbox_attrs(
							"Answer ${key}",
							flag_value,
							[Html.class_attr("checkbox"), Html.aria_invalid_s(invalid)],
							answers.on_bool(|state, value| Form.set_answer_flag(state, key, value)),
						),
						Html.text("Yes"),
					],
				),
				|| Ui.when(
					select_field,
					|| Html.select_attrs(
						"Answer ${key}",
						text_value,
						[Html.class_attr("input"), Html.aria_invalid_s(invalid)],
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
							[Html.class_attr("input"), Html.attr("placeholder", "42"), Html.aria_invalid_s(invalid)],
							write_text,
						),
						|| Html.text_input_attrs(
							"Answer ${key}",
							text_value,
							[Html.class_attr("input"), Html.attr("placeholder", "Ada Lovelace"), Html.aria_invalid_s(invalid)],
							write_text,
						),
					),
				),
			),
			Html.paragraph_s_attrs(verdict, [Html.class_attr_s(verdict_tone), Html.test_id("preview-${key}-verdict")]),
		],
	)
}

designer_panel : Ui.State(Form.Schema), Signal.Signal(List(Form.Field)), Signal.Signal(Bool) -> Elem
designer_panel = |schema, fields, has_fields|
	Html.section_c(
		"Field designer",
		panel_class,
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Field designer", "panel-title"),
					Html.paragraph_c("Definition", hint_class),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Ui.when(
						has_fields,
						|| Ui.each_str(fields, |field| field.id, |key, field| render_builder_row(schema, key, field)),
						|| empty_state("No fields yet. Add a field to start designing."),
					),
				],
			),
		],
	)

## Everything the preview pane reads, in one record.
##
## The pane needs two independent `Bool` signals and two independent `Str`
## signals; as positional arguments those four are indistinguishable at the call
## site, and transposing a pair would type-check and render nonsense.
PreviewView : {
	rows : Signal.Signal(List(Form.Row)),
	has_fields : Signal.Signal(Bool),
	submit_disabled : Signal.Signal(Bool),
	submittable_text : Signal.Signal(Str),
	submittable_class : Signal.Signal(Str),
}

preview_panel : Ui.State(List(Form.Answer)), Ui.State(U64), PreviewView -> Elem
preview_panel = |answers, submits, view|
	Html.section_c(
		"Live preview",
		panel_class,
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Live preview", "panel-title"),
					Html.div_c(
						"flex items-center gap-2",
						[
							Html.paragraph_s_attrs(
								view.submittable_text,
								[Html.class_attr_s(view.submittable_class), Html.test_id("submittable-state")],
							),
							Html.button_attrs(
								"Clear preview answers",
								[Html.attr("type", "button"), Html.class_attr("button-ghost")],
								answers.on_unit(|_state| Form.initial_answers),
							),
						],
					),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.form_label(
						"Preview form",
						[Html.class_attr("grid gap-4"), Html.on_submit_prevent_default(submits.on_unit(|count| count))],
						[
							Ui.when(
								view.has_fields,
								|| Ui.each_str(view.rows, |row| row.id, |key, row| render_preview_row(answers, key, row)),
								|| empty_state("No fields yet. The generated form is empty."),
							),
							Html.div_c(
								"flex justify-end border-t border-zinc-200 pt-4",
								[
									Html.action_button_attrs(
										Signal.const("Submit form"),
										view.submit_disabled,
										[Html.attr("type", "button"), Html.class_attr("button-primary")],
										submits.on_unit(|count| count + 1),
									),
								],
							),
						],
					),
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

							field_count : Signal.Signal(Str)
							field_count = fields.map(|list| list.len().to_str())

							# ---- the cross-level join: schema x answers -> preview rows
							preview_rows : Signal.Signal(List(Form.Row))
							preview_rows = Signal.map2(fields, answers.signal(), Form.rows_of)

							problem_count : Signal.Signal(Str)
							problem_count = preview_rows.map(|rows| Form.problem_count(rows).to_str())

							valid_count : Signal.Signal(Str)
							valid_count = preview_rows.map(|rows| Form.valid_count(rows).to_str())

							all_valid : Signal.Signal(Bool)
							all_valid = preview_rows.map(Form.all_valid)

							# ---- level 2 fan-in: "has fields" AND "every field valid"
							submittable : Signal.Signal(Bool)
							submittable = Signal.map2(has_fields, all_valid, |any, valid| any and valid)

							submit_disabled : Signal.Signal(Bool)
							submit_disabled = submittable.map(|ok| !ok)

							# The badge's caption and its colour come off the same signal, so
							# it can never say "Ready to submit" in the warning tone.
							submittable_text : Signal.Signal(Str)
							submittable_text =
								submittable.map(|ok| if ok { "Ready to submit" } else { "Not ready" })

							submittable_class : Signal.Signal(Str)
							submittable_class =
								submittable.map(|ok| if ok { "badge badge-ok" } else { "badge badge-warn" })

							submissions_text : Signal.Signal(Str)
							submissions_text = submits.signal().map(|count| count.to_str())

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Form Builder",
										"app-header",
										[
											Html.heading_c("Form Builder", "app-title"),
											Html.paragraph_c(
												"Design a form on the left and answer the form it generates on the right. Field definitions and answers are two independent sources; every preview label, every validation message, and the submit button's disabled state are derived from both.",
												"app-subtitle",
											),
										],
									),
									Html.div_c(
										"stat-grid",
										[
											stat("Fields", field_count, "designer-status"),
											stat("Valid answers", valid_count, "valid-answers"),
											stat("Problems", problem_count, "preview-status"),
											stat("Submissions", submissions_text, "submissions-count"),
										],
									),
									Html.section_c(
										"Field toolbar",
										"panel grid gap-3 p-4",
										[
											Html.heading_c("Add a field", "panel-title"),
											Html.div_c(
												"toolbar",
												[
													Html.button_c("Add text field", "button button-sm", schema.on_unit(|state| Form.add_field(state, Form.text_kind))),
													Html.button_c("Add number field", "button button-sm", schema.on_unit(|state| Form.add_field(state, Form.number_kind))),
													Html.button_c("Add email field", "button button-sm", schema.on_unit(|state| Form.add_field(state, Form.email_kind))),
													Html.button_c("Add select field", "button button-sm", schema.on_unit(|state| Form.add_field(state, Form.select_kind))),
													Html.button_c("Add checkbox field", "button button-sm", schema.on_unit(|state| Form.add_field(state, Form.checkbox_kind))),
												],
											),
										],
									),
									Html.div_c(
										panes_class,
										[
											designer_panel(schema, fields, has_fields),
											preview_panel(
												answers,
												submits,
												{
													rows: preview_rows,
													has_fields,
													submit_disabled,
													submittable_text,
													submittable_class,
												},
											),
										],
									),
								],
							)
						},
					),
			),
	)
