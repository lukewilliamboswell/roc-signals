app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

label_i64 : Str, I64 -> Str
label_i64 = |name, value| "${name}: ${value.to_str()}"

step_label : I64 -> Str
step_label = |step|
	if step == 0 {
		"Step 1 - Cart"
	} else if step == 1 {
		"Step 2 - Delivery"
	} else {
		"Step 3 - Review"
	}

step_attr_value : I64 -> Str
step_attr_value = |step|
	if step == 0 {
		"cart"
	} else if step == 1 {
		"delivery"
	} else {
		"review"
	}

next_step : I64 -> I64
next_step = |step| {
	next = step + 1
	if next > 2 {
		2
	} else {
		next
	}
}

prev_step : I64 -> I64
prev_step = |step| {
	next = step - 1
	if next < 0 {
		0
	} else {
		next
	}
}

Plan := [Team, Basic].{
	is_eq : Plan, Plan -> Bool
	is_eq = |left, right|
		match left {
			Team => match right {
				Team => True
				Basic => False
			}
			Basic => match right {
				Team => False
				Basic => True
			}
		}
}

TextDraft := [TextUntouched, TextChanged(Str)].{
	is_eq : TextDraft, TextDraft -> Bool
	is_eq = |left, right|
		match left {
			TextUntouched => match right {
				TextUntouched => True
				TextChanged(_) => False
			}
			TextChanged(left_value) => match right {
				TextUntouched => False
				TextChanged(right_value) => left_value == right_value
			}
		}
}

BoolDraft := [BoolUntouched, BoolChanged(Bool)].{
	is_eq : BoolDraft, BoolDraft -> Bool
	is_eq = |left, right|
		match left {
			BoolUntouched => match right {
				BoolUntouched => True
				BoolChanged(_) => False
			}
			BoolChanged(left_value) => match right {
				BoolUntouched => False
				BoolChanged(right_value) => left_value == right_value
			}
		}
}

I64Draft := [I64Untouched, I64Changed(I64)].{
	is_eq : I64Draft, I64Draft -> Bool
	is_eq = |left, right|
		match left {
			I64Untouched => match right {
				I64Untouched => True
				I64Changed(_) => False
			}
			I64Changed(left_value) => match right {
				I64Untouched => False
				I64Changed(right_value) => left_value == right_value
			}
		}
}

PlanDraft := [PlanUntouched, PlanChanged(Plan)].{
	is_eq : PlanDraft, PlanDraft -> Bool
	is_eq = |left, right|
		match left {
			PlanUntouched => match right {
				PlanUntouched => True
				PlanChanged(_) => False
			}
			PlanChanged(left_value) => match right {
				PlanUntouched => False
				PlanChanged(right_value) => left_value.is_eq(right_value)
			}
		}
}

team_button_class : Plan -> Str
team_button_class = |plan|
	match plan {
		Plan.Team => "button-primary"
		Plan.Basic => "button"
	}

basic_button_class : Plan -> Str
basic_button_class = |plan|
	match plan {
		Plan.Team => "button"
		Plan.Basic => "button-primary"
	}

team_pressed : Plan -> Str
team_pressed = |plan|
	match plan {
		Plan.Team => "true"
		Plan.Basic => "false"
	}

basic_pressed : Plan -> Str
basic_pressed = |plan|
	match plan {
		Plan.Team => "false"
		Plan.Basic => "true"
	}

encode_plan : Plan -> Str
encode_plan = |plan|
	match plan {
		Plan.Team => "team"
		Plan.Basic => "basic"
	}

decode_plan : Str -> Plan
decode_plan = |value|
	if value == "basic" {
		Plan.Basic
	} else {
		Plan.Team
	}

decode_bool : Str -> Bool
decode_bool = |value| value == "true"

decode_i64 : I64, Str -> I64
decode_i64 = |fallback, value| {
	if value == "0" {
		0
	} else if value == "1" {
		1
	} else if value == "2" {
		2
	} else if value == "3" {
		3
	} else if value == "4" {
		4
	} else if value == "5" {
		5
	} else if value == "6" {
		6
	} else if value == "7" {
		7
	} else if value == "8" {
		8
	} else if value == "9" {
		9
	} else {
		fallback
	}
}

stored_text : Str, Browser.StorageText -> Str
stored_text = |fallback, stored|
	match stored {
		StorageValue(value) => value
		_ => fallback
	}

stored_bool : Bool, Browser.StorageText -> Bool
stored_bool = |fallback, stored|
	match stored {
		StorageValue(value) => decode_bool(value)
		_ => fallback
	}

