app [main] { pf: platform "../../platform/main.roc" }

import Loan
import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

page_class = "app-shell app-shell-wide"

panel_class = "panel grid gap-4 p-4"

## The three scenarios are columns, not a stack: comparing them is the whole
## point, so they have to sit beside each other at desktop width.
columns_class = "grid gap-4 lg:grid-cols-3"

input_class = "input numeric text-right"

## An amortisation schedule is detail, not headline. It scrolls inside its own
## box so twelve or twenty-four months never push the comparison off screen.
schedule_scroll_class = "max-h-56 overflow-y-auto rounded-md border border-zinc-200 bg-zinc-50"

row_class = "numeric border-b border-zinc-100 px-3 py-1.5 text-xs text-zinc-700"

## A schedule row flattened for display, keyed by scenario slug and month. The
## key doubles as the row's `test_id`, so a spec can assert a specific month's
## figures by identity rather than by matching their text.
##
## One string per row on purpose: each row is a single derived node, so editing
## a scenario recomputes one text per month rather than one per cell.
RowView : {
	key : Str,
	text : Str,
}

scenario_a_draft : Loan.Draft
scenario_a_draft = { principal: "2400", rate: "6", term: "12", extra: "0" }

scenario_b_draft : Loan.Draft
scenario_b_draft = { principal: "2400", rate: "12", term: "12", extra: "0" }

scenario_c_draft : Loan.Draft
scenario_c_draft = { principal: "2400", rate: "6", term: "24", extra: "0" }

set_principal : Loan.Draft, Str -> Loan.Draft
set_principal = |draft, value| { ..draft, principal: value }

set_rate : Loan.Draft, Str -> Loan.Draft
set_rate = |draft, value| { ..draft, rate: value }

set_term : Loan.Draft, Str -> Loan.Draft
set_term = |draft, value| { ..draft, term: value }

set_extra : Loan.Draft, Str -> Loan.Draft
set_extra = |draft, value| { ..draft, extra: value }

row_views : Str, Loan.Schedule -> List(RowView)
row_views = |id, sched|
	sched.rows.map(
		|row| {
			key: "${id}-month-${row.month.to_str()}",
			text: "Month ${row.month.to_str()} | interest ${Loan.money(row.interest)} | principal ${Loan.money(row.principal_paid)} | balance ${Loan.money(row.balance)}",
		},
	)

render_row : Str, Signal.Signal(RowView) -> Elem
render_row = |key, row|
	Html.paragraph_s_attrs(
		row.map(|value| value.text),
		[Html.class_attr(row_class), Html.test_id(key)],
	)

render_rows : Str, Str, Signal.Signal(Loan.Schedule) -> Elem
render_rows = |id, name, sched| {
	rows = sched.map(|value| Rows.from_list(row_views(id, value), |row| row.key) ?? crash "duplicate row key")
	Html.section_c(
		"${name} schedule",
		"grid gap-2",
		[
			Html.paragraph_c("Amortisation", "panel-title"),
			Html.div_c(
				schedule_scroll_class,
				[
					Ui.when(
						sched.map(|value| value.rows.is_empty()),
						|| Html.paragraph_c("Nothing to amortise — this scenario borrows $0.00.", "empty-state border-0 bg-transparent"),
						|| Ui.each(rows, |each_row| render_row(each_row.key(), each_row.signal())),
					),
				],
			),
		],
	)
}

## A labelled money/number input. `Html.text_input_c`'s first argument is only
## an accessible name, so the visible caption is drawn here.
money_field : Str, Str, Signal.Signal(Str), _ -> Elem
money_field = |label, placeholder, value, msg|
	Html.div_c(
		"field",
		[
			Html.paragraph_c(label, "field-label"),
			Html.text_input_attrs(
				label,
				value,
				[Html.class_attr(input_class), Html.attr("placeholder", placeholder)],
				msg,
			),
		],
	)

