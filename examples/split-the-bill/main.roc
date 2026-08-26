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
initial_roster = { names: ["Ana", "Bo", "Cy"], draft: "" }

initial_ledger : Ledger
initial_ledger = {
	items: [
		{ description: "Cabin", amount_text: "300.00", payer: "Ana", excluded: [] },
		{ description: "Dinner", amount_text: "62.50", payer: "Bo", excluded: [] },
		{ description: "Taxi", amount_text: "24.00", payer: "Cy", excluded: ["Ana"] },
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
		"Person form: enter a name"
	} else if roster.names.contains(name) {
		"Person form: ${name} is already on the trip"
	} else {
		"Person form: ready to add ${name}"
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
	amount_ok =
		match Bill.parse_cents(ledger.amount_text) {
			Ok(_) => True
			Err(_) => False
		}
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
		"Expense form: enter a description"
	} else if ledger.items.any(|item| item.description == description) {
		"Expense form: ${description} is already recorded"
	} else {
		match Bill.parse_cents(ledger.amount_text) {
			Err(_) => "Expense form: enter an amount such as 12.50"
			Ok(cents) =>
				if !people.contains(ledger.payer) {
					"Expense form: choose who paid"
				} else {
					"Expense form: ready to add ${description} for ${Bill.money(cents)}"
				}
		}
	}
}

# --- derived text ------------------------------------------------------------

person_totals_line : Bill.Balance -> Str
person_totals_line = |row|
	"Totals: paid ${Bill.money(row.paid_cents)}, owes ${Bill.money(row.owed_cents)}"

person_net_line : Bill.Balance -> Str
person_net_line = |row|
	if row.net_cents > 0 {
		"Net: is owed ${Bill.money(row.net_cents)}"
	} else if row.net_cents < 0 {
		"Net: owes ${Bill.money(row.net_cents.abs())}"
	} else {
		"Net: settled up"
	}

person_locked : Bill.Balance -> Bool
person_locked = |row| row.payer_count > 0

person_removal_line : Bill.Balance -> Str
person_removal_line = |row|
	if row.payer_count == 0 {
		"Removal: allowed"
	} else if row.payer_count == 1 {
		"Removal: blocked, payer on 1 expense"
	} else {
		"Removal: blocked, payer on ${row.payer_count.to_str()} expenses"
	}

people_line : List(Str) -> Str
people_line = |names| "People on the trip: ${Bill.count(names).to_str()}"

expense_line : List(Bill.Expense) -> Str
expense_line = |items| "Expenses recorded: ${Bill.count(items).to_str()}"

total_line : List(Bill.Expense), List(Str) -> Str
total_line = |items, names| "Trip total: ${Bill.money(Bill.total_cents(items, names))}"

## Always `$0.00`: every expense that counts is split into shares that add back
## up to it, so the paid and owed sides cancel exactly.
check_line : List(Bill.Balance) -> Str
check_line = |rows| "Balances check: ${Bill.money(Bill.net_check(rows))}"

settlement_summary : List(Bill.Transfer) -> Str
settlement_summary = |plan| {
	total = Bill.count(plan)
	if total == 0 {
		"Settlement: everyone is settled up"
	} else if total == 1 {
		"Settlement: 1 transfer"
	} else {
		"Settlement: ${total.to_str()} transfers"
	}
}

# --- classes -----------------------------------------------------------------

page_class = "grid gap-5"

panel_class = "panel grid gap-4 p-4"

row_class = "panel grid gap-2 p-4"

form_class = "grid gap-3"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

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

					people_count_text = people.map(people_line)
					expense_count_text = expenses.map(expense_line)
					total_text = trip.map(|value| total_line(value.expenses, value.people))
					check_text = person_rows.map(check_line)

					# A third fan-in: one screen-reader summary of the whole trip, built
					# from all three derived collections at once.
					# A third fan-in: one summary line built from the roster, the ledger,
					# and the balances at once.
					summary_text =
						Signal.map2(
							trip,
							person_rows,
							|value, rows|
								"${people_line(value.people)} / ${expense_line(value.expenses)} / ${total_line(value.expenses, value.people)} / ${check_line(rows)}",
						)

					has_people = people.map(|names| !names.is_empty())
					has_expenses = expenses.map(|items| !items.is_empty())

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Split the Bill",
								panel_class,
								[
									Html.heading_c("Split the Bill", "text-3xl font-semibold text-zinc-950"),
									Html.paragraph_c(
										"Add the people on the trip, record what each person paid, and read back who owes whom. Balances and the settlement plan are computed from the roster and the ledger; nothing derived is stored.",
										"max-w-3xl text-sm text-zinc-700",
									),
								],
							),
							people_panel(roster, person_rows, has_people),
							expenses_panel(ledger, people, expense_views, has_expenses),
							Html.section_c(
								"Settlement plan",
								panel_class,
								[
									Html.heading_c("Settlement plan", "text-xl font-semibold text-zinc-950"),
									Html.paragraph_s_attrs(
										settlement.map(settlement_summary),
										[
											Html.class_attr("text-sm font-medium text-zinc-900"),
											Html.test_id("settlement-summary"),
										],
									),
									Ui.each_str(
										settlement,
										Bill.transfer_key,
										|key, transfer|
											Html.paragraph_s_attrs(
												transfer.map(Bill.transfer_line),
												[Html.class_attr("text-sm text-zinc-700"), Html.test_id("transfer-${key}")],
											),
									),
								],
							),
							Html.section_c(
								"Trip totals",
								panel_class,
								[
									Html.heading_c("Trip totals", "text-xl font-semibold text-zinc-950"),
									Html.paragraph_s_attrs(people_count_text, [Html.test_id("trip-people-count")]),
									Html.paragraph_s_attrs(expense_count_text, [Html.test_id("trip-expense-count")]),
									Html.paragraph_s_attrs(total_text, [Html.test_id("trip-total")]),
									Html.paragraph_s_attrs(check_text, [Html.test_id("trip-balances-check")]),
									Html.paragraph_s_attrs(
										summary_text,
										[Html.class_attr("text-sm text-zinc-600"), Html.test_id("trip-summary")],
									),
								],
							),
						],
					)
				},
			),
	)