stored_i64 : I64, Browser.StorageText -> I64
stored_i64 = |fallback, stored|
	match stored {
		StorageValue(value) => decode_i64(fallback, value)
		_ => fallback
	}

stored_plan : Plan, Browser.StorageText -> Plan
stored_plan = |fallback, stored|
	match stored {
		StorageValue(value) => decode_plan(value)
		_ => fallback
	}

encode_bool : Bool -> Str
encode_bool = |value|
	if value {
		"true"
	} else {
		"false"
	}

draft_text_value : Str, TextDraft, Browser.StorageText -> Str
draft_text_value = |fallback, draft, stored|
	match draft {
		TextChanged(value) => value
		TextUntouched => stored_text(fallback, stored)
	}

draft_bool_value : Bool, BoolDraft, Browser.StorageText -> Bool
draft_bool_value = |fallback, draft, stored|
	match draft {
		BoolChanged(value) => value
		BoolUntouched => stored_bool(fallback, stored)
	}

draft_i64_value : I64, I64Draft, Browser.StorageText -> I64
draft_i64_value = |fallback, draft, stored|
	match draft {
		I64Changed(value) => value
		I64Untouched => stored_i64(fallback, stored)
	}

draft_plan_value : Plan, PlanDraft, Browser.StorageText -> Plan
draft_plan_value = |fallback, draft, stored|
	match draft {
		PlanChanged(value) => value
		PlanUntouched => stored_plan(fallback, stored)
	}

draft_text_signal : Str, Signal.Signal(TextDraft), Signal.Signal(Browser.StorageText) -> Signal.Signal(Str)
draft_text_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_text_value(fallback, value.draft, value.stored))
}

draft_bool_signal : Bool, Signal.Signal(BoolDraft), Signal.Signal(Browser.StorageText) -> Signal.Signal(Bool)
draft_bool_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_bool_value(fallback, value.draft, value.stored))
}

draft_i64_signal : I64, Signal.Signal(I64Draft), Signal.Signal(Browser.StorageText) -> Signal.Signal(I64)
draft_i64_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_i64_value(fallback, value.draft, value.stored))
}

draft_plan_signal : Plan, Signal.Signal(PlanDraft), Signal.Signal(Browser.StorageText) -> Signal.Signal(Plan)
draft_plan_signal = |fallback, draft, stored| {
	inputs = { draft: draft, stored: stored }.Signal
	inputs.map(|value| draft_plan_value(fallback, value.draft, value.stored))
}

draft_i64_current : I64, I64Draft -> I64
draft_i64_current = |fallback, draft|
	match draft {
		I64Changed(value) => value
		I64Untouched => fallback
	}

increase_i64 : I64, I64Draft -> I64Draft
increase_i64 = |fallback, draft| I64Changed(draft_i64_current(fallback, draft) + 1)

decrease_i64 : I64, I64Draft -> I64Draft
decrease_i64 = |fallback, draft| {
	next = draft_i64_current(fallback, draft) - 1
	if next < 0 {
		I64Changed(0)
	} else {
		I64Changed(next)
	}
}

next_step_draft : I64Draft -> I64Draft
next_step_draft = |draft| I64Changed(next_step(draft_i64_current(0, draft)))

prev_step_draft : I64Draft -> I64Draft
prev_step_draft = |draft| I64Changed(prev_step(draft_i64_current(0, draft)))

has_storage_value : Browser.StorageText -> Bool
has_storage_value = |stored|
	match stored {
		StorageValue(_) => True
		_ => False
	}

storage_notice_text : Browser.StorageText -> Str
storage_notice_text = |stored|
	match stored {
		StorageUnavailable(_) => "Saved draft storage is unavailable in this browser."
		_ => ""
	}

checkout_step_key = "team-checkout:step"

checkout_email_key = "team-checkout:email"

checkout_address_key = "team-checkout:address"

checkout_terms_key = "team-checkout:terms"

checkout_plan_key = "team-checkout:plan"

quantity_seats_key = "team-checkout:qty:3-seats"

quantity_support_key = "team-checkout:qty:priority-support"

quantity_audit_key = "team-checkout:qty:audit-log-export"

quantity_key_for_label : Str -> Str
quantity_key_for_label = |label|
	if label == "Priority support" {
		quantity_support_key
	} else if label == "Audit log export" {
		quantity_audit_key
	} else {
		quantity_seats_key
	}

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

cart_item_class = "panel grid gap-3 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