## One headline figure. Three of the four fields are `Str`, so they are named:
## a positional call could quietly swap the label, the test id and the size.
Metric : {
	label : Str,
	value : Signal.Signal(Str),
	test_id : Str,
	size : Str,
}

metric : Metric -> Elem
metric = |spec|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(spec.label, "stat-label"),
			Html.paragraph_s_attrs(spec.value, [Html.class_attr("stat-value ${spec.size}"), Html.test_id(spec.test_id)]),
		],
	)

## As `metric`, plus a "Lowest" badge that appears only on the winning column.
## The mark is derived from the same comparison signal that ranks the number,
## so the badge can never contradict the figure under it.
MarkedMetric : {
	label : Str,
	value : Signal.Signal(Str),
	test_id : Str,
	size : Str,
	best : Signal.Signal(Bool),
}

marked_metric : MarkedMetric -> Elem
marked_metric = |spec|
	Html.div_sc(
		spec.best.map(stat_class),
		[
			Html.div_c(
				"flex items-center justify-between gap-2",
				[
					Html.paragraph_c(spec.label, "stat-label"),
					Html.paragraph_attrs("Lowest", [Html.class_attr_s(spec.best.map(mark_class))]),
				],
			),
			Html.paragraph_s_attrs(spec.value, [Html.class_attr("stat-value ${spec.size}"), Html.test_id(spec.test_id)]),
		],
	)

## The badge is hidden rather than emptied: an empty pill would still draw a
## border, and a "Lowest" caption on a losing column would be a lie.
mark_class : Bool -> Str
mark_class = |best| if best {
	"badge badge-ok"
} else {
	"hidden"
}

stat_class : Bool -> Str
stat_class = |best|
	if best {
		"stat border-emerald-200 bg-emerald-50"
	} else {
		"stat"
	}

## Both the badge text and its tone come off the same verdict tag, so the two
## cannot disagree — neither is read back out of the other's sentence.
input_badge_class : Loan.Validation -> Str
input_badge_class = |validation|
	if Loan.Validation.is_valid(validation) {
		"badge badge-ok"
	} else {
		"badge badge-danger"
	}

## A draft whose boxes all parse gets the affirmative badge tone.
expect input_badge_class(Valid) == "badge badge-ok"

## Any failing field flips the badge to the danger tone.
expect input_badge_class(Invalid([Rate])) == "badge badge-danger"

## The scenario with the lowest `field`. An empty list has no winner, which is
## `Err(NotFound)` rather than an id no scenario can hold.
best_by : List(Loan.Summary), (Loan.Summary -> U64) -> Try(Loan.Summary, [NotFound])
best_by = |summaries, field|
	summaries
		.first()
		.map_ok(
			|head| summaries.fold(
				head,
				|current, item| if field(item) < field(current) {
					item
				} else {
					current
				},
			),
		)
		.map_err(|_| NotFound)

is_best : List(Loan.Summary), (Loan.Summary -> U64), Str -> Bool
is_best = |summaries, field, id| best_by(summaries, field).map_ok(|best| best.id == id) ?? False

## One scenario column. `id` and `name` are both `Str` and sat side by side in
## the old positional signature; naming the fields makes transposing them, or
## any of the four signals, impossible at the call site.
Scenario : {
	id : Str,
	name : Str,
	draft : Ui.State(Loan.Draft),
	parsed : Signal.Signal(Loan.Parsed),
	sched : Signal.Signal(Loan.Schedule),
	summaries : Signal.Signal(Rows.Rows(Loan.Summary)),
}

