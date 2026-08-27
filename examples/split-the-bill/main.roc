app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

## Split the Bill — the gallery's teaching example for derived state.
##
## There are exactly two sources of truth: the roster (who is on the trip) and
## the ledger (what was spent). Everything else on screen is a derived signal:
##
##     roster.names ─┐
##                   ├─> person_rows ──> settlement ──> settlement_summary
##     ledger.items ─┘        │
##                   └─> expense_views
##
## `person_rows` is the diamond: it is the only value that needs both sources at
## once, and both the balance list and the settlement plan hang off it. No
## balance, share, or transfer is ever written into state by a reducer — they are
## recomputed by the graph whenever a source changes, which is why editing one
## expense's amount patches text sinks instead of rebuilding rows.
##
## Two rules the app commits to, both spec'd:
##
## * **Removing a person** is blocked, with a visible reason, while that person
##   is the payer on any expense — a payment has nowhere to go. Anyone who is
##   only *sharing* expenses may leave at any time, and the expenses they were
##   on re-split across whoever remains. That falls out of storing the people an
##   expense *excludes* rather than the people it includes.
## * **Money is integer cents.** Amounts are stored as the text the user typed
##   and parsed into cents by `Bill`; a split that does not divide evenly gives
##   the leftover cents to the first participants in trip order, so the shares
##   always add back to the exact amount and the balances always sum to $0.00.

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

import Bill

## Who is on the trip, plus the draft name in the add-person form. The draft
## lives here because a reducer can only see its own binder, and adding a person
## has to read the draft and write the list in one step.
Roster : { names : List(Str), draft : Str }

## What was spent, plus the add-expense form draft.
Ledger : {
	items : List(Bill.Expense),
	description : Str,
	amount_text : Str,
	payer : Str,
}

initial_roster : Roster
initial_roster = { names: ["Ana", "Ben", "Chloe"], draft: "" }

initial_ledger : Ledger
initial_ledger = {
	items: [
		{ description: "Cabin", amount_text: "300.00", payer: "Ana", excluded: [] },
		{ description: "Dinner", amount_text: "62.50", payer: "Ben", excluded: [] },
		{ description: "Taxi", amount_text: "24.00", payer: "Chloe", excluded: ["Ana"] },
	],
	description: "",
	amount_text: "",
	payer: "Ana",
}

# --- roster reducers ---------------------------------------------------------

set_person_draft : Roster, Str -> Roster
set_person_draft = |roster, value| { ..roster, draft: value }

add_person : Roster -> Roster
add_person = |roster| {
	name = roster.draft.trim()
	if name.is_empty() or roster.names.contains(name) {
		roster
	} else {
		{ names: roster.names.append(name), draft: "" }
	}
}

## Removing a person is only offered when they did not pay for anything (see
## `person_locked`). Anyone else can leave at any time: because an expense stores
## the people it *excludes*, the expenses they were sharing simply re-split
## across whoever is left.
remove_person : Str -> (Roster -> Roster)
remove_person = |name| |roster| { ..roster, names: roster.names.drop_if(|other| other == name) }

person_draft_note : Roster -> Str
person_draft_note = |roster| {
	name = roster.draft.trim()
	if name.is_empty() {
		"Enter a name to add them to the trip."
	} else if roster.names.contains(name) {
		"${name} is already on the trip."
	} else {
		"Ready to add ${name}."
	}
}

person_draft_blocked : Roster -> Bool
person_draft_blocked = |roster| {
	name = roster.draft.trim()
	name.is_empty() or roster.names.contains(name)
}

# --- ledger reducers ---------------------------------------------------------

set_expense_description : Ledger, Str -> Ledger
set_expense_description = |ledger, value| { ..ledger, description: value }

set_expense_amount : Ledger, Str -> Ledger
set_expense_amount = |ledger, value| { ..ledger, amount_text: value }

set_expense_payer : Ledger, Str -> Ledger
set_expense_payer = |ledger, value| { ..ledger, payer: value }