render_line : Str, Signal.Signal(Browser.StorageText) -> Elem
render_line = |label, stored_quantity| {
	key = quantity_key_for_label(label)

	Ui.state(
		I64Untouched,
		|quantity| {
			quantity_value = draft_i64_signal(1, quantity.signal(), stored_quantity)
			quantity_label = quantity_value.map(|n| "${label} quantity: ${n.to_str()}")

			Html.section_c(
				label,
				cart_item_class,
				[
					Html.heading_c(label, "text-lg font-semibold text-zinc-950"),
					Html.paragraph_c("Included in the team workspace order.", "text-sm text-zinc-600"),
					Html.div_c(
						toolbar_class,
						[
							Html.button_c("Decrease ${label}", "button", quantity.on_unit(|draft| decrease_i64(1, draft))),
							Html.paragraph_s_c(quantity_label, "text-sm font-medium text-zinc-900"),
							Html.button_c("Increase ${label}", "button", quantity.on_unit(|draft| increase_i64(1, draft))),
							Ui.on_change(quantity.signal(), |draft|
								match draft {
									I64Changed(n) => Browser.set_local_storage_text(key, n.to_str())
									I64Untouched => Signal.noop
								}
							),
						],
					),
				],
			)
		},
	)
}

receipt_label : I64 -> Str
receipt_label = |attempts|
	if attempts == 0 {
		"Receipt pending"
	} else {
		label_i64("Receipt sent", attempts)
	}

