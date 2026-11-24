## Cell addressing and fixed-point numbers for the spreadsheet.
##
## Numbers are an `I64` scaled by `scale` (four decimal places), so arithmetic
## and formatting are exactly reproducible on every target.
Cells := [].{

	scale : I64
	scale = 10000

	col_count : U64
	col_count = 8

	row_count : U64
	row_count = 12

	cell_count : U64
	cell_count = 96

	col_letters : List(Str)
	col_letters = ["A", "B", "C", "D", "E", "F", "G", "H"]

	## "B2" for the index of column 1, row 1.
	ref_of : U64 -> Str
	ref_of = |index| {
		col = index % col_count
		row = index // col_count
		letter = col_letters.get(col) ?? "?"
		"${letter}${(row + 1).to_str()}"
	}

	## Parse "B2" into a cell index.
	index_of : Str -> Try(U64, [NotARef])
	index_of = |text| {
		parsed = Cells.parse_ref(text.to_utf8())?
		if parsed.rest.is_empty() {
			Ok(parsed.index)
		} else {
			Err(NotARef)
		}
	}

	byte_at : List(U8), U64 -> U8
	byte_at = |bytes, index| bytes.get(index) ?? 0

	is_digit : U8 -> Bool
	is_digit = |byte| byte >= '0' and byte <= '9'

	head_is_digit : List(U8) -> Bool
	head_is_digit = |bytes| Cells.is_digit(Cells.byte_at(bytes, 0))

	## Parse an unsigned decimal literal into fixed point.
	take_number : List(U8) -> Try({ value : I64, rest : List(U8) }, [NotANumber])
	take_number = |bytes| {
		number = take_magnitude(bytes)?
		value = Cells.checked_fixed(number.value) ? |_| NotANumber
		Ok({ value, rest: number.rest })
	}

	## Read a complete signed decimal, including the smallest cell number.
	read_number : Str -> Try(I64, [NotANumber])
	read_number = |source| {
		negative = source.starts_with("-")
		digits = if (negative) source.drop_prefix("-") else source
		number = take_magnitude(digits.to_utf8())?
		if !number.rest.is_empty() {
			return Err(NotANumber)
		}
		Cells.checked_fixed(if (negative) 0 - number.value else number.value).map_err(|_| NotANumber)
	}

	## Return a calculated fixed-point value only if it fits a cell.
	checked_fixed : I128 -> Try(I64, [Overflow])
	checked_fixed = |value|
		if (value < -9223372036854775808 or value > 9223372036854775807) Err(Overflow) else Ok(value.to_i64_wrap())

	## Parse a leading cell reference such as "B2".
	parse_ref : List(U8) -> Try({ index : U64, rest : List(U8) }, [NotARef])
	parse_ref = |bytes| {
		letter = Cells.byte_at(bytes, 0)
		if letter < 'A' or letter > 'H' {
			Err(NotARef)
		} else {
			digits = take_digits(bytes.drop_first(1), Cells.row_count.to_i128()) ? |_| NotARef
			if digits.digits == 0 or digits.value < 1 {
				Err(NotARef)
			} else {
				col = (letter - 'A').to_u64()
				row = (digits.value - 1).to_u64_wrap()
				Ok({ index: row * Cells.col_count + col, rest: digits.rest })
			}
		}
	}

	## Address bounds for either direction of a rectangular selection.
	Bounds : { top : U64, bottom : U64, left : U64, right : U64 }

	bounds : U64, U64 -> Bounds
	bounds = |from, to| {
		from_row = from // Cells.col_count
		from_col = from % Cells.col_count
		to_row = to // Cells.col_count
		to_col = to % Cells.col_count
		{
			top: if (from_row < to_row) from_row else to_row,
			bottom: if (from_row < to_row) to_row else from_row,
			left: if (from_col < to_col) from_col else to_col,
			right: if (from_col < to_col) to_col else from_col,
		}
	}

	## Whether an address lies in a rectangle, including its edges.
	in_range : Bounds, U64 -> Bool
	in_range = |{ top, bottom, left, right }, index| {
		row = index // Cells.col_count
		col = index % Cells.col_count
		row >= top and row <= bottom and col >= left and col <= right
	}

	## Expand a rectangular range into the cell indices it covers.
	expand_range : U64, U64 -> List(U64)
	expand_range = |from, to| {
		{ top, bottom, left, right } = Cells.bounds(from, to)
		var $out = []
		var $row = top

		while $row <= bottom {
			var $col = left

			while $col <= right {
				$out = $out.append($row * Cells.col_count + $col)
				$col = $col + 1
			}

			$row = $row + 1
		}

		$out
	}

	## Fixed-point multiply within the sheet’s operand and result limits.
	multiply : I64, I64 -> Try(I64, [Overflow])
	multiply = |left, right| {
		negative = (left < 0) != (right < 0)
		x = if (left < 0) 0 - left.to_i128() else left.to_i128()
		y = if (right < 0) 0 - right.to_i128() else right.to_i128()
		x_whole = x // Cells.scale.to_i128()
		x_frac = x % Cells.scale.to_i128()
		y_whole = y // Cells.scale.to_i128()
		y_frac = y % Cells.scale.to_i128()
		if x_whole > 100000000 or y_whole > 100000000 or x_whole * y_whole > 100000000000000 {
			Err(Overflow)
		} else {
			magnitude =
				x_whole * y_whole * Cells.scale.to_i128()
					+ x_whole * y_frac
					+ x_frac * y_whole
					+ (x_frac * y_frac) // Cells.scale.to_i128()
			Cells.checked_fixed(if (negative) 0 - magnitude else magnitude)
		}
	}

	## Fixed-point divide, truncating toward zero.
	divide : I64, I64 -> Try(I64, [DivideByZero, Overflow])
	divide = |left, right|
		if right == 0 {
			Err(DivideByZero)
		} else if left < -100000000000000 or left > 100000000000000 {
			Err(Overflow)
		} else {
			Ok((left * Cells.scale) // right)
		}

	## Fixed-point number to text, without trailing zeros.
	format_number : I64 -> Str
	format_number = |value| Cells.format_total(value.to_i128())

	## Range totals may exceed the value representable by one cell.
	format_total : I128 -> Str
	format_total = |value| {
		negative = value < 0
		magnitude = if (negative) 0 - value else value
		whole = magnitude // Cells.scale.to_i128()
		frac = magnitude % Cells.scale.to_i128()
		sign = if negative {
			"-"
		} else {
			""
		}
		if frac == 0 {
			"${sign}${whole.to_str()}"
		} else {
			d1 = frac // 1000
			d2 = (frac // 100) % 10
			d3 = (frac // 10) % 10
			d4 = frac % 10
			digits =
				if d4 != 0 {
					"${d1.to_str()}${d2.to_str()}${d3.to_str()}${d4.to_str()}"
				} else if d3 != 0 {
					"${d1.to_str()}${d2.to_str()}${d3.to_str()}"
				} else if d2 != 0 {
					"${d1.to_str()}${d2.to_str()}"
				} else {
					d1.to_str()
				}
			"${sign}${whole.to_str()}.${digits}"
		}
	}
}

## Parse the magnitude wide enough to apply a sign before narrowing.
take_magnitude : List(U8) -> Try({ value : I128, rest : List(U8) }, [NotANumber])
take_magnitude = |bytes| {
	whole = take_digits(bytes, 922337203685477)?
	whole_fixed = whole.value * Cells.scale.to_i128()
	if Cells.byte_at(whole.rest, 0) == '.' {
		frac = take_digits(whole.rest.drop_first(1), 9999)?
		if frac.digits > 4 or (whole.digits == 0 and frac.digits == 0) {
			return Err(NotANumber)
		}
		var $scaled = frac.value
		var $places = frac.digits
		while $places < 4 {
			$scaled = $scaled * 10
			$places = $places + 1
		}
		Ok({ value: whole_fixed + $scaled, rest: frac.rest })
	} else if whole.digits == 0 {
		Err(NotANumber)
	} else {
		Ok({ value: whole_fixed, rest: whole.rest })
	}
}

## Accumulate only while the magnitude the caller can represent still fits.
take_digits : List(U8), I128 -> Try({ value : I128, digits : U64, rest : List(U8) }, [NotANumber])
take_digits = |bytes, maximum| {
	var $rest = bytes
	var $value = 0.I128
	var $digits = 0.U64
	while Cells.head_is_digit($rest) {
		$value = $value * 10 + (Cells.byte_at($rest, 0) - '0').to_i128()
		if $value > maximum {
			return Err(NotANumber)
		}
		$digits = $digits + 1
		$rest = $rest.drop_first(1)
	}
	Ok({ value: $value, digits: $digits, rest: $rest })
}

## Index 0 is the top-left cell.
expect Cells.ref_of(0) == "A1"

## Indices run across the row first, so index 9 is the second column of row 2.
expect Cells.ref_of(9) == "B2"

## The last index of the 8 by 12 sheet is the bottom-right cell.
expect Cells.ref_of(95) == "H12"

## A well-formed reference parses back to the index `ref_of` would render it from.
expect Cells.index_of("B2") == Ok(9)

## Two-digit row numbers parse, up to the last row.
expect Cells.index_of("H12") == Ok(95)

## A column past H is outside the sheet, so it is not a reference.
expect Cells.index_of("Z9") == Err(NotARef)

## A row past 12 is outside the sheet, so it is not a reference.
expect Cells.index_of("B13") == Err(NotARef)

## Trailing text after a valid reference rejects the whole string, rather than
## silently parsing the prefix.
expect Cells.index_of("B2x") == Err(NotARef)

## Zero formats without a decimal point.
expect Cells.format_number(0) == "0"

## A whole number keeps no fractional digits.
expect Cells.format_number(2500 * Cells.scale) == "2500"

## Trailing zeros of the four-decimal representation are dropped.
expect Cells.format_number(11275000) == "1127.5"

## All four decimal places survive when they are significant.
expect Cells.format_number(33333) == "3.3333"

## A negative value keeps its sign in front of the whole part.
expect Cells.format_number(0 - 25000) == "-2.5"

## A decimal literal scales into fixed point and consumes all of its input.
expect Cells.take_number("2.5".to_utf8()) == Ok({ value: 25000, rest: [] })

## A bare decimal point has no digits on either side, so it is not a number.
expect Cells.take_number(".".to_utf8()) == Err(NotANumber)

## More than four decimal places would lose precision, so it is rejected rather
## than rounded.
expect Cells.take_number("1.23456".to_utf8()) == Err(NotANumber)

## A single-column range expands down the column, one index per row.
expect Cells.expand_range(9, 25) == [9, 17, 25]

## A rectangular range expands row by row, left to right within each row.
expect Cells.expand_range(9, 26) == [9, 10, 17, 18, 25, 26]

## Division reports a zero divisor rather than trapping.
expect Cells.divide(10 * Cells.scale, 0) == Err(DivideByZero)

## A visually valid decimal beyond fixed-point range does not wrap or trap.
expect Cells.take_number("922337203685477.5808".to_utf8()) == Err(NotANumber)

## The most negative representable result still has a display value.
expect Cells.format_number(-9223372036854775808) == "-922337203685477.5808"

## Reading signed literals respects the asymmetric fixed-point boundary.
expect Cells.read_number("-922337203685477.5808") == Ok(-9223372036854775808)