expense_draft_ready : Ledger -> Bool
expense_draft_ready = |ledger| {
	description = ledger.description.trim()
	amount_ok = Try.is_ok(Bill.parse_cents(ledger.amount_text))
	(!description.is_empty())
	and (!ledger.items.any(|item| item.description == description))
	and amount_ok
}

add_expense : Ledger -> Ledger
add_expense = |ledger|
	if !expense_draft_ready(ledger) {
		ledger
	} else {
		{
			..ledger,
			items: ledger.items.append(
				{
					description: ledger.description.trim(),
					amount_text: ledger.amount_text.trim(),
					payer: ledger.payer,
					excluded: [],
				},
			),
			description: "",
			amount_text: "",
		}
	}

expense_draft_note : Ledger, List(Str) -> Str
expense_draft_note = |ledger, people| {
	description = ledger.description.trim()
	if description.is_empty() {
		"Describe the expense to add it."
	} else if ledger.items.any(|item| item.description == description) {
		"${description} is already recorded."
	} else {
		match Bill.parse_cents(ledger.amount_text) {
			Err(_) => "Enter an amount such as 12.50."
			Ok(cents) =>
				if !people.contains(ledger.payer) {
					"Choose who paid."
				} else {
					"Ready to add ${description} for ${Bill.money(cents)}."
				}
		}
	}
}

# --- derived text -------------------------------------------------

## Both sides of one person's position, as a single muted numeric line beside
## their name.
person_totals_line : Bill.Balance -> Str
person_totals_line = |row| "Paid ${Bill.money(row.paid_cents)} / owes ${Bill.money(row.owed_cents)}"

## The balance itself is rendered as a signed figure, not a sentence: the sign
## and the colour say which way the money goes.
person_net_line : Bill.Balance -> Str
person_net_line = |row|
	if row.net_cents > 0 {
		"+${Bill.money(row.net_cents)}"
	} else {
		Bill.money(row.net_cents)
	}

## Emerald when the trip owes them, red when they owe the trip. The colour and
## the figure come off the same balance signal, so they cannot disagree.
person_net_class : Bill.Balance -> Str
person_net_class = |row| {
	tone =
		if row.net_cents > 0 {
			"text-emerald-700"
		} else if row.net_cents < 0 {
			"text-red-700"
		} else {
			"text-zinc-500"
		}
	"text-lg font-semibold tabular-nums ${tone}"
}

person_locked : Bill.Balance -> Bool
person_locked = |row| row.payer_count > 0

person_removal_line : Bill.Balance -> Str
person_removal_line = |row|
	if row.payer_count == 0 {
		"Can leave the trip"
	} else if row.payer_count == 1 {
		"Payer on 1 expense"
	} else {
		"Payer on ${row.payer_count.to_str()} expenses"
	}

person_removal_class : Bill.Balance -> Str
person_removal_class = |row|
	if row.payer_count == 0 {
		"badge badge-neutral"
	} else {
		"badge badge-warn"
	}

## An expense's status is a badge when something is wrong with it and a plain
## numeric value when it is counting normally.
status_class : [Ok, Warn, Danger] -> Str
status_class = |tone|
	match tone {
		Ok => "value numeric"
		Warn => "badge badge-warn"
		Danger => "badge badge-danger"
	}

people_line : List(Str) -> Str
people_line = |names| Bill.count(names).to_str()

expense_line : List(Bill.Expense) -> Str
expense_line = |items| Bill.count(items).to_str()

total_line : List(Bill.Expense), List(Str) -> Str
total_line = |items, names| Bill.money(Bill.total_cents(items, names))

## What the trip would cost each person if every expense were shared by
## everyone. Derived from the same two sources as the total, never stored.
share_line : List(Bill.Expense), List(Str) -> Str
share_line = |items, names| {
	heads = Bill.count(names)
	if heads == 0 {
		Bill.money(0)
	} else {
		Bill.money(Bill.total_cents(items, names).div_trunc_by(heads))
	}
}

## Always `$0.00`: every expense that counts is split into shares that add back
## up to it, so the paid and owed sides cancel exactly.
check_line : List(Bill.Balance) -> Str
check_line = |rows| Bill.money(Bill.net_check(rows))

