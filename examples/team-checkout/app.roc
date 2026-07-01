app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

label_i64 : Str, I64 -> Str
label_i64 = |name, value| concat3(name, ": ", value.to_str())

step_label : I64 -> Str
step_label = |step| {
	if step == 0 {
		"Step 1 - Cart"
	} else if step == 1 {
		"Step 2 - Delivery"
	} else {
		"Step 3 - Review"
	}
}

step_attr_value : I64 -> Str
step_attr_value = |step| {
	if step == 0 {
		"cart"
	} else if step == 1 {
		"delivery"
	} else {
		"review"
	}
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

initial_lines : List(Str)
initial_lines = ["3 seats", "Priority support"]

team_lines : List(Str)
team_lines = ["3 seats", "Priority support", "Audit log export"]

basic_lines : List(Str)
basic_lines = ["3 seats"]

page_class : Str
page_class = "grid gap-5"

hero_class : Str
hero_class = "panel grid gap-2 p-5"

panel_class : Str
panel_class = "panel grid gap-4 p-4"

cart_item_class : Str
cart_item_class = "panel grid gap-3 p-4"

toolbar_class : Str
toolbar_class = "flex flex-wrap items-center gap-3"

input_class : Str
input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

render_line : Str, Signal.Signal(Str) -> Elem
render_line = |label, _line_signal| {
	initial_quantity : I64
	initial_quantity = 1

	Ui.state(
		initial_quantity,
		|quantity| {
			quantity_label =
				Signal.map(
					quantity.signal(),
					|n| concat3(label, " quantity: ", n.to_str()),
				)

			Html.section_c(
				label,
				cart_item_class,
				[
					Html.heading_c(label, "text-lg font-semibold text-zinc-950"),
					Html.paragraph_c("Included in the team workspace order.", "text-sm text-zinc-600"),
					Html.div_c(
						toolbar_class,
						[
							Html.button_c(
								Str.concat("Decrease ", label),
								"button",
								quantity.on_unit(|current| {
									next = current - 1
									if next < 0 {
										0
									} else {
										next
									}
								}),
							),
							Html.paragraph_s_c(quantity_label, "text-sm font-medium text-zinc-900"),
							Html.button_c(Str.concat("Increase ", label), "button", quantity.on_unit(|current| current + 1)),
						],
					),
				],
			)
		},
	)
}

receipt_label : I64 -> Str
receipt_label = |attempts| {
	if attempts == 0 {
		"Receipt pending"
	} else {
		label_i64("Receipt sent", attempts)
	}
}

main : {} -> Elem
main = |_| {
	initial_terms : Bool
	initial_terms = False

	Ui.state(
		0,
		|step| {
			Ui.state(
				"",
				|email| {
					Ui.state(
						"",
						|address| {
							Ui.state(
								initial_terms,
								|terms| {
									Ui.state(
										initial_lines,
										|lines| {
											Ui.state(
												0,
												|submit_count| {
													step_signal = step.signal()
													step_text = Signal.map(step_signal, step_label)
													step_attr = Signal.map(step_signal, step_attr_value)
													is_cart = Signal.map(step_signal, |value| value == 0)
													is_delivery = Signal.map(step_signal, |value| value == 1)
													terms_signal = terms.signal()
													terms_text =
														Signal.map(
															terms_signal,
															|accepted| if accepted {
																"Terms accepted"
															} else {
																"Terms pending"
															},
														)
													submit_disabled = Signal.map(terms_signal, |accepted| !accepted)
													review_label = Signal.map(submit_count.signal(), receipt_label)
													email_review = Signal.map(email.signal(), |value| Str.concat("Email: ", value))
													address_review = Signal.map(address.signal(), |value| Str.concat("Address: ", value))

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
																		Html.button_c("Use team plan", "button-primary", lines.on_unit(|_| team_lines)),
																		Html.button_c("Use basic plan", "button", lines.on_unit(|_| basic_lines)),
																	],
																),
																Ui.each_str(lines.signal(), |label| label, render_line),
															],
														)
													delivery_panel =
														Html.section_c(
															"Delivery",
															panel_class,
															[
																Html.heading_c("Delivery details", "text-xl font-semibold text-zinc-950"),
																Html.text_input_c("Email", email.signal(), input_class, email.on_str(|_, value| value)),
																Html.text_input_c("Address", address.signal(), input_class, address.on_str(|_, value| value)),
																Html.checkbox_c("Accept terms", terms_signal, "rounded border-zinc-300", terms.on_bool(|_, checked| checked)),
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
																],
															),
															Html.section_c(
																"Checkout progress",
																panel_class,
																[
																	Html.paragraph_s_c(step_text, "text-sm font-semibold text-zinc-950"),
																	Html.div_c(
																		toolbar_class,
																		[
																			Html.button_c("Back", "button", step.on_unit(prev_step)),
																			Html.button_c("Next", "button-primary", step.on_unit(next_step)),
																		],
																	),
																],
															),
															Html.section("Current step", [Html.class_attr("sr-only"), Html.attr_s("data-step", step_attr)], [Html.text_s(step_text)]),
															Ui.when(
																is_cart,
																|_| cart_panel,
																|_| {
																	Ui.when(
																		is_delivery,
																		|_| delivery_panel,
																		|_| review_panel,
																	)
																},
															),
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
}