## Every figure below is read from the SAME `sched` signal: the schedule is
## computed once per edit and consumed by five separate sinks. The two "Lowest"
## marks come off `summaries`, the cross-scenario fan-in.
scenario_panel : Scenario -> Elem
scenario_panel = |scenario| {
	{ id, name, draft, parsed, sched, summaries } = scenario
	draft_signal = draft.signal()
	best_payment = summaries.map(|rows| is_best(Rows.to_list(rows), |item| item.payment, id))
	best_cost = summaries.map(|rows| is_best(Rows.to_list(rows), |item| item.total_paid, id))

	Html.section_c(
		name,
		panel_class,
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-2",
				[
					Html.heading_c(name, "card-title text-base"),
					Html.paragraph_s_attrs(
						parsed.map(|value| Loan.Validation.to_str(value.validation)),
						[Html.class_attr_s(parsed.map(|value| input_badge_class(value.validation))), Html.test_id("${id}-inputs")],
					),
				],
			),
			Html.div_c(
				"grid gap-3 sm:grid-cols-2",
				[
					money_field("${name} principal", "2400", draft_signal.map(|value| value.principal), draft.on_str(set_principal)),
					money_field("${name} annual rate", "6", draft_signal.map(|value| value.rate), draft.on_str(set_rate)),
					money_field("${name} term months", "12", draft_signal.map(|value| value.term), draft.on_str(set_term)),
					money_field("${name} extra payment", "0", draft_signal.map(|value| value.extra), draft.on_str(set_extra)),
				],
			),
			Html.div_c(
				"grid gap-2 sm:grid-cols-2",
				[
					marked_metric({
						label: "Monthly payment",
						value: sched.map(|value| Loan.money(value.payment)),
						test_id: "${id}-payment",
						size: "text-xl",
						best: best_payment,
					}),
					marked_metric({
						label: "Total cost",
						value: sched.map(|value| Loan.money(value.total_paid)),
						test_id: "${id}-total-paid",
						size: "text-xl",
						best: best_cost,
					}),
					metric({
						label: "Total interest",
						value: sched.map(|value| Loan.money(value.total_interest)),
						test_id: "${id}-total-interest",
						size: "text-base",
					}),
					metric({
						label: "Payoff",
						value: sched.map(|value| Loan.months_text(value.months)),
						test_id: "${id}-payoff",
						size: "text-base",
					}),
				],
			),
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-2 border-t border-zinc-200 pt-3",
				[
					Html.paragraph_s_attrs(
						parsed.map(|value| Loan.percent(value.params.rate_bp)),
						[Html.class_attr("hint numeric"), Html.test_id("${id}-rate")],
					),
					Html.paragraph_s_attrs(
						sched.map(|value| Loan.money(value.final_balance)),
						[Html.class_attr("hint numeric"), Html.test_id("${id}-final-balance")],
					),
				],
			),
			render_rows(id, name, sched),
		],
	)
}

cheapest_text : List(Loan.Summary) -> Str
cheapest_text = |summaries|
	best_by(summaries, |item| item.total_interest)
		.map_ok(|best| "${best.name} (${Loan.money(best.total_interest)})") ?? "None"

spread_text : List(Loan.Summary) -> Str
spread_text = |summaries|
	summaries
		.first()
		.map_ok(
			|head| {
				low =
					summaries.fold(
						head.total_interest,
						|current, item| if item.total_interest < current {
							item.total_interest
						} else {
							current
						},
					)
				high =
					summaries.fold(
						head.total_interest,
						|current, item| if item.total_interest > current {
							item.total_interest
						} else {
							current
						},
					)
				Loan.money(high - low)
			},
		) ?? "None"

## Which two scenarios the break-even figure compares. The `<select>` hands us
## its wire value as text, so it is parsed once here and matched on everywhere
## else.
Pair := [AvsB, AvsC, BvsC].{
	is_eq : Pair, Pair -> Bool
	is_eq = |left, right|
		match left {
			AvsB => match right {
				AvsB => True
				_ => False
			}
			AvsC => match right {
				AvsC => True
				_ => False
			}
			BvsC => match right {
				BvsC => True
				_ => False
			}
		}

	from_str : Str -> Pair
	from_str = |value|
		if value == "ac" {
			AvsC
		} else if value == "bc" {
			BvsC
		} else {
			AvsB
		}

	## The inverse of `from_str`, so the `<option>` values still read `ab`.
	to_str : Pair -> Str
	to_str = |pair|
		match pair {
			AvsB => "ab"
			AvsC => "ac"
			BvsC => "bc"
		}

	## The two scenario columns, in the order the schedules are assembled.
	indexes : Pair -> { left : U64, right : U64 }
	indexes = |pair|
		match pair {
			AvsB => { left: 0, right: 1 }
			AvsC => { left: 0, right: 2 }
			BvsC => { left: 1, right: 2 }
		}
}