settlement_summary : List(Bill.Transfer) -> Str
settlement_summary = |plan| {
	total = Bill.count(plan)
	if total == 0 {
		"Settled up"
	} else if total == 1 {
		"1 transfer"
	} else {
		"${total.to_str()} transfers"
	}
}

settlement_badge_class : List(Bill.Transfer) -> Str
settlement_badge_class = |plan|
	if plan.is_empty() {
		"badge badge-ok"
	} else {
		"badge badge-info"
	}

## A validation note reads as a neutral requirement until there is input that
## cannot be accepted, and only then turns red.
note_tone : Bool -> Str
note_tone = |bad| if bad { "text-xs font-medium text-red-600" } else { "hint" }

# --- classes -----------------------------------------------------------------

page_class : Str
page_class = "app-shell"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

row_class : Str
row_class = "card gap-3 p-4"

input_class : Str
input_class = "input"

amount_input_class : Str
amount_input_class = "input numeric text-right"

# --- view --------------------------------------------------------------------

main : () -> Elem
main = ||
	Ui.state(
		initial_roster,
		|roster|
			Ui.state(
				initial_ledger,
				|ledger| {
					# The two sources.
					people : Signal.Signal(List(Str))
					people = roster.signal().map(|value| value.names)
					expenses : Signal.Signal(List(Bill.Expense))
					expenses = ledger.signal().map(|value| value.items)

					# Fan-in: the only value that needs both sources at once.
					person_rows : Signal.Signal(List(Bill.Balance))
					person_rows = Signal.map2(people, expenses, Bill.balances)

					# Second hop of the chain: the plan is a function of balances.
					settlement : Signal.Signal(List(Bill.Transfer))
					settlement = person_rows.map(Bill.settle)

					# Fan-in again, for the expense list's display records.
					expense_views : Signal.Signal(List(Bill.View))
					expense_views = Signal.map2(expenses, people, Bill.views)

					trip : Signal.Signal({ people : List(Str), expenses : List(Bill.Expense) })
					trip = { people: people, expenses: expenses }.Signal

					totals : Totals
					totals = {
						people_count: people.map(people_line),
						expense_count: expenses.map(expense_line),
						total: trip.map(|value| total_line(value.expenses, value.people)),
						share: trip.map(|value| share_line(value.expenses, value.people)),
						check: person_rows.map(check_line),
						# A third fan-in: one summary line built from the roster, the
						# ledger, and the balances at once.
						summary: Signal.map2(
							trip,
							person_rows,
							|value, rows|
								"${people_line(value.people)} people, ${expense_line(value.expenses)} expenses, ${total_line(value.expenses, value.people)} recorded, balances check ${check_line(rows)}",
						),
					}

					has_people = people.map(|names| !names.is_empty())
					has_expenses = expenses.map(|items| !items.is_empty())
					has_transfers = settlement.map(|plan| !plan.is_empty())

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Split the Bill",
								"app-header",
								[
									Html.heading_c("Split the Bill", "app-title"),
									Html.paragraph_c(
										"Three days at the lake house. Record what each person paid, then read back the shortest set of transfers that squares everyone up. Balances and the settlement plan are computed from the roster and the ledger; nothing derived is stored.",
										"app-subtitle",
									),
								],
							),
							totals_panel(totals),
							settlement_panel(settlement, has_transfers),
							people_panel(roster, person_rows, has_people),
							expenses_panel(ledger, people, expense_views, has_expenses),
						],
					)
				},
			),
	)

## The five figures the trip is judged by, as signals. Grouped into a record so
## the totals panel takes one argument instead of six.
Totals : {
	people_count : Signal.Signal(Str),
	expense_count : Signal.Signal(Str),
	total : Signal.Signal(Str),
	share : Signal.Signal(Str),
	check : Signal.Signal(Str),
	summary : Signal.Signal(Str),
}