main : () -> Elem
main = || {
	stored_step = Browser.local_storage_text(checkout_step_key)
	stored_email = Browser.local_storage_text(checkout_email_key)
	stored_address = Browser.local_storage_text(checkout_address_key)
	stored_terms = Browser.local_storage_text(checkout_terms_key)
	stored_plan_source = Browser.local_storage_text(checkout_plan_key)
	stored_seats_quantity = Browser.local_storage_text(quantity_seats_key)
	stored_support_quantity = Browser.local_storage_text(quantity_support_key)
	stored_audit_quantity = Browser.local_storage_text(quantity_audit_key)

	Ui.state(
		I64Untouched,
		|step| {
			Ui.state(
				TextUntouched,
				|email| {
					Ui.state(
						TextUntouched,
						|address| {
							Ui.state(
								BoolUntouched,
								|terms| {
									Ui.state(
										PlanUntouched,
										|plan| {
											Ui.state(
												0,
												|submit_count| {
													Ui.state(
														0,
														|clear_saved| {
															step_value = draft_i64_signal(0, step.signal(), stored_step)
															step_text = step_value.map(step_label)
															step_attr = step_value.map(step_attr_value)
															is_cart = step_value.map(|value| value == 0)
															is_delivery = step_value.map(|value| value == 1)
															email_value = draft_text_signal("", email.signal(), stored_email)
															address_value = draft_text_signal("", address.signal(), stored_address)
															terms_value = draft_bool_signal(False, terms.signal(), stored_terms)
															plan_value = draft_plan_signal(Plan.Team, plan.signal(), stored_plan_source)
															terms_text =
																terms_value.map(
																	|accepted| if accepted {
																		"Terms accepted"
																	} else {
																		"Terms pending"
																	},
																)
															submit_disabled = terms_value.map(|accepted| !accepted)
															review_label = submit_count.signal().map(receipt_label)
															email_review = email_value.map(|value| "Email: ${value}")
															address_review = address_value.map(|value| "Address: ${value}")
															is_team_plan = plan_value.map(|value| value == Plan.Team)
															team_class_signal = plan_value.map(team_button_class)
															basic_class_signal = plan_value.map(basic_button_class)
															team_pressed_signal = plan_value.map(team_pressed)
															basic_pressed_signal = plan_value.map(basic_pressed)
															has_saved_order = stored_email.map(has_storage_value)
															storage_notice = stored_email.map(storage_notice_text)

															resume_panel =
																Html.section_c(
																	"Saved checkout",
																	panel_class,
																	[
																		Html.heading_c("Resume saved order", "text-lg font-semibold text-zinc-950"),
																		Html.paragraph_c("A saved checkout draft was restored from this browser.", "text-sm text-zinc-700"),
																		Html.button_c("Clear saved order", "button", clear_saved.on_unit(|current| current + 1)),
																	],
																)
															cart_panel =
																Html.section(
																	"Cart",
																	[Html.class_attr(panel_class), Html.attr("data-panel", "cart")],
																	[
																		Html.heading_c("Workspace plan", "text-xl font-semibold text-zinc-950"),
																		Html.paragraph_c("Choose the subscription lines for the team checkout.", "text-sm text-zinc-600"),
																		Html.div_c(
																			toolbar_class,
																			[
																				Html.button_attrs(
																					"Use team plan",
																					[Html.class_attr_s(team_class_signal), Html.attr_s("aria-pressed", team_pressed_signal)],
																					plan.on_unit(|_| PlanChanged(Plan.Team)),
																				),
																				Html.button_attrs(
																					"Use basic plan",
																					[Html.class_attr_s(basic_class_signal), Html.attr_s("aria-pressed", basic_pressed_signal)],
																					plan.on_unit(|_| PlanChanged(Plan.Basic)),
																				),
																			],
																		),
																		render_line("3 seats", stored_seats_quantity),
																		Ui.when(
																			is_team_plan,
																			|| {
																				Html.div_c(
																					"grid gap-4",
																					[
																						render_line("Priority support", stored_support_quantity),
																						render_line("Audit log export", stored_audit_quantity),
																					],
																				)
																			},
																			|| Html.div_c("hidden", []),
																		),
																	],
																)
															delivery_panel =
																Html.section_c(
																	"Delivery",
																	panel_class,
																	[
																		Html.heading_c("Delivery details", "text-xl font-semibold text-zinc-950"),
																		Html.text_input_c("Email", email_value, input_class, email.on_str(|_, value| TextChanged(value))),
																		Html.text_input_c("Address", address_value, input_class, address.on_str(|_, value| TextChanged(value))),
																		Html.checkbox_c("Accept terms", terms_value, "rounded border-zinc-300", terms.on_bool(|_, checked| BoolChanged(checked))),
																		Html.paragraph_s_c(terms_text, "text-sm font-medium text-zinc-900"),
																	],
																)
															review_panel =
																Html.section_c(
																	"Review",
																	panel_class,
																	[
																		Html.heading_c("Review order", "text-xl font-semibold text-zinc-950"),
																		Html.paragraph_s_c(email_review, "text-sm text-zinc-700"),
																		Html.paragraph_s_c(address_review, "text-sm text-zinc-700"),
																		Html.paragraph_s_c(review_label, "text-sm font-medium text-emerald-700"),
																		Html.action_button_c(
																			Signal.const("Place order"),
																			submit_disabled,
																			"button-primary",
																			submit_count.on_unit(|current| current + 1),
																		),
																	],
																)

															Html.div_c(
																page_class,
																[
																	Html.section_c(
																		"Team Checkout",
																		hero_class,
																		[
																			Html.heading_c("Team Checkout", "text-3xl font-semibold text-zinc-950"),
																			Html.paragraph_c("Build a team workspace order across cart, delivery, and review without losing entered details.", "max-w-3xl text-sm text-zinc-700"),
																			Html.paragraph_s_c(storage_notice, "text-sm font-medium text-amber-700"),
																		],
																	),
																	Ui.when(
																		has_saved_order,
																		|| resume_panel,
																		|| Html.div_c("hidden", []),
																	),
																	Html.section_c(
																		"Checkout progress",
																		panel_class,
																		[
																			Html.paragraph_s_c(step_text, "text-sm font-semibold text-zinc-950"),
																			Html.div_c(
																				toolbar_class,
																				[
																					Html.button_c("Back", "button", step.on_unit(prev_step_draft)),
																					Html.button_c("Next", "button-primary", step.on_unit(next_step_draft)),
																				],
																			),
																		],
																	),
																	Html.section("Current step", [Html.class_attr("sr-only"), Html.attr_s("data-step", step_attr)], [Html.text_s(step_text)]),
																	Ui.when(
																		is_cart,
																		|| cart_panel,
																		|| {
																			Ui.when(
																				is_delivery,
																				|| delivery_panel,
																				|| review_panel,
																			)
																		},
																	),
																	Html.div_c(
																		"hidden",
																		[
																			Html.text_s(stored_seats_quantity.map(|_| "")),
																			Html.text_s(stored_support_quantity.map(|_| "")),
																			Html.text_s(stored_audit_quantity.map(|_| "")),
																		],
																	),
																	Ui.on_change(step_value, |value| Browser.set_local_storage_text(checkout_step_key, value.to_str())),
																	Ui.on_change(email_value, |value| Browser.set_local_storage_text(checkout_email_key, value)),
																	Ui.on_change(address_value, |value| Browser.set_local_storage_text(checkout_address_key, value)),
																	Ui.on_change(terms_value, |value| Browser.set_local_storage_text(checkout_terms_key, encode_bool(value))),
																	Ui.on_change(plan_value, |value| Browser.set_local_storage_text(checkout_plan_key, encode_plan(value))),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(checkout_step_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(checkout_email_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(checkout_address_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(checkout_terms_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(checkout_plan_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(quantity_seats_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(quantity_support_key)),
																	Ui.on_change(clear_saved.signal(), |_| Browser.remove_local_storage(quantity_audit_key)),
																],
															)
														},
													)
												},
											)
										},
									)
								},
							)
						},
					)
				},
			)
		},
	)
}
