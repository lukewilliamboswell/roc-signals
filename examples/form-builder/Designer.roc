import pf.Engine exposing [Cell, Elem, Row, Signal, State]
import pf.Html
import Form
import Schema

## The field designer owns editing and deletion decisions over the cells
## it is handed. Each row keeps its Settings dialog's open state locally.
Designer := [].{

	## A deletion being considered, kept at page lifetime rather than in a row.
	Confirm :: [Idle, Deleting(U64)].{

		## Whether there is no field awaiting confirmation.
		is_idle : Confirm -> Bool
		is_idle = |choice| match choice {
			Idle => True
			Deleting(_) => False
		}
	}

	## No deletion has been requested.
	idle : Confirm
	idle = Idle

	## The schema and the two cells used by the page-level confirmation.
	Props(st) := {
		fields : Cell(st, Schema.Fields),
		confirm : Cell(st, Confirm),
		focus : Cell(st, Engine.Outbox(Str)),
	}

	## Ask before deleting a field; its definition is untouched until confirmed.
	requested : Cell(st, Confirm), U64 -> List(Engine.Write(st))
	requested = |confirm, key| [confirm.set(Deleting(key))]

	## Keep the field and dismiss its confirmation.
	kept : Cell(st, Confirm) -> List(Engine.Write(st))
	kept = |confirm| [confirm.set(Idle)]

	## Delete the chosen row, clear the pending choice and focus the toolbar
	## together, because the element that opened the dialog is about to leave.
	confirmed : Props(st), Confirm -> List(Engine.Write(st))
	confirmed = |props, choice| match choice {
		Idle => []
		Deleting(key) => Schema.deleted(props.fields, key).concat([
			props.confirm.set(Idle),
			props.focus.update(|box| box.post("add-text-field")),
		])
	}

	## One editor per field and a confirmation that survives deleting a row.
	view : Props(st) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props| Html.section(
		"Field designer",
		"panel",
		[
			Engine.on_post(props.focus.signal(), |name| [Engine.command(Focus(name))], Engine.ignore({})),
			Html.div("panel-head", [Html.h2("Field designer", "panel-title"), Html.p("Definition", "hint")]),
			Html.div(
				"panel-body",
				[
					Engine.when(
						Schema.has_fields(props.fields),
						# Keep the template as a lambda (roc-lang/roc#12970).
						|| Schema.each_field(props.fields, |key, field| editor(props, { key, field })),
						|| Html.div("empty-state", [Html.p_attrs("No fields yet. Add a field to start designing.", [])]),
					),
				],
			),
			Html.dialog(
				"Confirm delete",
				{
					open: props.confirm.signal().map(|choice| !choice.is_idle()),
					on_close: Engine.handle(|open| if (open) [] else Designer.kept(props.confirm)),
				},
				[Engine.test_id("confirm-delete"), Engine.class("panel w-full max-w-md p-5")],
				[
					Html.div(
						"grid gap-4",
						[
							Html.h2("Delete field?", "panel-title"),
							Html.p_s(
								props.confirm.signal().map(
									|choice| match choice {
										Idle => ""
										Deleting(key) => "Delete field ${Form.id_of(key)}? Its definition will be removed."
									},
								),
								[],
							),
							Html.div(
								"flex justify-end gap-2",
								[
									Html.button("Keep", [Engine.class("button"), Engine.attr("autofocus", "true")], Engine.does(Designer.kept(props.confirm))),
									Html.button("Delete", [Engine.class("button-danger")], Engine.handle_by(props.confirm.signal(), |choice, _event| Designer.confirmed(props, choice))),
								],
							),
						],
					),
				],
			),
		],
	)
}

## Label editing stays inline; the rule controls live in a row-owned modal.
editor : Designer.Props(st), { key : Signal(Row(ctx, U64), U64), field : State(Row(ctx, U64), Form.Field) } -> Elem(Row(ctx, U64))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
editor = |props, { key, field }| {
	named = |prefix| key.map(|number| "${prefix} ${Form.id_of(number)}")
	defined = field.signal()
	move = |toward| Engine.handle_by(key, |number, _event| Schema.moved(props.fields, { key: number, toward }))
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
							Html.icon_button("✕", named("Delete"), "button-danger button-sm", Engine.handle_by(key, |number, _event| Designer.requested(props.confirm, number))),
						],
					),
				],
			),
			labelled("Label", Html.text_input(named("Label"), "text", defined.map(|now| now.label), [Engine.class("input"), Engine.attr("placeholder", "Work email")], field.set_value(Form.set_label))),
			Engine.state(
				False,
				|settings| {
					local_key = key.lift()
					local_field = field.lift()
					local_name = |prefix| local_key.map(|number| "${prefix} ${Form.id_of(number)}")
					local_definition = local_field.signal()
					broken_rule = Html.aria_invalid(local_definition.map(|now| Form.rule_error(now) != ""))
					Html.div(
						"",
						[
							Html.button_s(local_name("Settings"), [Engine.class("button button-sm"), Engine.ref_s(local_key.map(|number| "settings-${Form.id_of(number)}"))], settings.update(|_open| True)),
							Html.dialog(
								"Field settings",
								{ open: settings.signal(), on_close: settings.set_value(|_open, showing| showing) },
								[Html.aria_label_s(local_name("Settings")), Engine.test_id_s(local_key.map(|number| "settings-${Form.id_of(number)}")), Engine.class("panel w-full max-w-md p-5")],
								[
									Html.div(
										"grid gap-4",
										[
											Html.p_s(local_name("Settings"), [Engine.class("panel-title")]),
											Html.div(
												"check-row",
												[
													Html.checkbox(local_name("Required"), local_definition.map(|now| now.required), [Engine.class("checkbox")], local_field.set_value(|now, checked| Form.set_required(now, checked == "true"))),
													Engine.text("Required"),
												],
											),
											Engine.when(
												local_definition.map(|now| Form.is_select(now.kind)),
												|| labelled("Options", Html.text_input(local_name("Options"), "text", local_definition.map(|now| now.options_text), [Engine.class("input"), Engine.attr("placeholder", "Small, Medium, Large"), broken_rule], local_field.set_value(Form.set_options))),
												|| Html.div(
													"grid gap-3 sm:grid-cols-2",
													[
														labelled("Minimum", Html.number_input(local_name("Minimum"), local_definition.map(|now| now.min_text), [Engine.class("input"), Engine.attr("placeholder", "2"), broken_rule], local_field.set_value(Form.set_min))),
														labelled("Maximum", Html.number_input(local_name("Maximum"), local_definition.map(|now| now.max_text), [Engine.class("input"), Engine.attr("placeholder", "40"), broken_rule], local_field.set_value(Form.set_max))),
													],
												),
											),
											Html.div(
												"flex justify-end gap-2",
												[
													Html.button("Delete", [Html.aria_label_s(local_name("Delete from settings")), Engine.class("button-danger")], Engine.handle_by(local_key, |number, _event| Designer.requested(props.confirm, number))),
													Html.button("Done", [Html.aria_label_s(local_name("Done")), Engine.class("button")], settings.update(|_open| False)),
												],
											),
										],
									),
								],
							),
						],
					)
				},
			),
		],
	)
}

## A control under its caption.
labelled : Str, Elem(ctx) -> Elem(ctx)
labelled = |caption, control| Html.div("field", [Html.p(caption, "field-label"), control])