totals_panel : Totals -> Elem
totals_panel = |totals|
	Html.section_c(
		"Trip totals",
		panel_class,
		[
			Html.heading_c("Trip totals", "panel-title"),
			Html.div_c(
				"stat-grid",
				[
					stat_cell("Bill total", totals.total, "trip-total"),
					stat_cell("Per person", totals.share, "trip-person-share"),
					stat_cell("People", totals.people_count, "trip-people-count"),
					stat_cell("Expenses", totals.expense_count, "trip-expense-count"),
				],
			),
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3 border-t border-zinc-200 pt-3",
				[
					Html.div_c(
						"flex items-center gap-2",
						[
							Html.paragraph_c("Balances check", "hint"),
							Html.paragraph_s_attrs(
								totals.check,
								[Html.class_attr("badge badge-ok numeric"), Html.test_id("trip-balances-check")],
							),
						],
					),
					Html.paragraph_s_attrs(
						totals.summary,
						[Html.class_attr("hint numeric"), Html.test_id("trip-summary")],
					),
				],
			),
		],
	)

## One metric: a caption and a figure, never a sentence.
stat_cell : Str, Signal.Signal(Str), Str -> Elem
stat_cell = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value"), Html.test_id(id)]),
		],
	)

# --- settlement --------------------------------------------------------------

settlement_panel : Signal.Signal(List(Bill.Transfer)), Signal.Signal(Bool) -> Elem
settlement_panel = |settlement, has_transfers|
	Html.section_c(
		"Settlement plan",
		panel_class,
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3",
				[
					Html.heading_c("Settlement plan", "panel-title"),
					Html.paragraph_s_attrs(
						settlement.map(settlement_summary),
						[
							Html.class_attr_s(settlement.map(settlement_badge_class)),
							Html.test_id("settlement-summary"),
						],
					),
				],
			),
			Ui.when(
				has_transfers,
				|| Html.div_c(
					"grid gap-2",
					[
						Ui.each_str(
							settlement,
							Bill.transfer_key,
							|key, transfer| transfer_row(key, transfer),
						),
					],
				),
				|| Html.paragraph_c("Everyone is square. No transfers needed.", "empty-state"),
			),
		],
	)

## One directional row of the plan: who pays whom on the left, how much on the
## right, in tabular figures so a column of transfers lines up.
transfer_row : Str, Signal.Signal(Bill.Transfer) -> Elem
transfer_row = |key, transfer|
	Html.div_c(
		"flex flex-wrap items-center justify-between gap-3 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2",
		[
			Html.paragraph_s_attrs(
				transfer.map(Bill.transfer_line),
				[Html.class_attr("value"), Html.test_id("transfer-${key}")],
			),
			Html.paragraph_s_attrs(
				transfer.map(Bill.transfer_amount),
				[
					Html.class_attr("text-base font-semibold tabular-nums text-emerald-700"),
					Html.test_id("transfer-${key}-amount"),
				],
			),
		],
	)

# --- people ------------------------------------------------------------------

people_panel : Ui.State(Roster), Signal.Signal(List(Bill.Balance)), Signal.Signal(Bool) -> Elem
people_panel = |roster, person_rows, has_people| {
	roster_signal = roster.signal()

	Html.section_c(
		"People",
		panel_class,
		[
			Html.heading_c("People", "panel-title"),
			Html.form_label(
				"Add person form",
				[
					Html.class_attr("grid gap-3"),
					Html.on_submit_prevent_default(roster.on_unit(add_person)),
				],
				[
					Html.div_c(
						"toolbar",
						[
							Html.div_c(
								"field min-w-0 flex-1",
								[
									Html.paragraph_c("Name", "field-label"),
									Html.text_input_attrs(
										"New person name",
										roster_signal.map(|value| value.draft),
										[
											Html.class_attr(input_class),
											Html.attr("placeholder", "Priya Raman"),
											Html.aria_describedby("person-draft-note"),
										],
										roster.on_str(set_person_draft),
									),
								],
							),
							Html.action_button_attrs(
								Signal.const("Add person"),
								roster_signal.map(person_draft_blocked),
								[Html.class_attr("button"), Html.attr("type", "button")],
								roster.on_unit(add_person),
							),
						],
					),
					Html.paragraph_s_attrs(
						roster_signal.map(person_draft_note),
						[
							Html.attr("id", "person-draft-note"),
							Html.class_attr_s(
								roster_signal.map(|value| note_tone(person_draft_blocked(value) and (!value.draft.trim().is_empty()))),
							),
							Html.test_id("person-draft-note"),
						],
					),
				],
			),
			Ui.when(
				has_people,
				|| Html.div_c(
					"grid gap-2",
					[Ui.each_str(person_rows, |row| row.name, |name, row| person_row(roster, name, row))],
				),
				|| Html.paragraph_c("Nobody on the trip yet. Add someone to start.", "empty-state"),
			),
		],
	)
}

