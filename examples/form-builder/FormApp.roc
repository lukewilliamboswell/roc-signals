import pf.Engine exposing [Comp, Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Form

## Form Builder on the Roc-owned engine: ported from the previous engine.
##
## Same graph as the original: two independent sources (the schema and the
## answers) plus a submission counter, each its own state layer. The join of
## schema x answers (`Form.rows_of`) is one memoised `derive` layer that the
## stats and the preview read. The designer and the preview are components:
## each sees only its prop and routes its actions outward through a sink.
FormApp := [].{
	C1 : In(Root, Form.Schema)
	C2 : In(C1, List(Form.Answer))
	C3 : In(C2, U64)
	C4 : In(C3, List(Form.Row))

	## Actions the designer component routes to the schema.
	FieldAct : [SetLabel(Str, Str), SetRequired(Str, Bool), SetMin(Str, Str), SetMax(Str, Str), SetOptions(Str, Str), MoveUp(Str), MoveDown(Str), Delete(Str)]

	apply_field : Form.Schema, FieldAct -> Form.Schema
	apply_field = |s, act| match act {
		SetLabel(k, v) => Form.set_label(s, k, v)
		SetRequired(k, v) => Form.set_required(s, k, v)
		SetMin(k, v) => Form.set_min(s, k, v)
		SetMax(k, v) => Form.set_max(s, k, v)
		SetOptions(k, v) => Form.set_options(s, k, v)
		MoveUp(k) => Form.move_up(s, k)
		MoveDown(k) => Form.move_down(s, k)
		Delete(k) => Form.delete_field(s, k)
	}

	## Actions the preview component routes to the answers or the counter.
	PrevAct : [SetText(Str, Str), SetFlag(Str, Bool), ClearAnswers, Submit]

	PreviewProp : { rows : List(Form.Row), has_fields : Bool, submittable : Bool }

	DC : Comp(List(Form.Field), FieldAct)
	PC : Comp(PreviewProp, PrevAct)

	## ------------------------------------------------------------------
	## Designer component.

	labelled : Str, Elem(ctx) -> Elem(ctx)
	labelled = |caption, control| Html.div("field", [Html.p(caption, "field-label"), control])

	empty_state : Str -> Elem(ctx)
	empty_state = |message| Html.div("empty-state", [Engine.element("p", [], [Engine.text(message)])])

	builder_row : State(DC, List(FieldAct)), RowRef(DC, Form.Field) -> Elem(Row(DC, Form.Field))
	builder_row = |out0, row| {
		out = out0.lift_row()
		key = row.key()
		named = |prefix| key.map(|k| "${prefix} ${k}")
		rule_broken = row.field(|f| Form.rule_error(f) != "")
		Html.section_v(
			named("Field"),
			"card gap-3",
			[
				Html.div(
					"flex flex-wrap items-start justify-between gap-2",
					[
						Html.div(
							"grid min-w-0 gap-1",
							[
								Html.div(
									"flex items-center gap-2",
									[
										Html.p_v(row.field(|f| Form.kind_title(f.kind)), [Engine.class_v(row.field(|f| Form.kind_badge_class(f.kind)))]),
										Html.p_v(row.field(|f| f.label), [Engine.class("card-title truncate")]),
									],
								),
								Html.p_v(row.field(Form.summary_text), [Engine.class_v(row.field(Form.summary_tone)), Engine.test_id_v(key.map(|k| "field-${k}-summary"))]),
							],
						),
						Html.div(
							"flex shrink-0 items-center gap-1",
							[
								Html.icon_button("↑", named("Move up"), "button button-sm", out.push_by(key, |k| MoveUp(k))),
								Html.icon_button("↓", named("Move down"), "button button-sm", out.push_by(key, |k| MoveDown(k))),
								Html.icon_button("✕", named("Delete"), "button-danger button-sm", out.push_by(key, |k| Delete(k))),
							],
						),
					],
				),
				FormApp.labelled("Label", Html.text_input(named("Label"), "text", row.field(|f| f.label), [Engine.class("input"), Engine.attr("placeholder", "Work email")], out.push_value_by(key, |k, v| SetLabel(k, v)))),
				Html.div(
					"check-row",
					[
						Html.checkbox(named("Required"), row.field(|f| f.required), [Engine.class("checkbox")], out.push_value_by(key, |k, v| SetRequired(k, v == "true"))),
						Engine.text("Required"),
					],
				),
				Engine.when(
					row.field(|f| Form.is_select(f.kind)),
					|| FormApp.labelled("Options", Html.text_input(named("Options"), "text", row.field(|f| f.options_text), [Engine.class("input"), Engine.attr("placeholder", "Small, Medium, Large"), Html.flag_maybe("aria-invalid", rule_broken)], out.push_value_by(key, |k, v| SetOptions(k, v)))),
					|| Html.div(
						"grid gap-3 sm:grid-cols-2",
						[
							FormApp.labelled("Minimum", Html.text_input(named("Minimum"), "number", row.field(|f| f.min_text), [Engine.class("input"), Engine.attr("placeholder", "2"), Html.flag_maybe("aria-invalid", rule_broken)], out.push_value_by(key, |k, v| SetMin(k, v)))),
							FormApp.labelled("Maximum", Html.text_input(named("Maximum"), "number", row.field(|f| f.max_text), [Engine.class("input"), Engine.attr("placeholder", "40"), Html.flag_maybe("aria-invalid", rule_broken)], out.push_value_by(key, |k, v| SetMax(k, v)))),
						],
					),
				),
			],
		)
	}

	designer : Val(DC, List(Form.Field)), State(DC, List(FieldAct)) -> Elem(DC)
	designer = |fields, out| Html.section(
		"Field designer",
		"panel",
		[
			Html.div("panel-head", [Html.h2("Field designer", "panel-title"), Html.p("Definition", "hint")]),
			Html.div(
				"panel-body",
				[
					Engine.when(
						fields.map(|l| !l.is_empty()),
						|| Engine.each(fields, |f| f.id, |row| FormApp.builder_row(out, row)),
						|| FormApp.empty_state("No fields yet. Add a field to start designing."),
					),
				],
			),
		],
	)

	## ------------------------------------------------------------------
	## Preview component.

	preview_row : State(PC, List(PrevAct)), RowRef(PC, Form.Row) -> Elem(Row(PC, Form.Row))
	preview_row = |out0, row| {
		out = out0.lift_row()
		key = row.key()
		named = |prefix| key.map(|k| "${prefix} ${k}")
		invalid = Html.flag_maybe("aria-invalid", row.field(|r| r.error != ""))
		text_value = row.field(|r| r.text)
		write_text = out.push_value_by(key, |k, v| SetText(k, v))
		Html.section_v(
			named("Preview field"),
			"field",
			[
				Html.p_v(row.field(|r| if (r.required) "${r.label} (required)" else r.label), [Engine.class("field-label"), Engine.test_id_v(key.map(|k| "preview-${k}-label"))]),
				Engine.when(
					row.field(|r| Form.is_checkbox(r.kind)),
					|| Html.div(
						"check-row",
						[
							Html.checkbox(named("Answer"), row.field(|r| r.flag), [Engine.class("checkbox"), invalid], out.push_value_by(key, |k, v| SetFlag(k, v == "true"))),
							Engine.text("Yes"),
						],
					),
					|| Engine.when(
						row.field(|r| Form.is_select(r.kind)),
						|| Html.select(
							named("Answer"),
							text_value,
							[Engine.class("input"), invalid],
							[
								Html.option("", "Choose..."),
								Engine.each(row.field(|r| r.options), |o| o, |opt| Html.option_v(opt.key())),
							],
							write_text,
						),
						|| Html.text_input(
							named("Answer"),
							"text",
							text_value,
							[Engine.class("input"), Engine.attr_v("placeholder", row.field(|r| if (Form.is_number(r.kind)) "42" else "Ada Lovelace")), invalid],
							write_text,
						),
					),
				),
				Html.p_v(row.field(Form.verdict_text), [Engine.class_v(row.field(Form.verdict_tone)), Engine.test_id_v(key.map(|k| "preview-${k}-verdict"))]),
			],
		)
	}

	preview : Val(PC, PreviewProp), State(PC, List(PrevAct)) -> Elem(PC)
	preview = |pp, out| {
		ready = pp.map(|p| p.submittable)
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
								Html.button("Clear preview answers", [Engine.attr("type", "button"), Engine.class("button-ghost")], out.push(ClearAnswers)),
							],
						),
					],
				),
				Html.div(
					"panel-body",
					[
						Engine.element(
							"form",
							[Engine.attr("aria-label", "Preview form"), Engine.class("grid gap-4")],
							[
								Engine.when(
									pp.map(|p| p.has_fields),
									|| Engine.each(pp.map(|p| p.rows), |r| r.id, |row| FormApp.preview_row(out, row)),
									|| FormApp.empty_state("No fields yet. The generated form is empty."),
								),
								Html.div(
									"flex justify-end border-t border-zinc-200 pt-4",
									[
										Engine.element(
											"button",
											[Engine.attr("type", "button"), Engine.class("button-primary"), Html.flag("disabled", ready.map(|ok| !ok)), Engine.on_click(out.push(Submit))],
											[Engine.text("Submit form")],
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

	## ------------------------------------------------------------------
	## Page.

	stat : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat = |caption, value, id| Html.div("stat", [Html.p(caption, "stat-label"), Html.p_v(value, [Engine.class("stat-value numeric"), Engine.test_id(id)])])

	route_prev : PrevAct -> [L([SetText(Str, Str), SetFlag(Str, Bool), ClearAnswers]), R({})]
	route_prev = |a| match a {
		SetText(k, v) => L(SetText(k, v))
		SetFlag(k, v) => L(SetFlag(k, v))
		ClearAnswers => L(ClearAnswers)
		Submit => R({})
	}

	apply_answer : List(Form.Answer), [SetText(Str, Str), SetFlag(Str, Bool), ClearAnswers] -> List(Form.Answer)
	apply_answer = |answers, act| match act {
		SetText(k, v) => Form.set_answer_text(answers, k, v)
		SetFlag(k, v) => Form.set_answer_flag(answers, k, v)
		ClearAnswers => Form.initial_answers
	}

	add_button : State(ctx, Form.Schema), Str, Form.Kind -> Elem(ctx)
	add_button = |schema, label, kind| Html.button(label, [Engine.class("button button-sm")], schema.update(|s| Form.add_field(s, kind)))

	page : State(C4, Form.Schema), State(C4, List(Form.Answer)), State(C4, U64), Val(C4, List(Form.Row)) -> Elem(C4)
	page = |schema, answers, submits, rows| {
		fields = schema.val().map(|s| s.fields)
		has_fields = fields.map(|l| !l.is_empty())
		submittable = has_fields.map2(rows, |any, rs| any and Form.all_valid(rs))
		Html.div(
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
						FormApp.stat("Fields", fields.map(|l| l.len().to_str()), "designer-status"),
						FormApp.stat("Valid answers", rows.map(|rs| Form.valid_count(rs).to_str()), "valid-answers"),
						FormApp.stat("Problems", rows.map(|rs| Form.problem_count(rs).to_str()), "preview-status"),
						FormApp.stat("Submissions", submits.val().map(|n| n.to_str()), "submissions-count"),
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
								FormApp.add_button(schema, "Add text field", Form.text_kind),
								FormApp.add_button(schema, "Add number field", Form.number_kind),
								FormApp.add_button(schema, "Add email field", Form.email_kind),
								FormApp.add_button(schema, "Add select field", Form.select_kind),
								FormApp.add_button(schema, "Add checkbox field", Form.checkbox_kind),
							],
						),
					],
				),
				Html.div(
					"grid gap-5 lg:grid-cols-2",
					[
						Engine.component(fields, Engine.sink(schema, FormApp.apply_field), FormApp.designer),
						Engine.component(
							Val.map2(rows, submittable.map2(has_fields, |ok, hf| { ok, hf }), |rs, { ok, hf }| { rows: rs, has_fields: hf, submittable: ok }),
							Engine.split(Engine.sink(answers, FormApp.apply_answer), Engine.sink(submits, |n, _| n + 1), FormApp.route_prev),
							FormApp.preview,
						),
					],
				),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program(|| FormApp.main({}))

	main : {} -> Elem(Root)
	main = |_| FormApp.main_with(Form.initial_schema)

	main_with : Form.Schema -> Elem(Root)
	main_with = |schema0| Engine.state(
		schema0,
		|schema| Engine.state(
			Form.initial_answers,
			|answers| Engine.state(
				0,
				|submits| {
					sc = schema.lift().lift()
					an = answers.lift()
					rows = Val.map2(sc.val(), an.val(), |s, a| Form.rows_of(s.fields, a))
					Engine.derive(rows, |rows_v| FormApp.page(sc.lift(), an.lift(), submits.lift(), rows_v))
				},
			),
		),
	)
}