## The `<option>` value for A vs B parses back to the same pair.
expect Pair.from_str(Pair.to_str(AvsB)).is_eq(AvsB)

## The `<option>` value for A vs C parses back to the same pair.
expect Pair.from_str(Pair.to_str(AvsC)).is_eq(AvsC)

## The `<option>` value for B vs C parses back to the same pair.
expect Pair.from_str(Pair.to_str(BvsC)).is_eq(BvsC)

## A pair names its two scenario columns by their position in the schedule list.
expect Pair.indexes(AvsC) == { left: 0, right: 2 }

empty_schedule : Loan.Schedule
empty_schedule = { payment: 0, rows: [], total_interest: 0, total_paid: 0, months: 0, final_balance: 0 }

pick : List(Loan.Schedule), U64 -> Loan.Schedule
pick = |schedules, index| schedules.get(index) ?? empty_schedule

## The pair being compared is named by the select beside this figure, so the
## value is just the month the two cross over.
break_even_text : Pair, List(Loan.Schedule) -> Str
break_even_text = |pair, schedules| {
	sides = Pair.indexes(pair)
	month = Loan.break_even_month(pick(schedules, sides.left), pick(schedules, sides.right))
	if month == 0 {
		"Never"
	} else {
		"Month ${month.to_str()}"
	}
}

invariant_text : List(Loan.Schedule) -> Str
invariant_text = |schedules| {
	bad = schedules.keep_if(|sched| sched.final_balance != 0)
	if bad.is_empty() {
		"All balances clear"
	} else {
		"${bad.len().to_str()} schedule(s) did not clear"
	}
}

invariant_class : List(Loan.Schedule) -> Str
invariant_class = |schedules|
	if schedules.keep_if(|sched| sched.final_balance != 0).is_empty() {
		"badge badge-ok"
	} else {
		"badge badge-danger"
	}

summary_line : Loan.Summary -> Str
summary_line = |summary|
	"${Loan.money(summary.payment)} / mo, ${Loan.months_text(summary.months)}, ${Loan.money(summary.total_interest)} interest"

render_summary : Str, Signal.Signal(Loan.Summary) -> Elem
render_summary = |key, summary|
	Html.div_c(
		"flex flex-wrap items-baseline justify-between gap-2 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2",
		[
			Html.paragraph_s_c(summary.map(|value| value.name), "value"),
			Html.paragraph_s_attrs(
				summary.map(summary_line),
				[Html.class_attr("numeric text-sm text-zinc-700"), Html.test_id("summary-${key}")],
			),
		],
	)

