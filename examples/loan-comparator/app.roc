app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Loan
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

list_class = "grid gap-1"

input_class = "w-full max-w-xs rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

figure_class = "text-sm font-medium text-zinc-900"

note_class = "text-sm text-zinc-600"

row_class = "text-sm text-zinc-700"

## A schedule row flattened for display, keyed by scenario id and month.
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
row_views = |name, sched|
	sched.rows.map(
		|row| {
			key: "${name} month ${row.month.to_str()}",
			text: "${name} month ${row.month.to_str()}: interest ${Loan.money(row.interest)}, principal ${Loan.money(row.principal_paid)}, balance ${Loan.money(row.balance)}",
		},
	)

render_row : Str, Signal.Signal(RowView) -> Elem
render_row = |_key, row| Html.paragraph_s_c(row.map(|value| value.text), row_class)

render_rows : Str, Signal.Signal(Loan.Schedule) -> Elem
render_rows = |name, sched| {
	rows = sched.map(|value| row_views(name, value))
	Html.section_c(
		"${name} schedule",
		list_class,
		[Ui.each_str(rows, |row| row.key, render_row)],
	)
}

## One scenario panel. Every figure below is read from the SAME `sched` signal:
## the schedule is computed once per edit and consumed by five separate sinks.
scenario_panel : Str, Ui.State(Loan.Draft), Signal.Signal(Loan.Parsed), Signal.Signal(Loan.Schedule) -> Elem
scenario_panel = |name, draft, parsed, sched| {
	draft_signal = draft.signal()

	Html.section_c(
		name,
		panel_class,
		[
			Html.heading_c(name, "text-lg font-semibold text-zinc-950"),
			Html.text_input_c(
				"${name} principal",
				draft_signal.map(|value| value.principal),
				input_class,
				draft.on_str(set_principal),
			),
			Html.text_input_c(
				"${name} annual rate",
				draft_signal.map(|value| value.rate),
				input_class,
				draft.on_str(set_rate),
			),
			Html.text_input_c(
				"${name} term months",
				draft_signal.map(|value| value.term),
				input_class,
				draft.on_str(set_term),
			),
			Html.text_input_c(
				"${name} extra payment",
				draft_signal.map(|value| value.extra),
				input_class,
				draft.on_str(set_extra),
			),
			Html.paragraph_s_c(
				parsed.map(|value| "${name} inputs: ${value.message}"),
				note_class,
			),
			Html.paragraph_s_c(
				parsed.map(|value| "${name} rate: ${Loan.percent(value.params.rate_bp)}"),
				note_class,
			),
			Html.paragraph_s_c(
				sched.map(|value| "${name} monthly payment: ${Loan.money(value.payment)}"),
				figure_class,
			),
			Html.paragraph_s_c(
				sched.map(|value| "${name} total interest: ${Loan.money(value.total_interest)}"),
				figure_class,
			),
			Html.paragraph_s_c(
				sched.map(|value| "${name} total paid: ${Loan.money(value.total_paid)}"),
				figure_class,
			),
			Html.paragraph_s_c(
				sched.map(|value| "${name} payoff: ${Loan.months_text(value.months)}"),
				figure_class,
			),
			Html.paragraph_s_c(
				sched.map(|value| "${name} final balance: ${Loan.money(value.final_balance)}"),
				figure_class,
			),
			render_rows(name, sched),
		],
	)
}

cheapest_text : List(Loan.Summary) -> Str
cheapest_text = |summaries|
	match summaries.first() {
		Err(_) => "Cheapest: none"
		Ok(head) => {
			best =
				summaries.fold(
					head,
					|current, item|
						if item.total_interest < current.total_interest {
							item
						} else {
							current
						},
				)
			"Cheapest: ${best.name} at ${Loan.money(best.total_interest)} total interest"
		}
	}

spread_text : List(Loan.Summary) -> Str
spread_text = |summaries|
	match summaries.first() {
		Err(_) => "Interest spread: none"
		Ok(head) => {
			low =
				summaries.fold(
					head.total_interest,
					|current, item| if item.total_interest < current { item.total_interest } else { current },
				)
			high =
				summaries.fold(
					head.total_interest,
					|current, item| if item.total_interest > current { item.total_interest } else { current },
				)
			"Interest spread: ${Loan.money(high - low)}"
		}
	}