## One person's balance row: name, what they paid, what they owe, and the
## balance as a coloured figure. `name` is the row key, so every accessible name
## in here is static text while every value is a signal sink.
person_row : Ui.State(Roster), Str, Signal.Signal(Bill.Balance) -> Elem
person_row = |roster, name, row|
	Html.section_c(
		name,
		row_class,
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-4",
				[
					Html.div_c(
						"grid min-w-0 gap-1",
						[
							Html.heading_c(name, "card-title"),
							Html.paragraph_s_attrs(
								row.map(person_totals_line),
								[Html.class_attr("muted numeric"), Html.test_id("person-${name}-totals")],
							),
						],
					),
					Html.div_c(
						"flex items-center gap-4",
						[
							Html.div_c(
								"grid justify-items-end gap-0.5",
								[
									Html.paragraph_c("Balance", "stat-label"),
									Html.paragraph_s_attrs(
										row.map(person_net_line),
										[
											Html.class_attr_s(row.map(person_net_class)),
											Html.test_id("person-${name}-net"),
										],
									),
								],
							),
							Html.action_button_attrs(
								Signal.const("Remove ${name}"),
								row.map(person_locked),
								[Html.class_attr("button button-sm"), Html.attr("type", "button")],
								roster.on_unit(remove_person(name)),
							),
						],
					),
				],
			),
			Html.paragraph_s_attrs(
				row.map(person_removal_line),
				[Html.class_attr_s(row.map(person_removal_class)), Html.test_id("person-${name}-removal")],
			),
		],
	)

# --- expenses ----------------------------------------------------------------

expenses_panel : Ui.State(Ledger), Signal.Signal(List(Str)), Signal.Signal(List(Bill.View)), Signal.Signal(Bool) -> Elem
expenses_panel = |ledger, people, expense_views, has_expenses| {
	ledger_signal = ledger.signal()
	draft_note = Signal.map2(ledger_signal, people, expense_draft_note)
	# Fan-in: the draft is only addable when it is complete *and* the chosen payer
	# is still on the trip, which only the roster knows.
	add_blocked =
		Signal.map2(ledger_signal, people, |value, names| !(expense_draft_ready(value) and names.contains(value.payer)))

	Html.section_c(
		"Expenses",
		panel_class,
		[
			Html.heading_c("Expenses", "panel-title"),
			Html.form_label(
				"Add expense form",
				[
					Html.class_attr("grid gap-3"),
					Html.on_submit_prevent_default(ledger.on_unit(add_expense)),
				],
				[
					Html.div_c(
						"grid gap-3 sm:grid-cols-3",
						[
							Html.div_c(
								"field min-w-0",
								[
									Html.paragraph_c("Description", "field-label"),
									Html.text_input_attrs(
										"New expense description",
										ledger_signal.map(|value| value.description),
										[Html.class_attr(input_class), Html.attr("placeholder", "Groceries")],
										ledger.on_str(set_expense_description),
									),
								],
							),
							Html.div_c(
								"field min-w-0",
								[
									Html.paragraph_c("Amount", "field-label"),
									Html.text_input_attrs(
										"New expense amount",
										ledger_signal.map(|value| value.amount_text),
										[
											Html.class_attr(amount_input_class),
											Html.attr("placeholder", "24.00"),
											Html.attr("inputmode", "decimal"),
										],
										ledger.on_str(set_expense_amount),
									),
								],
							),
							Html.div_c(
								"field min-w-0",
								[
									Html.paragraph_c("Paid by", "field-label"),
									Html.select_c(
										"New expense payer",
										ledger_signal.map(|value| value.payer),
										input_class,
										[Ui.each_str(people, |name| name, |name, _person| Html.option(name, name))],
										ledger.on_str(set_expense_payer),
									),
								],
							),
						],
					),
					Html.div_c(
						"flex flex-wrap items-center justify-between gap-3",
						[
							Html.paragraph_s_attrs(
								draft_note,
								[
									Html.class_attr_s(add_blocked.map(|blocked| note_tone(blocked))),
									Html.test_id("expense-draft-note"),
								],
							),
							Html.action_button_attrs(
								Signal.const("Add expense"),
								add_blocked,
								[Html.class_attr("button-primary"), Html.attr("type", "button")],
								ledger.on_unit(add_expense),
							),
						],
					),
				],
			),
			Ui.when(
				has_expenses,
				|| Html.div_c(
					"grid gap-2",
					[
						Ui.each_str(
							expense_views,
							|view| view.description,
							|description, view| expense_row(ledger, description, view),
						),
					],
				),
				|| Html.paragraph_c("No expenses yet. Record what someone paid for.", "empty-state"),
			),
		],
	)
}

