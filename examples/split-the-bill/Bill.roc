## Pure domain for the trip expense splitter.
##
## Everything in this module is a plain function of the two source collections
## the app owns: the list of people and the list of expenses. Balances, splits,
## and the settlement plan are *computed* here and never stored, so `main.roc` can
## expose them as derived signals instead of fields it has to keep in sync.
##
## Money is integer minor units (cents) everywhere. The only text/number boundary
## is `Bill.parse_cents`, which turns the amount a user typed into cents once, at
## the edge. That keeps every split exact and every spec deterministic.
Bill := {}.{

	## One recorded expense. `amount_text` is exactly what the user typed; the
	## cents value is derived from it. `excluded` names the people who are *not*
	## sharing this expense, so a new expense defaults to "everyone" and a person
	## who leaves the trip drops out of every split automatically.
	Expense : {
		description : Str,
		amount_text : Str,
		payer : Str,
		excluded : List(Str),
	}

	## One person's share of one expense, in cents.
	Share : { name : Str, cents : I64 }

	## A person's position in the trip. `net_cents` is positive when the trip owes
	## them money. `payer_count` is how many expenses they paid for, which is what
	## decides whether they can leave the trip.
	Balance : {
		name : Str,
		paid_cents : I64,
		owed_cents : I64,
		net_cents : I64,
		payer_count : I64,
	}

	## One transfer in the settlement plan.
	Transfer : { from_name : Str, to_name : Str, cents : I64 }

	## One row of an expense's participation checklist.
	Member : { name : Str, included : Bool }

	## Why an expense row is in the state it is in. The badge caption and the tone
	## that badge is drawn in are both derived from this one value, so a row can
	## never show an error word in the ok colour.
	Status : [
		Unrecognised,
		PayerGone(Str),
		NobodySharing,
		Counted({ cents : I64, payer : Str, ways : I64 }),
	]

	## Display record for one expense row. It carries everything that row renders,
	## including its own participation checklist, so nothing inside the row has to
	## reach back out to the roster signal.
	View : {
		description : Str,
		amount_text : Str,
		payer : Str,
		members : List(Bill.Member),
		status : Bill.Status,
		breakdown : Str,
	}

	currency : Str
	currency = "$"

	## Render cents as text, e.g. `2084` -> `$20.84`.
	money : I64 -> Str
	money = |cents| {
		sign = if cents < 0 { "-" } else { "" }
		value = cents.abs()
		whole = value.div_trunc_by(100)
		rest = value.rem_by(100)
		padded = if rest < 10 { "0${rest.to_str()}" } else { rest.to_str() }
		"${sign}${Bill.currency}${whole.to_str()}.${padded}"
	}

	## Count a list as `I64` so cent arithmetic never mixes numeric types.
	count : List(a) -> I64
	count = |items| items.fold(0, |total, _item| total + 1)

	## Parse a typed amount into cents. Accepts `12`, `12.5`, `12.50`, and
	## surrounding whitespace. Rejects empty text, negatives, non-digits, and more
	## than two decimal places.
	parse_cents : Str -> Try(I64, [BadAmount])
	parse_cents = |raw| {
		text = raw.trim()
		match text.split_first(".") {
			Err(_) => Bill.whole_cents(text)
			Ok(parts) =>
				if parts.after.contains(".") {
					Err(BadAmount)
				} else {
					dollars_text = if parts.before.is_empty() { "0" } else { parts.before }
					dollars = Bill.whole_cents(dollars_text)?
					cents = Bill.fraction_cents(parts.after)?
					Ok(dollars + cents)
				}
		}
	}

	whole_cents : Str -> Try(I64, [BadAmount])
	whole_cents = |text|
		if text.starts_with("-") or text.starts_with("+") {
			Err(BadAmount)
		} else {
			value = Try.map_err(I64.from_str(text), |_| BadAmount)?
			if value < 0 { Err(BadAmount) } else { Ok(value * 100) }
		}

	fraction_cents : Str -> Try(I64, [BadAmount])
	fraction_cents = |text|
		if text.starts_with("-") or text.starts_with("+") {
			Err(BadAmount)
		} else {
			digits = Bill.count(text.to_utf8())
			value = Try.map_err(I64.from_str(text), |_| BadAmount)?
			if value < 0 {
				Err(BadAmount)
			} else if digits == 1 {
				Ok(value * 10)
			} else if digits == 2 {
				Ok(value)
			} else {
				Err(BadAmount)
			}
		}

	## Cents for an expense, treating unparseable text as zero.
	amount_cents : Bill.Expense -> I64
	amount_cents = |expense| Try.ok_or(Bill.parse_cents(expense.amount_text), 0)

	expect Bill.money(2084) == "$20.84"
	expect Bill.money(-500) == "-$5.00"
	expect Bill.money(7) == "$0.07"

	# Accepted: whole amounts, one or two decimal places, surrounding whitespace.
	expect Bill.parse_cents("12") == Ok(1200)
	expect Bill.parse_cents("12.5") == Ok(1250)
	expect Bill.parse_cents(" 12.50 ") == Ok(1250)
	expect Bill.parse_cents(".5") == Ok(50)
	expect Bill.parse_cents("0") == Ok(0)
	# Rejected: empty text, signs, three decimal places, two points, non-digits.
	expect Bill.parse_cents("") == Err(BadAmount)
	expect Bill.parse_cents("-5") == Err(BadAmount)
	expect Bill.parse_cents("+5") == Err(BadAmount)
	expect Bill.parse_cents("12.345") == Err(BadAmount)
	expect Bill.parse_cents("1.2.3") == Err(BadAmount)
	expect Bill.parse_cents("12x3") == Err(BadAmount)

	## The people actually sharing an expense, in trip order.
	participants : Bill.Expense, List(Str) -> List(Str)
	participants = |expense, people| people.drop_if(|name| expense.excluded.contains(name))

	## An expense only counts when someone on the trip paid for it and at least one
	## person on the trip is sharing it.
	is_counted : Bill.Expense, List(Str) -> Bool
	is_counted = |expense, people|
		people.contains(expense.payer) and (!Bill.participants(expense, people).is_empty())

	## Split an expense across its participants, in cents.
	##
	## Cents rarely divide evenly. Every participant pays `amount / n`, and the
	## first `amount % n` participants (in trip order) pay one extra cent. The
	## shares therefore always add back up to the exact amount, which is what keeps
	## the settlement plan summing to zero.
	shares : Bill.Expense, List(Str) -> List(Bill.Share)
	shares = |expense, people|
		if !Bill.is_counted(expense, people) {
			[]
		} else {
			members = Bill.participants(expense, people)
			total = Bill.amount_cents(expense)
			divisor = Bill.count(members)
			base = total.div_trunc_by(divisor)
			remainder = total.rem_by(divisor)
			members
				.fold(
					{ out: [], index: 0 },
					|acc, name| {
						extra = if acc.index < remainder { 1 } else { 0 }
						{
							out: acc.out.append({ name, cents: base + extra }),
							index: acc.index + 1,
						}
					},
				)
				.out
		}

	# 10 cents across 3 people: the leftover cent goes to the first participant,
	# and the shares still add back up to the exact amount.
	expect
		Bill.shares(
			{ description: "Dinner", amount_text: "0.10", payer: "Ben", excluded: [] },
			["Ana", "Ben", "Chloe"],
		)
		== [{ name: "Ana", cents: 4 }, { name: "Ben", cents: 3 }, { name: "Chloe", cents: 3 }]

	# An expense whose payer has left the trip is not split at all.
	expect
		Bill.shares(
			{ description: "Taxi", amount_text: "24.00", payer: "Dev", excluded: [] },
			["Ana", "Ben"],
		)
		== []

	## Total of every expense that counts.
	total_cents : List(Bill.Expense), List(Str) -> I64
	total_cents = |expenses, people|
		expenses
			.keep_if(|expense| Bill.is_counted(expense, people))
			.fold(0, |total, expense| total + Bill.amount_cents(expense))

	## Per-person balances. This is the fan-in point of the app: it is the only
	## thing that needs both source collections at once.
	balances : List(Str), List(Bill.Expense) -> List(Bill.Balance)
	balances = |people, expenses|
		people.map(
			|name| {
				# The expenses this person paid for and that count: both what they
				# paid and whether they may leave the trip are read off this one list.
				paid_for =
					expenses.keep_if(
						|expense| (expense.payer == name) and Bill.is_counted(expense, people),
					)
				paid = paid_for.fold(0, |total, expense| total + Bill.amount_cents(expense))
				owed =
					expenses.fold(
						0,
						|total, expense|
							total
							+ Bill.shares(expense, people)
								.keep_if(|share| share.name == name)
								.fold(0, |sum, share| sum + share.cents),
					)
				{
					name,
					paid_cents: paid,
					owed_cents: owed,
					net_cents: paid - owed,
					payer_count: Bill.count(paid_for),
				}
			},
		)

	## Sum of every net balance. Always `0` — the spec asserts it as an invariant.
	net_check : List(Bill.Balance) -> I64
	net_check = |rows| rows.fold(0, |total, row| total + row.net_cents)

	Account : { name : Str, net : I64 }

	account_at : List(Bill.Account), U64 -> Bill.Account
	account_at = |accounts, index| Try.ok_or(accounts.get(index), { name: "", net: 0 })

	adjust : List(Bill.Account), U64, I64 -> List(Bill.Account)
	adjust = |accounts, index, delta|
		Try.ok_or(accounts.update(index, |account| { ..account, net: account.net + delta }), accounts)

	## Index of the largest creditor (`Creditor`) or largest debtor (`Debtor`).
	## Ties keep the earlier person, so the plan is deterministic.
	extreme : List(Bill.Account), [Creditor, Debtor] -> [NoAccount, At(U64)]
	extreme = |accounts, side| {
		start : { best : [NoAccount, At(U64)], value : I64 }
		start = { best: NoAccount, value: 0 }
		accounts
			.fold_with_index(
				start,
				|acc, account, index| {
					better =
						match side {
							Creditor => account.net > acc.value
							Debtor => account.net < acc.value
						}
					if better { { best: At(index), value: account.net } } else { acc }
				},
			)
			.best
	}

	## Greedy settlement: repeatedly move as much as possible from the largest
	## debtor to the largest creditor. Each step zeroes at least one person, so at
	## most `people - 1` transfers are produced.
	settle : List(Bill.Balance) -> List(Bill.Transfer)
	settle = |rows|
		Bill.settle_loop(
			rows.map(|row| { name: row.name, net: row.net_cents }).drop_if(|account| account.net == 0),
			[],
		)

	settle_loop : List(Bill.Account), List(Bill.Transfer) -> List(Bill.Transfer)
	settle_loop = |accounts, plan|
		match Bill.extreme(accounts, Creditor) {
			NoAccount => plan
			At(creditor_index) =>
				match Bill.extreme(accounts, Debtor) {
					NoAccount => plan
					At(debtor_index) => {
						creditor = Bill.account_at(accounts, creditor_index)
						debtor = Bill.account_at(accounts, debtor_index)
						amount = creditor.net.min(debtor.net.negate())
						if amount <= 0 {
							plan
						} else {
							next =
								Bill.adjust(
									Bill.adjust(accounts, creditor_index, amount.negate()),
									debtor_index,
									amount,
								)
							Bill.settle_loop(
								next,
								plan.append({ from_name: debtor.name, to_name: creditor.name, cents: amount }),
							)
						}
					}
				}
		}

	## `Chloe pays Ana`. The amount is rendered beside it, in its own numeric cell,
	## so the settlement row reads as a direction and a figure rather than a
	## sentence.
	transfer_line : Bill.Transfer -> Str
	transfer_line = |transfer| "${transfer.from_name} pays ${transfer.to_name}"

	## The money side of one settlement row.
	transfer_amount : Bill.Transfer -> Str
	transfer_amount = |transfer| Bill.money(transfer.cents)

	## Stable key for a transfer row.
	transfer_key : Bill.Transfer -> Str
	transfer_key = |transfer| "${transfer.from_name}>${transfer.to_name}"

	ways : I64 -> Str
	ways = |n| if n == 1 { "1 way" } else { "${n.to_str()} ways" }

	## Classify one expense. This is the single place the four states are decided;
	## the caption and the tone below are both read back off the result, so they
	## cannot drift apart.
	status : Bill.Expense, List(Str) -> Bill.Status
	status = |expense, people|
		match Bill.parse_cents(expense.amount_text) {
			Err(_) => Unrecognised
			Ok(cents) =>
				if !people.contains(expense.payer) {
					PayerGone(expense.payer)
				} else {
					parts = Bill.shares(expense, people)
					if parts.is_empty() {
						NobodySharing
					} else {
						Counted({ cents, payer: expense.payer, ways: Bill.count(parts) })
					}
				}
		}

	## The badge caption for a status.
	status_text : Bill.Status -> Str
	status_text = |value|
		match value {
			Unrecognised => "Amount not recognised, counted as ${Bill.money(0)}"
			PayerGone(payer) => "${payer} is no longer on the trip"
			NobodySharing => "Nobody is sharing this"
			Counted(counted) =>
				"${Bill.money(counted.cents)} paid by ${counted.payer}, split ${Bill.ways(counted.ways)}"
		}

	## The tone that caption is drawn in.
	status_tone : Bill.Status -> [Ok, Warn, Danger]
	status_tone = |value|
		match value {
			Unrecognised => Warn
			PayerGone(_) => Danger
			NobodySharing => Warn
			Counted(_) => Ok
		}

	expect Bill.status_text(Unrecognised) == "Amount not recognised, counted as $0.00"
	expect Bill.status_text(PayerGone("Dev")) == "Dev is no longer on the trip"
	expect Bill.status_text(NobodySharing) == "Nobody is sharing this"
	expect
		Bill.status_text(Counted({ cents: 6250, payer: "Ben", ways: 3 }))
		== "$62.50 paid by Ben, split 3 ways"
	expect Bill.status_text(Counted({ cents: 100, payer: "Ana", ways: 1 })) == "$1.00 paid by Ana, split 1 way"

	# The balances of a trip always sum to zero, and the settlement plan moves
	# exactly that much money.
	expect
		Bill.net_check(
			Bill.balances(
				["Ana", "Ben", "Chloe"],
				[{ description: "Cabin", amount_text: "300.00", payer: "Ana", excluded: [] }],
			),
		)
		== 0

	expect
		Bill.settle(
			Bill.balances(
				["Ana", "Ben", "Chloe"],
				[{ description: "Cabin", amount_text: "300.00", payer: "Ana", excluded: [] }],
			),
		)
		== [
			{ from_name: "Ben", to_name: "Ana", cents: 10000 },
			{ from_name: "Chloe", to_name: "Ana", cents: 10000 },
		]

	## Display rows for the expense list.
	views : List(Bill.Expense), List(Str) -> List(Bill.View)
	views = |expenses, people|
		expenses.map(
			|expense| {
				parts = Bill.shares(expense, people)
				breakdown =
					if parts.is_empty() {
						"No shares"
					} else {
						Str.join_with(parts.map(|share| "${share.name} ${Bill.money(share.cents)}"), ", ")
					}
				members =
					people.map(|name| { name, included: !(expense.excluded.contains(name)) })
				{
					description: expense.description,
					amount_text: expense.amount_text,
					payer: expense.payer,
					members,
					status: Bill.status(expense, people),
					breakdown,
				}
			},
		)

	## Set one expense's amount text, leaving every other expense untouched.
	set_amount : List(Bill.Expense), Str, Str -> List(Bill.Expense)
	set_amount = |expenses, description, text|
		expenses.map(
			|expense|
				if expense.description == description {
					{ ..expense, amount_text: text }
				} else {
					expense
				},
		)

	## Include or exclude one person from one expense's split.
	set_share : List(Bill.Expense), Str, Str, Bool -> List(Bill.Expense)
	set_share = |expenses, description, name, included|
		expenses.map(
			|expense|
				if expense.description != description {
					expense
				} else if included {
					{ ..expense, excluded: expense.excluded.drop_if(|other| other == name) }
				} else if expense.excluded.contains(name) {
					expense
				} else {
					{ ..expense, excluded: expense.excluded.append(name) }
				},
		)

	## Remove one expense by description.
	remove_expense : List(Bill.Expense), Str -> List(Bill.Expense)
	remove_expense = |expenses, description|
		expenses.drop_if(|expense| expense.description == description)
}