people_panel : Ui.State(Roster), Signal.Signal(List(Bill.Balance)), Signal.Signal(Bool) -> Elem
people_panel = |roster, person_rows, has_people| {
	roster_signal = roster.signal()

	Html.section_c(
		"People",
		panel_class,
		[
			Html.heading_c("People", "text-xl font-semibold text-zinc-950"),
			Html.form_label(
				"Add person form",
				[
					Html.class_attr(form_class),
					Html.on_submit_prevent_default(roster.on_unit(add_person)),
				],
				[
					Html.text_input_c(
						"New person name",
						roster_signal.map(|value| value.draft),
						input_class,
						roster.on_str(set_person_draft),
					),
					Html.action_button_attrs(
						Signal.const("Add person"),
						roster_signal.map(person_draft_blocked),
						[Html.class_attr("button-primary"), Html.attr("type", "button")],
						roster.on_unit(add_person),
					),
					Html.paragraph_s_attrs(
						roster_signal.map(person_draft_note),
						[Html.class_attr("text-sm text-zinc-700"), Html.test_id("person-draft-note")],
					),
				],
			),
			Ui.when(
				has_people,
				|| Ui.each_str(person_rows, |row| row.name, |name, row| person_row(roster, name, row)),
				|| Html.paragraph_c("No people yet, add someone to start.", "text-sm text-zinc-600"),
			),
		],
	)
}

## One person's balance card. `name` is the row key, so every accessible name in
## here is static text while every value is a signal sink.
person_row : Ui.State(Roster), Str, Signal.Signal(Bill.Balance) -> Elem
person_row = |roster, name, row|
	Html.section_c(
		name,
		row_class,
		[
			Html.heading_c(name, "text-lg font-semibold text-zinc-950"),
			Html.paragraph_s_attrs(
				row.map(person_totals_line),
				[Html.class_attr("text-sm text-zinc-700"), Html.test_id("person-${name}-totals")],
			),
			Html.paragraph_s_attrs(
				row.map(person_net_line),
				[Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("person-${name}-net")],
			),
			Html.paragraph_s_attrs(
				row.map(person_removal_line),
				[Html.class_attr("text-sm text-zinc-600"), Html.test_id("person-${name}-removal")],
			),
			Html.action_button_attrs(
				Signal.const("Remove ${name}"),
				row.map(person_locked),
				[Html.class_attr("button"), Html.attr("type", "button")],
				roster.on_unit(remove_person(name)),
			),
		],
	)

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
			Html.heading_c("Expenses", "text-xl font-semibold text-zinc-950"),
			Html.form_label(
				"Add expense form",
				[
					Html.class_attr(form_class),
					Html.on_submit_prevent_default(ledger.on_unit(add_expense)),
				],
				[
					Html.text_input_c(
						"New expense description",
						ledger_signal.map(|value| value.description),
						input_class,
						ledger.on_str(set_expense_description),
					),
					Html.text_input_c(
						"New expense amount",
						ledger_signal.map(|value| value.amount_text),
						input_class,
						ledger.on_str(set_expense_amount),
					),
					Html.select_c(
						"New expense payer",
						ledger_signal.map(|value| value.payer),
						input_class,
						[Ui.each_str(people, |name| name, |name, _person| Html.option(name, name))],
						ledger.on_str(set_expense_payer),
					),
					Html.action_button_attrs(
						Signal.const("Add expense"),
						add_blocked,
						[Html.class_attr("button-primary"), Html.attr("type", "button")],
						ledger.on_unit(add_expense),
					),
					Html.paragraph_s_attrs(
						draft_note,
						[Html.class_attr("text-sm text-zinc-700"), Html.test_id("expense-draft-note")],
					),
				],
			),
			Ui.when(
				has_expenses,
				|| Ui.each_str(
					expense_views,
					|view| view.description,
					|description, view| expense_row(ledger, description, view),
				),
				|| Html.paragraph_c("No expenses yet, record what someone paid for.", "text-sm text-zinc-600"),
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
			Html.heading_c(description, "text-lg font-semibold text-zinc-950"),
			Html.text_input_c(
				"${description} amount",
				view.map(|value| value.amount_text),
				input_class,
				ledger.on_str(|current, text| { ..current, items: Bill.set_amount(current.items, description, text) }),
			),
			Html.paragraph_s_attrs(
				view.map(|value| value.status),
				[Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("expense-${description}-status")],
			),
			Html.paragraph_s_attrs(
				view.map(|value| value.breakdown),
				[Html.class_attr("text-sm text-zinc-700"), Html.test_id("expense-${description}-shares")],
			),
			Ui.each_str(
				view.map(|value| value.members),
				|member| member.name,
				|name, member|
					Html.checkbox_c(
						"${description} includes ${name}",
						member.map(|value| value.included),
						"rounded border-zinc-300",
						ledger.on_bool(
							|current, included| {
								..current,
								items: Bill.set_share(current.items, description, name, included),
							},
						),
					),
			),
			Html.button_attrs(
				"Remove ${description}",
				[Html.class_attr("button"), Html.attr("type", "button")],
				ledger.on_unit(|current| { ..current, items: Bill.remove_expense(current.items, description) }),
			),
		],
	)
