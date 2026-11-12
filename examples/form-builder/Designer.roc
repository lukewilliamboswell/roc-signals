import pf.Engine exposing [Cell, Elem, Row, Signal, State]
import pf.Html
import Form
import Schema

## The field designer: one editor for each field of the form, in the
## form's order.
##
## It is drawn over the fields' cell of whichever store holds it, and that
## cell is all it is handed, so it can change a definition and never an
## answer. Each editor is a row of a view of the fields' table: a keystroke
## in one field's label writes that row, and wakes that field's editor and
## its preview and no other.
Designer := [].{

	## The designer, over the form's fields.
	view : Cell(st, Schema.Fields) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |fields| Html.section(
		"Field designer",
		"panel",
		[
			Html.div("panel-head", [Html.h2("Field designer", "panel-title"), Html.p("Definition", "hint")]),
			Html.div(
				"panel-body",
				[
					Engine.when(
						Schema.has_fields(fields),
						# The template is a lambda here, not the result of a
						# helper that returns one (roc-lang/roc#12970).
						|| Schema.each_field(fields, |key, field| editor(fields, key, field)),
						|| Html.div("empty-state", [Html.p_attrs("No fields yet. Add a field to start designing.", [])]),
					),
				],
			),
		],
	)
}

## One field's editor: its kind and label, a note on its rule, and controls
## for its label, whether it is required, and its bounds or its options.
##
## An edit of the definition is a write of the row itself. A move and a
## delete change more than this field's row, so each is a transition over
## the fields' cell (`Schema`).
editor : Cell(st, Schema.Fields), Signal(Row(ctx, U64), U64), State(Row(ctx, U64), Form.Field) -> Elem(Row(ctx, U64))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
editor = |fields, key, field| {
	named = |prefix| key.map(|number| "${prefix} ${Form.id_of(number)}")
	defined = field.signal()
	rule_broken = Html.aria_invalid(defined.map(|now| Form.rule_error(now) != ""))
	move = |toward| Engine.handle_by(key, |number, _| Schema.moved(fields, { key: number, toward }))
	Html.section_s(
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
									Html.p_s(defined.map(|now| Form.kind_title(now.kind)), [Engine.class_s(defined.map(|now| Form.kind_badge_class(now.kind)))]),
									Html.p_s(defined.map(|now| now.label), [Engine.class("card-title truncate")]),
								],
							),
							Html.p_s(defined.map(Form.summary_text), [Engine.class_s(defined.map(Form.summary_tone)), Engine.test_id_s(key.map(|number| "field-${Form.id_of(number)}-summary"))]),
						],
					),
					Html.div(
						"flex shrink-0 items-center gap-1",
						[
							Html.icon_button("↑", named("Move up"), "button button-sm", move(Earlier)),
							Html.icon_button("↓", named("Move down"), "button button-sm", move(Later)),
							Html.icon_button("✕", named("Delete"), "button-danger button-sm", Engine.handle_by(key, |number, _| Schema.deleted(fields, number))),
						],
					),
				],
			),
			labelled("Label", Html.text_input(named("Label"), "text", defined.map(|now| now.label), [Engine.class("input"), Engine.attr("placeholder", "Work email")], field.set_value(Form.set_label))),
			Html.div(
				"check-row",
				[
					Html.checkbox(named("Required"), defined.map(|now| now.required), [Engine.class("checkbox")], field.set_value(|now, checked| Form.set_required(now, checked == "true"))),
					Engine.text("Required"),
				],
			),
			Engine.when(
				defined.map(|now| Form.is_select(now.kind)),
				|| labelled("Options", Html.text_input(named("Options"), "text", defined.map(|now| now.options_text), [Engine.class("input"), Engine.attr("placeholder", "Small, Medium, Large"), rule_broken], field.set_value(Form.set_options))),
				|| Html.div(
					"grid gap-3 sm:grid-cols-2",
					[
						labelled("Minimum", Html.number_input(named("Minimum"), defined.map(|now| now.min_text), [Engine.class("input"), Engine.attr("placeholder", "2"), rule_broken], field.set_value(Form.set_min))),
						labelled("Maximum", Html.number_input(named("Maximum"), defined.map(|now| now.max_text), [Engine.class("input"), Engine.attr("placeholder", "40"), rule_broken], field.set_value(Form.set_max))),
					],
				),
			),
		],
	)
}

## A control under its caption.
labelled : Str, Elem(ctx) -> Elem(ctx)
labelled = |caption, control| Html.div("field", [Html.p(caption, "field-label"), control])
