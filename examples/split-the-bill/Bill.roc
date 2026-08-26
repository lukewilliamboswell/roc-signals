## Pure domain for the trip expense splitter.
##
## Everything in this module is a plain function of the two source collections
## the app owns: the list of people and the list of expenses. Balances, splits,
## and the settlement plan are *computed* here and never stored, so `app.roc` can
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

	## Display record for one expense row. It carries everything that row renders,
	## including its own participation checklist, so nothing inside the row has to
	## reach back out to the roster signal.
	View : {
		description : Str,
		amount_text : Str,
		payer : Str,
		members : List(Bill.Member),
		status : Str,
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
					match Bill.whole_cents(dollars_text) {
						Err(_) => Err(BadAmount)
						Ok(dollars) =>
							match Bill.fraction_cents(parts.after) {
								Err(_) => Err(BadAmount)
								Ok(cents) => Ok(dollars + cents)
							}
					}
				}
		}
	}

	whole_cents : Str -> Try(I64, [BadAmount])
	whole_cents = |text|
		if text.starts_with("-") or text.starts_with("+") {
			Err(BadAmount)
		} else {
			match I64.from_str(text) {
				Err(_) => Err(BadAmount)
				Ok(value) => if value < 0 { Err(BadAmount) } else { Ok(value * 100) }
			}
		}

	fraction_cents : Str -> Try(I64, [BadAmount])
	fraction_cents = |text|
		if text.starts_with("-") or text.starts_with("+") {
			Err(BadAmount)
		} else {
			digits = Bill.count(text.to_utf8())
			match I64.from_str(text) {
				Err(_) => Err(BadAmount)
				Ok(value) =>
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
		}

	## Cents for an expense, treating unparseable text as zero.
	amount_cents : Bill.Expense -> I64
	amount_cents = |expense|
		match Bill.parse_cents(expense.amount_text) {
			Ok(cents) => cents
			Err(_) => 0
		}

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

	## Total of every expense that counts.
	total_cents : List(Bill.Expense), List(Str) -> I64
	total_cents = |expenses, people|
		expenses.fold(
			0,
			|total, expense|
				if Bill.is_counted(expense, people) {
					total + Bill.amount_cents(expense)
				} else {
					total
				},
		)

	## Per-person balances. This is the fan-in point of the app: it is the only
	## thing that needs both source collections at once.
	balances : List(Str), List(Bill.Expense) -> List(Bill.Balance)
	balances = |people, expenses|
		people.map(
			|name| {
				paid =
					expenses.fold(
						0,
						|total, expense|
							if (expense.payer == name) and Bill.is_counted(expense, people) {
								total + Bill.amount_cents(expense)
							} else {
								total
							},
					)
				owed =
					expenses.fold(
						0,
						|total, expense|
							total
							+ Bill.shares(expense, people)
								.fold(
									0,
									|sum, share| if share.name == name { sum + share.cents } else { sum },
								),
					)
				payer_count =
					expenses.fold(
						0,
						|total, expense|
							if (expense.payer == name) and Bill.is_counted(expense, people) {
								total + 1
							} else {
								total
							},
					)
				{ name, paid_cents: paid, owed_cents: owed, net_cents: paid - owed, payer_count }
			},
		)

	## Sum of every net balance. Always `0` — the spec asserts it as an invariant.
	net_check : List(Bill.Balance) -> I64
	net_check = |rows| rows.fold(0, |total, row| total + row.net_cents)

	Account : { name : Str, net : I64 }

	account_at : List(Bill.Account), U64 -> Bill.Account
	account_at = |accounts, index|
		match accounts.get(index) {
			Ok(account) => account
			Err(_) => { name: "", net: 0 }
		}

	adjust : List(Bill.Account), U64, I64 -> List(Bill.Account)
	adjust = |accounts, index, delta|
		match accounts.update(index, |account| { ..account, net: account.net + delta }) {
			Ok(next) => next
			Err(_) => accounts
		}

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

	## `Ana owes Bo $42.00`
	transfer_line : Bill.Transfer -> Str
	transfer_line = |transfer|
		"${transfer.from_name} owes ${transfer.to_name} ${Bill.money(transfer.cents)}"

	## Stable key for a transfer row.
	transfer_key : Bill.Transfer -> Str
	transfer_key = |transfer| "${transfer.from_name}>${transfer.to_name}"

	ways : I64 -> Str
	ways = |n| if n == 1 { "1 way" } else { "${n.to_str()} ways" }

	## Display rows for the expense list.
	views : List(Bill.Expense), List(Str) -> List(Bill.View)
	views = |expenses, people|
		expenses.map(
			|expense| {
				parts = Bill.shares(expense, people)
				status =
					match Bill.parse_cents(expense.amount_text) {
						Err(_) =>
							"${expense.description} status: amount not recognised, treated as ${Bill.money(0)}"
						Ok(_) =>
							if !people.contains(expense.payer) {
								"${expense.description} status: payer ${expense.payer} is not on the trip, excluded"
							} else if parts.is_empty() {
								"${expense.description} status: nobody is sharing it, excluded"
							} else {
								"${expense.description} status: ${Bill.money(Bill.amount_cents(expense))} paid by ${expense.payer}, split ${Bill.ways(Bill.count(parts))}"
							}
					}
				breakdown =
					if parts.is_empty() {
						"${expense.description} shares: none"
					} else {
						joined =
							Str.join_with(parts.map(|share| "${share.name} ${Bill.money(share.cents)}"), ", ")
						"${expense.description} shares: ${joined}"
					}
				members =
					people.map(|name| { name, included: !(expense.excluded.contains(name)) })
				{
					description: expense.description,
					amount_text: expense.amount_text,
					payer: expense.payer,
					members,
					status,
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