## One expense card. The amount input is bound straight to the stored text, so
## typing never fights the control; cents are parsed downstream in `Bill`.
expense_row : Ui.State(Ledger), Str, Signal.Signal(Bill.View) -> Elem
expense_row = |ledger, description, view|
	Html.section_c(
		description,
		row_class,
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3",
				[
					Html.heading_c(description, "card-title"),
					Html.button_attrs(
						"Remove ${description}",
						[Html.class_attr("button-ghost button-sm"), Html.attr("type", "button")],
						ledger.on_unit(|current| { ..current, items: Bill.remove_expense(current.items, description) }),
					),
				],
			),
			Html.div_c(
				"grid gap-3 sm:grid-cols-2",
				[
					Html.div_c(
						"field",
						[
							Html.paragraph_c("Amount", "field-label"),
							Html.text_input_attrs(
								"${description} amount",
								view.map(|value| value.amount_text),
								[
									Html.class_attr(amount_input_class),
									Html.attr("placeholder", "24.00"),
									Html.attr("inputmode", "decimal"),
								],
								ledger.on_str(|current, text| { ..current, items: Bill.set_amount(current.items, description, text) }),
							),
						],
					),
					Html.div_c(
						"grid content-start gap-1",
						[
							Html.paragraph_c("Status", "stat-label"),
							Html.paragraph_s_attrs(
								view.map(|value| Bill.status_text(value.status)),
								[
									Html.class_attr_s(view.map(|value| status_class(Bill.status_tone(value.status)))),
									Html.test_id("expense-${description}-status"),
								],
							),
							Html.paragraph_s_attrs(
								view.map(|value| value.breakdown),
								[Html.class_attr("hint numeric"), Html.test_id("expense-${description}-shares")],
							),
						],
					),
				],
			),
			Html.div_c(
				"grid gap-2 border-t border-zinc-200 pt-3",
				[
					Html.paragraph_c("Split between", "stat-label"),
					Html.div_c(
						"flex flex-wrap gap-x-5 gap-y-2",
						[
							Ui.each_str(
								view.map(|value| value.members),
								|member| member.name,
								|name, member| share_row(ledger, { expense: description, person: name }, member),
							),
						],
					),
				],
			),
		],
	)

## One participation checkbox with its name drawn beside it. The accessible name
## stays fully qualified so the specs can address one expense's checkbox. The two
## names are passed as a record so the expense and the person cannot be swapped.
share_row : Ui.State(Ledger), { expense : Str, person : Str }, Signal.Signal(Bill.Member) -> Elem
share_row = |ledger, names, member|
	Html.div_c(
		"check-row",
		[
			Html.checkbox_c(
				"${names.expense} includes ${names.person}",
				member.map(|value| value.included),
				"checkbox",
				ledger.on_bool(
					|current, included| {
						..current,
						items: Bill.set_share(current.items, names.expense, names.person, included),
					},
				),
			),
			Html.text(names.person),
		],
	)
