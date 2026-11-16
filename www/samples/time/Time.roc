## Small, pure rules this app chooses for ids and dates. These are app code,
## rather than a platform calendar or a cryptographic random generator.
Time := [].{

	# region seed
	## Fold the boot seed into the state of this app's SplitMix64 stream.
	seed_state : U128 -> U64
	seed_state = |seed| seed.to_u64_wrap().bitwise_xor(seed.shr_zf_wrap(64).to_u64_wrap())

	## Take one value and the next state. Wrapping arithmetic is the generator's
	## definition; it is never used to repair a timestamp or a date.
	next : U64 -> { state : U64, value : U64 }
	next = |state| {
		advanced = state.plus_wrap(0x9e3779b97f4a7c15)
		first = advanced.bitwise_xor(advanced.shr_zf_wrap(30)).times_wrap(0xbf58476d1ce4e5b9)
		second = first.bitwise_xor(first.shr_zf_wrap(27)).times_wrap(0x94d049bb133111eb)
		{ state: advanced, value: second.bitwise_xor(second.shr_zf_wrap(31)) }
	}

	## A fixed-width lowercase spelling keeps app ids independent of inspection.
	hex : U64 -> Str
	hex = |number| Str.join_with(
		[60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0].map(
			|shift| {
				index = number.shr_zf_wrap(shift).bitwise_and(15)
				["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"].get(index) ?? crash "Time.hex: a nibble is below sixteen"
			},
		),
		"",
	)

	# endregion seed

	# region calendar
	## Gregorian civil date from days since 1970-01-01. Floor division gives
	## days before the epoch their own date instead of truncating toward zero.
	civil_date : I64 -> { year : I64, month : U8, day : U8 }
	civil_date = |days| {
		shifted = days.to_i128() + 719468
		era = floor_div({ number: shifted, divisor: 146097 })
		day_of_era = shifted - era * 146097
		year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
		year = year_of_era + era * 400
		day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
		march_month = (5 * day_of_year + 2) // 153
		day = day_of_year - (153 * march_month + 2) // 5 + 1
		month = march_month + (if (march_month < 10) 3 else -9)
		# Every I64 day has an I64 year; month and day are respectively
		# 1..12 and 1..31. These narrowings cannot discard significant bits.
		{ year: (year + (if (month <= 2) 1 else 0)).to_i64_wrap(), month: month.to_u8_wrap(), day: day.to_u8_wrap() }
	}

	## UTC text for an HTML time element. This example supports civil years
	## 0001 through 9999 and reports an outside date instead of wrapping it.
	utc_text : I64 -> Try(Str, [OutsideCalendar])
	utc_text = |at_ms| {
		parts = calendar_parts({ at_ms, offset_minutes: 0 })?
		fraction = if (parts.millisecond == 0) "" else ".${pad({ number: parts.millisecond.to_u64(), width: 3 })}"
		Ok("${pad({ number: parts.year.to_u64_wrap(), width: 4 })}-${pad({ number: parts.month.to_u64(), width: 2 })}-${pad({ number: parts.day.to_u64(), width: 2 })}T${pad({ number: parts.hour.to_u64(), width: 2 })}:${pad({ number: parts.minute.to_u64(), width: 2 })}:${pad({ number: parts.second.to_u64(), width: 2 })}${fraction}Z")
	}

	# endregion calendar

	## The first preferred language selects this app's clock pattern: en-US
	## uses twelve hours, every other tag uses twenty-four. It is not CLDR.
	clock_text : { at_ms : I64, offset_minutes : I32, language : Str } -> Try(Str, [OutsideCalendar])
	clock_text = |{ at_ms, offset_minutes, language }| {
		parts = calendar_parts({ at_ms, offset_minutes })?
		minute = pad({ number: parts.minute.to_u64(), width: 2 })
		if language == "en-US" {
			hour = if (parts.hour % 12 == 0) 12 else parts.hour % 12
			Ok("${hour.to_str()}:${minute} ${if (parts.hour < 12) "AM" else "PM"}")
		} else {
			Ok("${pad({ number: parts.hour.to_u64(), width: 2 })}:${minute}")
		}
	}

	## A backwards wall-clock jump has no negative age. The subtraction is
	## widened, so even opposite I64 endpoints cannot overflow.
	relative : { now_ms : I64, captured_ms : I64 } -> Str
	relative = |{ now_ms, captured_ms }| {
		elapsed = now_ms.to_i128() - captured_ms.to_i128()
		minutes = elapsed // 60000
		if minutes < 1 {
			"just now"
		} else if minutes < 60 {
			"${minutes.to_str()} min ago"
		} else if minutes < 1440 {
			"${(minutes // 60).to_str()} hr ago"
		} else {
			days = minutes // 1440
			"${days.to_str()} ${if (days == 1) "day" else "days"} ago"
		}
	}
}

