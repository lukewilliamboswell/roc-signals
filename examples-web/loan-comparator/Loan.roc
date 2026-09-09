Loan :: [].{

	## Parsed, validated loan inputs. All money is integer minor units (cents),
	## and the annual rate is integer basis points, so every figure below is
	## exactly reproducible on any target.
	Params : {
		principal : U64,
		rate_bp : U64,
		term : U64,
		extra : U64,
	}

	## One month of an amortisation schedule.
	Row : {
		month : U64,
		interest : U64,
		principal_paid : U64,
		balance : U64,
	}

	## The expensive derived value: a full amortisation schedule plus the
	## aggregate figures several parts of the UI read from it.
	Schedule : {
		payment : U64,
		rows : List(Row),
		total_interest : U64,
		total_paid : U64,
		months : U64,
		final_balance : U64,
	}

	## Presentation-free summary used for the cross-scenario comparison.
	Summary : {
		id : Str,
		name : Str,
		payment : U64,
		months : U64,
		total_interest : U64,
		total_paid : U64,
	}

	## Draft text held in each scenario's `Ui.state`.
	Draft : {
		principal : Str,
		rate : Str,
		term : Str,
		extra : Str,
	}

	## Which draft field failed to parse. The badge text is derived from these
	## tags; nothing downstream inspects the sentence to work out what broke.
	Field := [Principal, Rate, Term, Extra].{
		is_eq : Loan.Field, Loan.Field -> Bool
		is_eq = |left, right|
			match left {
				Principal => match right {
					Principal => True
					_ => False
				}
				Rate => match right {
					Rate => True
					_ => False
				}
				Term => match right {
					Term => True
					_ => False
				}
				Extra => match right {
					Extra => True
					_ => False
				}
			}

		to_str : Loan.Field -> Str
		to_str = |field|
			match field {
				Principal => "principal"
				Rate => "rate"
				Term => "term"
				Extra => "extra"
			}
	}

	## The verdict on a whole draft: either every field parsed, or these ones
	## did not.
	Validation := [Valid, Invalid(List(Loan.Field))].{
		is_eq : Loan.Validation, Loan.Validation -> Bool
		is_eq = |left, right|
			match left {
				Valid => match right {
					Valid => True
					_ => False
				}
				Invalid(left_fields) => match right {
					Invalid(right_fields) => Loan.same_fields(left_fields, right_fields)
					_ => False
				}
			}

		## Renders the message the badge shows.
		to_str : Loan.Validation -> Str
		to_str = |validation|
			match validation {
				Valid => "inputs ok"
				Invalid(fields) => "check ${Str.join_with(fields.map(Loan.Field.to_str), ", ")}"
			}

		is_valid : Loan.Validation -> Bool
		is_valid = |validation|
			match validation {
				Valid => True
				Invalid(_) => False
			}
	}

	same_fields : List(Loan.Field), List(Loan.Field) -> Bool
	same_fields = |left, right| {
		var $index = 0
		var $same = left.len() == right.len()

		while $index < left.len() {
			$same =
				$same
				and match (left.get($index), right.get($index)) {
					(Ok(left_field), Ok(right_field)) => Loan.Field.is_eq(left_field, right_field)
					_ => False
				}
			$index = $index + 1
		}

		$same
	}

	## A draft parsed into params plus the validation verdict.
	Parsed : {
		params : Params,
		validation : Loan.Validation,
	}

	max_term : U64
	max_term = 360

	pow10 : U64 -> U64
	pow10 = |places| {
		var $result = 1
		var $left = places
		while $left > 0 {
			$result = $result * 10
			$left = $left - 1
		}
		$result
	}

	## Parse a decimal string such as "6.5" into fixed-point minor units with
	## `places` fractional digits. Empty text and any non-digit character are
	## rejected; extra fractional digits are truncated. `U64.from_str` cannot
	## stand in here: it takes no scale and rejects the decimal point.
	parse_fixed : Str, U64 -> Try(U64, [InvalidNumber])
	parse_fixed = |text, places| {
		bytes = text.trim().to_utf8()
		var $whole = 0
		var $frac = 0
		var $frac_digits = 0
		var $digits = 0
		var $seen_dot = False
		var $ok = True
		var $index = 0

		while $index < bytes.len() {
			byte = bytes.get($index) ?? 0
			is_dot = byte == 46
			is_digit = (byte >= 48) and (byte <= 57)
			digit = if is_digit { U8.to_u64(byte) - 48 } else { 0 }

			$ok = $ok and (is_dot or is_digit) and (!(is_dot and $seen_dot))
			$whole = if is_digit and (!$seen_dot) { $whole * 10 + digit } else { $whole }
			$frac = if is_digit and $seen_dot and ($frac_digits < places) { $frac * 10 + digit } else { $frac }
			$frac_digits = if is_digit and $seen_dot { $frac_digits + 1 } else { $frac_digits }
			$digits = if is_digit { $digits + 1 } else { $digits }
			$seen_dot = $seen_dot or is_dot
			$index = $index + 1
		}

		kept = if $frac_digits < places { $frac_digits } else { places }
		value = $whole * Loan.pow10(places) + $frac * Loan.pow10(places - kept)

		if $ok and ($digits > 0) {
			Ok(value)
		} else {
			Err(InvalidNumber)
		}
	}

	## Parse a whole scenario draft. Invalid fields fall back to a safe value and
	## are named in the verdict so the UI can show an error path.
	parse_draft : Draft -> Parsed
	parse_draft = |draft| {
		principal_result = Loan.parse_fixed(draft.principal, 2)
		rate_result = Loan.parse_fixed(draft.rate, 2)
		term_result = Loan.parse_fixed(draft.term, 0)
		extra_result = Loan.parse_fixed(draft.extra, 2)

		principal = principal_result ?? 0
		rate_bp = rate_result ?? 0
		raw_term = term_result ?? 0
		extra = extra_result ?? 0

		term_ok = term_result.is_ok() and (raw_term >= 1) and (raw_term <= Loan.max_term)

		term = if raw_term < 1 { 1 } else if raw_term > Loan.max_term { Loan.max_term } else { raw_term }

		bad =
			[]
				.concat(if principal_result.is_ok() { [] } else { [Principal] })
				.concat(if rate_result.is_ok() { [] } else { [Rate] })
				.concat(if term_ok { [] } else { [Term] })
				.concat(if extra_result.is_ok() { [] } else { [Extra] })

		validation = if bad.is_empty() { Valid } else { Invalid(bad) }

		{ params: { principal, rate_bp, term, extra }, validation }
	}

	## A whole-number amount scales up to minor units with no fractional part.
	expect Loan.parse_fixed("2400", 2) == Ok(240000)
	## A single fractional digit is padded out to the full scale, not left short.
	expect Loan.parse_fixed("6.5", 2) == Ok(650)
	## Surrounding whitespace is trimmed and extra fractional digits truncate rather than round.
	expect Loan.parse_fixed(" 6.567 ", 2) == Ok(656)
	## A scale of zero places keeps a whole number exactly as written.
	expect Loan.parse_fixed("12", 0) == Ok(12)
	## Non-digit text is rejected instead of parsing as zero.
	expect Loan.parse_fixed("abc", 2) == Err(InvalidNumber)
	## Empty text is rejected, so a blank box is never read as $0.00.
	expect Loan.parse_fixed("", 2) == Err(InvalidNumber)
	## A second decimal point is rejected rather than silently ignored.
	expect Loan.parse_fixed("1.2.3", 2) == Err(InvalidNumber)

	## The badge text the UI shows, straight off the verdict tag.
	expect Loan.Validation.to_str(Valid) == "inputs ok"
	## A single bad field is named in the badge sentence.
	expect Loan.Validation.to_str(Invalid([Rate])) == "check rate"
	## Several bad fields are listed together in draft order, comma separated.
	expect Loan.Validation.to_str(Invalid([Rate, Term])) == "check rate, term"

	## A draft whose every box parses reports no failing fields.
	expect Loan.parse_draft({ principal: "2400", rate: "6", term: "12", extra: "0" }).validation.is_eq(Valid)
	## Only the boxes that actually failed are named, and in field order.
	expect Loan.parse_draft({ principal: "2400", rate: "abc", term: "zz", extra: "0" }).validation.is_eq(Invalid([Rate, Term]))
	## An out-of-range term still clamps into a usable params value.
	expect Loan.parse_draft({ principal: "2400", rate: "6", term: "0", extra: "0" }).params.term == 1

	## Interest accrued on `balance` for one month, floored to whole cents.
	monthly_interest : U64, U64 -> U64
	monthly_interest = |balance, rate_bp| balance * rate_bp / 120000

	## Run the amortisation until the balance clears or `max_months` elapses.
	simulate : U64, U64, U64, U64 -> Schedule
	simulate = |principal, rate_bp, pay, max_months| {
		var $balance = principal
		var $rows = []
		var $total_interest = 0
		var $total_paid = 0
		var $month = 0
		var $running = (principal > 0) and (max_months > 0)

		while $running {
			interest = Loan.monthly_interest($balance, rate_bp)
			owed = $balance + interest
			due = if pay < owed { pay } else { owed }
			principal_paid = if due > interest { due - interest } else { 0 }
			progressed = principal_paid > 0
			next_balance = if progressed { $balance - principal_paid } else { $balance }
			next_month = $month + 1

			$rows =
				if progressed {
					$rows.append({ month: next_month, interest, principal_paid, balance: next_balance })
				} else {
					$rows
				}
			$total_interest = if progressed { $total_interest + interest } else { $total_interest }
			$total_paid = if progressed { $total_paid + due } else { $total_paid }
			$month = if progressed { next_month } else { $month }
			$balance = next_balance
			$running = progressed and (next_balance > 0) and (next_month < max_months)
		}

		{
			payment: pay,
			rows: $rows,
			total_interest: $total_interest,
			total_paid: $total_paid,
			months: $month,
			final_balance: $balance,
		}
	}

	## Smallest whole-cent monthly payment that clears the loan within `term`.
	## Found by binary search over the simulation, which is exactly why the
	## schedule is worth memoising in one derived signal.
	required_payment : U64, U64, U64 -> U64
	required_payment = |principal, rate_bp, term| {
		if (principal == 0) or (term == 0) {
			0
		} else {
			var $low = 1
			var $high = principal + Loan.monthly_interest(principal, rate_bp) + 1

			while $low < $high {
				mid = ($low + $high) / 2
				attempt = Loan.simulate(principal, rate_bp, mid, term)
				cleared = attempt.final_balance == 0
				$low = if cleared { $low } else { mid + 1 }
				$high = if cleared { mid } else { $high }
			}

			$low
		}
	}

	## The full derived schedule for one scenario.
	schedule : Params -> Schedule
	schedule = |params| {
		base = Loan.required_payment(params.principal, params.rate_bp, params.term)
		Loan.simulate(params.principal, params.rate_bp, base + params.extra, params.term)
	}

	summarize : Str, Str, Schedule -> Summary
	summarize = |id, name, sched| {
		{
			id,
			name,
			payment: sched.payment,
			months: sched.months,
			total_interest: sched.total_interest,
			total_paid: sched.total_paid,
		}
	}

	month_paid : Schedule, U64 -> U64
	month_paid = |sched, month|
		if month == 0 {
			0
		} else {
			sched.rows.get(month - 1).map_ok(|row| row.interest + row.principal_paid) ?? 0
		}

	## True when the running totals have swapped places: they were ordered one
	## way and this month they are ordered the other. `EQ` on either side is
	## "no information yet", not a crossing.
	crossed : [LT, EQ, GT], [LT, EQ, GT] -> Bool
	crossed = |previous, step|
		match previous {
			LT => match step {
				GT => True
				_ => False
			}
			GT => match step {
				LT => True
				_ => False
			}
			EQ => False
		}

	u64_compare : U64, U64 -> [LT, EQ, GT]
	u64_compare = |left, right|
		if left < right { LT } else if left > right { GT } else { EQ }

	## First month at which the running total paid of two scenarios crosses over.
	## Returns 0 when the two never swap places.
	break_even_month : Schedule, Schedule -> U64
	break_even_month = |left, right| {
		limit = if left.months > right.months { left.months } else { right.months }
		var $month = 1
		var $left_total = 0
		var $right_total = 0
		var $sign = EQ
		var $found = 0

		while ($month <= limit) and ($found == 0) {
			$left_total = $left_total + Loan.month_paid(left, $month)
			$right_total = $right_total + Loan.month_paid(right, $month)
			step = Loan.u64_compare($left_total, $right_total)
			$found = if Loan.crossed($sign, step) { $month } else { $found }
			$sign =
				match step {
					EQ => $sign
					_ => step
				}
			$month = $month + 1
		}

		$found
	}

	## An initial ordering is not itself a crossing: there was nothing to swap from.
	expect Loan.crossed(EQ, GT) == False
	## Running totals that were behind and are now ahead have crossed over.
	expect Loan.crossed(LT, GT) == True
	## Holding the same ordering another month is not a fresh crossing.
	expect Loan.crossed(GT, GT) == False

	## "$1234.56" style formatting from integer cents.
	money : U64 -> Str
	money = |cents| {
		dollars = cents / 100
		rest = cents % 100
		pad = if rest < 10 { "0" } else { "" }
		"$${dollars.to_str()}.${pad}${rest.to_str()}"
	}

	## "6.50%" style formatting from integer basis points.
	percent : U64 -> Str
	percent = |basis_points| {
		whole = basis_points / 100
		rest = basis_points % 100
		pad = if rest < 10 { "0" } else { "" }
		"${whole.to_str()}.${pad}${rest.to_str()}%"
	}

	months_text : U64 -> Str
	months_text = |months|
		if months == 1 {
			"1 month"
		} else {
			"${months.to_str()} months"
		}

	## Zero cents still renders both decimal places.
	expect Loan.money(0) == "$0.00"
	## Cents are split off the dollars rather than shown as a raw integer.
	expect Loan.money(247862) == "$2478.62"
	## Basis points render as a two-decimal percentage.
	expect Loan.percent(650) == "6.50%"
	## A whole-percent rate still shows its trailing zeroes.
	expect Loan.percent(1200) == "12.00%"
	## A one-month payoff is singular.
	expect Loan.months_text(1) == "1 month"
	## Any other payoff length is plural.
	expect Loan.months_text(12) == "12 months"
}
