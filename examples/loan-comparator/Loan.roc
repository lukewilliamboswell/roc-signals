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

	## A draft parsed into params plus a human-readable validation message.
	Parsed : {
		params : Params,
		message : Str,
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
	## rejected; extra fractional digits are truncated.
	Parse : {
		ok : Bool,
		value : U64,
	}

	parse_fixed : Str, U64 -> Parse
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
			byte =
				match bytes.get($index) {
					Ok(value) => value
					Err(_) => 0
				}
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
			{ ok: True, value }
		} else {
			{ ok: False, value: 0 }
		}
	}

	## Parse a whole scenario draft. Invalid fields fall back to a safe value and
	## are reported in the message so the UI can show an error path.
	parse_draft : Draft -> Parsed
	parse_draft = |draft| {
		principal_result = Loan.parse_fixed(draft.principal, 2)
		rate_result = Loan.parse_fixed(draft.rate, 2)
		term_result = Loan.parse_fixed(draft.term, 0)
		extra_result = Loan.parse_fixed(draft.extra, 2)

		principal = principal_result.value
		rate_bp = rate_result.value
		raw_term = term_result.value
		extra = extra_result.value

		principal_ok = principal_result.ok
		rate_ok = rate_result.ok
		extra_ok = extra_result.ok
		term_ok = term_result.ok and (raw_term >= 1) and (raw_term <= Loan.max_term)

		term = if raw_term < 1 { 1 } else if raw_term > Loan.max_term { Loan.max_term } else { raw_term }

		bad =
			[]
				.concat(if principal_ok { [] } else { ["principal"] })
				.concat(if rate_ok { [] } else { ["rate"] })
				.concat(if term_ok { [] } else { ["term"] })
				.concat(if extra_ok { [] } else { ["extra"] })

		message =
			if bad.is_empty() {
				"inputs ok"
			} else {
				"check ${Str.join_with(bad, ", ")}"
			}

		{ params: { principal, rate_bp, term, extra }, message }
	}

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
			match sched.rows.get(month - 1) {
				Ok(row) => row.interest + row.principal_paid
				Err(_) => 0
			}
		}

	sign_of : U64, U64 -> I64
	sign_of = |left, right|
		if left > right {
			1
		} else if left < right {
			-1
		} else {
			0
		}

	## First month at which the running total paid of two scenarios crosses over.
	## Returns 0 when the two never swap places.
	break_even_month : Schedule, Schedule -> U64
	break_even_month = |left, right| {
		limit = if left.months > right.months { left.months } else { right.months }
		var $month = 1
		var $left_total = 0
		var $right_total = 0
		var $sign = Loan.sign_of(0, 0)
		var $found = 0

		while ($month <= limit) and ($found == 0) {
			$left_total = $left_total + Loan.month_paid(left, $month)
			$right_total = $right_total + Loan.month_paid(right, $month)
			step = Loan.sign_of($left_total, $right_total)
			$found = if ($sign != 0) and (step != 0) and (step != $sign) { $month } else { $found }
			$sign = if step != 0 { step } else { $sign }
			$month = $month + 1
		}

		$found
	}

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
}
