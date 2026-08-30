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

	take_int : List(U8) -> { value : I64, digits : U64, rest : List(U8) }
	take_int = |bytes| {
		var $rest = bytes
		var $acc = 0
		var $digits = 0

		while Cells.head_is_digit($rest) {
			byte = Cells.byte_at($rest, 0)
			$acc = $acc * 10 + (byte - '0').to_i64()
			$digits = $digits + 1
			$rest = $rest.drop_first(1)
		}

		{ value: $acc, digits: $digits, rest: $rest }
	}

	take_uint : List(U8) -> { value : U64, digits : U64, rest : List(U8) }
	take_uint = |bytes| {
		var $rest = bytes
		var $acc = 0
		var $digits = 0

		while Cells.head_is_digit($rest) {
			byte = Cells.byte_at($rest, 0)
			$acc = $acc * 10 + (byte - '0').to_u64()
			$digits = $digits + 1
			$rest = $rest.drop_first(1)
		}

		{ value: $acc, digits: $digits, rest: $rest }
	}

	## Parse an unsigned decimal literal into fixed point.
	take_number : List(U8) -> Try({ value : I64, rest : List(U8) }, [NotANumber])
	take_number = |bytes| {
		whole = Cells.take_int(bytes)
		if Cells.byte_at(whole.rest, 0) == '.' {
			after_dot = whole.rest.drop_first(1)
			frac = Cells.take_int(after_dot)
			if whole.digits == 0 and frac.digits == 0 {
				Err(NotANumber)
			} else if frac.digits > 4 {
				Err(NotANumber)
			} else {
				var $scaled = frac.value
				var $places = frac.digits

				while $places < 4 {
					$scaled = $scaled * 10
					$places = $places + 1
				}

				Ok({ value: whole.value * Cells.scale + $scaled, rest: frac.rest })
			}
		} else if whole.digits == 0 {
			Err(NotANumber)
		} else {
			Ok({ value: whole.value * Cells.scale, rest: whole.rest })
		}
	}

	## Parse a leading cell reference such as "B2".
	parse_ref : List(U8) -> Try({ index : U64, rest : List(U8) }, [NotARef])
	parse_ref = |bytes| {
		letter = Cells.byte_at(bytes, 0)
		if letter < 'A' or letter > 'H' {
			Err(NotARef)
		} else {
			digits = Cells.take_uint(bytes.drop_first(1))
			if digits.digits == 0 or digits.value < 1 or digits.value > 12 {
				Err(NotARef)
			} else {
				col = (letter - 'A').to_u64()
				row = digits.value - 1
				Ok({ index: row * Cells.col_count + col, rest: digits.rest })
			}
		}
	}

	## Expand a rectangular range into the cell indices it covers.
	expand_range : U64, U64 -> List(U64)
	expand_range = |from, to| {
		from_row = from // Cells.col_count
		from_col = from % Cells.col_count
		to_row = to // Cells.col_count
		to_col = to % Cells.col_count
		top = if from_row < to_row { from_row } else { to_row }
		bottom = if from_row < to_row { to_row } else { from_row }
		left = if from_col < to_col { from_col } else { to_col }
		right = if from_col < to_col { to_col } else { from_col }

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

	abs_i64 : I64 -> I64
	abs_i64 = |value| if value < 0 { 0 - value } else { value }

	## Fixed-point multiply, kept in range without 128-bit intermediates.
	multiply : I64, I64 -> Try(I64, [Overflow])
	multiply = |left, right| {
		negative = (left < 0) != (right < 0)
		x = Cells.abs_i64(left)
		y = Cells.abs_i64(right)
		x_whole = x // Cells.scale
		x_frac = x % Cells.scale
		y_whole = y // Cells.scale
		y_frac = y % Cells.scale
		if x_whole > 100000000 or y_whole > 100000000 or x_whole * y_whole > 100000000000000 {
			Err(Overflow)
		} else {
			magnitude =
				x_whole * y_whole * Cells.scale
				+ x_whole * y_frac
				+ x_frac * y_whole
				+ (x_frac * y_frac) // Cells.scale
			if negative {
				Ok(0 - magnitude)
			} else {
				Ok(magnitude)
			}
		}
	}

	## Fixed-point divide, truncating toward zero.
	divide : I64, I64 -> Try(I64, [DivideByZero, Overflow])
	divide = |left, right|
		if right == 0 {
			Err(DivideByZero)
		} else if Cells.abs_i64(left) > 100000000000000 {
			Err(Overflow)
		} else {
			Ok((left * Cells.scale) // right)
		}

	## Fixed-point number to text, without trailing zeros.
	format_number : I64 -> Str
	format_number = |value| {
		negative = value < 0
		magnitude = Cells.abs_i64(value)
		whole = magnitude // Cells.scale
		frac = magnitude % Cells.scale
		sign = if negative { "-" } else { "" }
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