floor_div : { number : I128, divisor : I128 } -> I128
floor_div = |{ number, divisor }| {
	quotient = number // divisor
	if (number < 0 and number % divisor != 0) quotient - 1 else quotient
}

pad : { number : U64, width : U64 } -> Str
pad = |{ number, width }| {
	digits = number.to_str()
	if (digits.count_utf8_bytes() < width) "${Str.join_with(List.repeat("0", width - digits.count_utf8_bytes()), "")}${digits}" else digits
}

calendar_parts : { at_ms : I64, offset_minutes : I32 } -> Try({ year : I64, month : U8, day : U8, hour : U8, minute : U8, second : U8, millisecond : U16 }, [OutsideCalendar])
calendar_parts = |{ at_ms, offset_minutes }| {
	# I128 holds every I64 instant plus every I32 offset without wrapping.
	local_ms = at_ms.to_i128() + offset_minutes.to_i128() * 60000
	days = floor_div({ number: local_ms, divisor: 86400000 })
	# Even I64 endpoints plus an I32 offset have fewer than 107 billion
	# epoch days, so the narrowing to the calendar's I64 input is exact.
	date = Time.civil_date(days.to_i64_wrap())
	if date.year < 1 or date.year > 9999 {
		Err(OutsideCalendar)
	} else {
		within = local_ms - days * 86400000
		Ok({ year: date.year, month: date.month, day: date.day, hour: (within // 3600000).to_u8_wrap(), minute: (within // 60000 % 60).to_u8_wrap(), second: (within // 1000 % 60).to_u8_wrap(), millisecond: (within % 1000).to_u16_wrap() })
	}
}

## A fixed seed gives reproducible ids, including leading zeroes.
expect {
	first = Time.next(Time.seed_state(7))
	second = Time.next(first.state)
	[Time.hex(first.value), Time.hex(second.value)] == ["63cbe1e459320dd7", "044c3cd7f43c661c"]
}

## Both halves of the boot seed influence the app's generator state.
expect Time.seed_state(0x10000000000000007) == 6

## Epoch days on both sides of zero and Gregorian leap days are civil dates.
expect [-1, 0, 11016, 19782].map(Time.civil_date) == [
	{ year: 1969, month: 12, day: 31 },
	{ year: 1970, month: 1, day: 1 },
	{ year: 2000, month: 2, day: 29 },
	{ year: 2024, month: 2, day: 29 },
]

## A negative millisecond belongs to the previous second and previous day.
expect Time.utc_text(-1)? == "1969-12-31T23:59:59.999Z"

## The app clock has explicit twelve- and twenty-four-hour patterns.
expect [
	Time.clock_text({ at_ms: 0, offset_minutes: 600, language: "en-AU" })?,
	Time.clock_text({ at_ms: 0, offset_minutes: -300, language: "en-US" })?,
] == ["10:00", "7:00 PM"]

## Extreme timestamps and shifted timestamps fail this app's supported
## calendar rather than wrapping into a plausible date.
expect {
	[Time.utc_text(I64.lowest), Time.utc_text(I64.highest), Time.clock_text({ at_ms: I64.highest, offset_minutes: I32.highest, language: "en-AU" }), Time.clock_text({ at_ms: I64.lowest, offset_minutes: I32.lowest, language: "en-AU" })] == List.repeat(Err(OutsideCalendar), 4)
}

## Backwards clocks read just now, while very distant endpoints stay defined.
expect [Time.relative({ now_ms: -1, captured_ms: 0 }), Time.relative({ now_ms: 180000, captured_ms: 0 }), Time.relative({ now_ms: I64.highest, captured_ms: I64.lowest })] == ["just now", "3 min ago", "213503982334 days ago"]