comparison_panel : Ui.State(Str), Signal.Signal(Rows.Rows(Loan.Summary)), Signal.Signal(List(Loan.Schedule)) -> Elem
comparison_panel = |pair, summaries, schedules| {
	pair_signal = pair.signal()
	break_even = Signal.map2(pair_signal.map(Pair.from_str), schedules, break_even_text)

	Html.section_c(
		"Comparison",
		panel_class,
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3",
				[
					Html.heading_c("Comparison", "panel-title"),
					Html.paragraph_s_attrs(
						schedules.map(invariant_text),
						[Html.class_attr_s(schedules.map(invariant_class)), Html.test_id("schedule-invariant")],
					),
				],
			),
			Html.div_c(
				"stat-grid lg:grid-cols-3",
				[
					metric({ label: "Least interest", value: summaries.map(|rows| cheapest_text(Rows.to_list(rows))), test_id: "cheapest", size: "text-base" }),
					metric({ label: "Interest spread", value: summaries.map(|rows| spread_text(Rows.to_list(rows))), test_id: "interest-spread", size: "text-base" }),
					metric({ label: "Break-even", value: break_even, test_id: "break-even", size: "text-base" }),
				],
			),
			Html.div_c(
				"field max-w-sm",
				[
					Html.paragraph_c("Comparison pair", "field-label"),
					Html.select_c(
						"Comparison pair",
						pair_signal,
						"input",
						[
							Html.option(Pair.to_str(AvsB), "Scenario A vs Scenario B"),
							Html.option(Pair.to_str(AvsC), "Scenario A vs Scenario C"),
							Html.option(Pair.to_str(BvsC), "Scenario B vs Scenario C"),
						],
						pair.on_str(|_, value| value),
					),
					Html.paragraph_c("Break-even is the first month the two running totals swap places.", "hint"),
				],
			),
			Html.section_c(
				"Scenario summaries",
				"grid gap-2",
				[Ui.each(summaries, |each_row| render_summary(each_row.key(), each_row.signal()))],
			),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		scenario_a_draft,
		|draft_a|
			Ui.state(
				scenario_b_draft,
				|draft_b|
					Ui.state(
						scenario_c_draft,
						|draft_c|
							Ui.state(
								Pair.to_str(AvsB),
								|pair| {
									# Chain: draft -> parsed -> params -> schedule -> summary/rows/figures.
									parsed_a = draft_a.signal().map(Loan.parse_draft)
									parsed_b = draft_b.signal().map(Loan.parse_draft)
									parsed_c = draft_c.signal().map(Loan.parse_draft)

									params_a = parsed_a.map(|value| value.params)
									params_b = parsed_b.map(|value| value.params)
									params_c = parsed_c.map(|value| value.params)

									sched_a = params_a.map(Loan.schedule)
									sched_b = params_b.map(Loan.schedule)
									sched_c = params_c.map(Loan.schedule)

									summary_a = sched_a.map(|value| Loan.summarize("a", "Scenario A", value))
									summary_b = sched_b.map(|value| Loan.summarize("b", "Scenario B", value))
									summary_c = sched_c.map(|value| Loan.summarize("c", "Scenario C", value))

									# Fan-in: three independent scenario branches meet here.
									# `Signal.combine` would read every input through the first
									# signal's capability and abort, so the fan-in is nested `map2`.
									summaries =
										Signal.map2(
											Signal.map2(summary_a, summary_b, |a, b| [a, b]),
											summary_c,
											|pair_list, c|
												Rows.from_list(pair_list.append(c), |summary| summary.id) ?? crash "duplicate row key",
										)
									schedules =
										Signal.map2(
											Signal.map2(sched_a, sched_b, |a, b| [a, b]),
											sched_c,
											|pair_list, c| pair_list.append(c),
										)

									Html.div_c(
										page_class,
										[
											Html.section_c(
												"Loan Comparator",
												"app-header",
												[
													Html.heading_c("Loan Comparator", "app-title"),
													Html.paragraph_c(
														"Three loans side by side, in integer cents. Each scenario's amortisation schedule is one memoised derived signal, and every figure in its column — including the Lowest marks — is read from it.",
														"app-subtitle",
													),
												],
											),
											comparison_panel(pair, summaries, schedules),
											Html.div_c(
												columns_class,
												[
													scenario_panel({ id: "a", name: "Scenario A", draft: draft_a, parsed: parsed_a, sched: sched_a, summaries }),
													scenario_panel({ id: "b", name: "Scenario B", draft: draft_b, parsed: parsed_b, sched: sched_b, summaries }),
													scenario_panel({ id: "c", name: "Scenario C", draft: draft_c, parsed: parsed_c, sched: sched_c, summaries }),
												],
											),
										],
									)
								},
							),
					),
			),
	)