pair_name : Str -> Str
pair_name = |pair|
	match pair {
		"ac" => "Scenario A vs Scenario C"
		"bc" => "Scenario B vs Scenario C"
		_ => "Scenario A vs Scenario B"
	}

pair_indexes : Str -> { left : U64, right : U64 }
pair_indexes = |pair|
	match pair {
		"ac" => { left: 0, right: 2 }
		"bc" => { left: 1, right: 2 }
		_ => { left: 0, right: 1 }
	}

pick : List(Loan.Schedule), U64 -> Loan.Schedule
pick = |schedules, index|
	match schedules.get(index) {
		Ok(value) => value
		Err(_) => { payment: 0, rows: [], total_interest: 0, total_paid: 0, months: 0, final_balance: 0 }
	}

break_even_text : Str, List(Loan.Schedule) -> Str
break_even_text = |pair, schedules| {
	sides = pair_indexes(pair)
	month = Loan.break_even_month(pick(schedules, sides.left), pick(schedules, sides.right))
	if month == 0 {
		"Break-even (${pair_name(pair)}): none"
	} else {
		"Break-even (${pair_name(pair)}): month ${month.to_str()}"
	}
}

invariant_text : List(Loan.Schedule) -> Str
invariant_text = |schedules| {
	bad = schedules.keep_if(|sched| sched.final_balance != 0)
	if bad.is_empty() {
		"Schedule invariant: all final balances are $0.00"
	} else {
		"Schedule invariant: ${bad.len().to_str()} schedule(s) did not clear"
	}
}

summary_line : Loan.Summary -> Str
summary_line = |summary|
	"${summary.name} summary: ${Loan.money(summary.payment)} per month for ${Loan.months_text(summary.months)}, interest ${Loan.money(summary.total_interest)}"

render_summary : Str, Signal.Signal(Loan.Summary) -> Elem
render_summary = |_key, summary| Html.paragraph_s_c(summary.map(summary_line), row_class)

comparison_panel : Ui.State(Str), Signal.Signal(List(Loan.Summary)), Signal.Signal(List(Loan.Schedule)) -> Elem
comparison_panel = |pair, summaries, schedules| {
	pair_signal = pair.signal()
	break_even = Signal.map2(pair_signal, schedules, break_even_text)

	Html.section_c(
		"Comparison",
		panel_class,
		[
			Html.heading_c("Comparison", "text-lg font-semibold text-zinc-950"),
			Html.paragraph_s_c(summaries.map(cheapest_text), figure_class),
			Html.paragraph_s_c(summaries.map(spread_text), figure_class),
			Html.paragraph_s_c(schedules.map(invariant_text), figure_class),
			Html.select_c(
				"Comparison pair",
				pair_signal,
				input_class,
				[
					Html.option("ab", "Scenario A vs Scenario B"),
					Html.option("ac", "Scenario A vs Scenario C"),
					Html.option("bc", "Scenario B vs Scenario C"),
				],
				pair.on_str(|_, value| value),
			),
			Html.paragraph_s_c(break_even, figure_class),
			Html.section_c(
				"Scenario summaries",
				list_class,
				[Ui.each_str(summaries, |summary| summary.id, render_summary)],
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
								"ab",
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
											|pair_list, c| pair_list.append(c),
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
												hero_class,
												[
													Html.heading_c("Loan Comparator", "text-3xl font-semibold text-zinc-950"),
													Html.paragraph_c(
														"Compare loan scenarios with integer-cent arithmetic. Each scenario's amortisation schedule is one memoised derived signal that many parts of this page read.",
														"max-w-3xl text-sm text-zinc-700",
													),
												],
											),
											scenario_panel("Scenario A", draft_a, parsed_a, sched_a),
											scenario_panel("Scenario B", draft_b, parsed_b, sched_b),
											scenario_panel("Scenario C", draft_c, parsed_c, sched_c),
											comparison_panel(pair, summaries, schedules),
										],
									)
								},
							),
					),
			),
	)
