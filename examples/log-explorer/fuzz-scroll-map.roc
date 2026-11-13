app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Log

## Scroll geometry is checked without a viewer or the platform. Inputs cover
## the entire count and pixel types; a zero generated row height means one.
## The oracle checks distances and ordering rather than repeating the map's
## rounding formula. In particular, a partial-height final window names the
## reachable end even when its nearest ordinary line would be earlier.
Input : {
	total : U64,
	row_height : U32,
	viewport : U32,
	top : U32,
	first : U64,
}

check : Input -> Try({}, Str)
check = |input| {
	row = input.row_height.max(1)
	map = { total: input.total, line_height: row, viewport_height: input.viewport }
	full_height = input.total.to_u128() * row.to_u128()
	wanted_height = full_height.min(8000000).to_u32_wrap()
	height = Log.spacer_height({ total: input.total, line_height: row })
	if height != wanted_height {
		return Err("spacer height wrapped or did not apply its cap")
	}
	capacity = (input.viewport.to_u64() // row.to_u64()).max(1)
	last = if (input.total > capacity) input.total - capacity else 0
	extent = if (height > input.viewport) height - input.viewport else 0
	top = input.top.min(extent)
	line = input.first.min(last)
	found = Log.first_at(map, input.top)
	offset = Log.offset_of(map, input.first)
	if found > last or offset > extent {
		return Err("a map escaped the reachable line or pixel bounds")
	}
	if Log.first_at(map, 0) != 0 or Log.offset_of(map, 0) != 0 {
		return Err("the beginning must map to zero")
	}
	if extent == 0 or last == 0 {
		if found != 0 or offset != 0 {
			return Err("a geometry with no scrollable lines or pixels must map to zero")
		}
		return Ok({})
	}
	if Log.first_at(map, extent) != last or Log.first_at(map, 4294967295.U32) != last {
		return Err("the reachable end must select the last full window")
	}
	if Log.first_at(map, top) != found or Log.offset_of(map, line) != offset {
		return Err("out-of-range inputs must clamp to the reachable span")
	}
	if Log.first_at(map, top + (if (top < extent) 1 else 0)) < found or Log.offset_of(map, line + (if (line < last) 1 else 0)) < offset {
		return Err("increasing either coordinate moved the map backwards")
	}
	if full_height <= 8000000 {
		linear = (line.to_u128() * row.to_u128()).min(extent.to_u128()).to_u32_wrap()
		if offset != linear {
			return Err("an uncapped line must retain its reachable linear offset")
		}
		if Log.first_at(map, offset) != line {
			return Err("an uncapped line did not round trip exactly")
		}
		if top < extent {
			# The nearest candidate wins, with ties going to the later line.
			at = found.to_u128() * row.to_u128()
			distance = apart({ left: at, right: top.to_u128() })
			if found > 0 and apart({ left: at - row.to_u128(), right: top.to_u128() }) < distance {
				return Err("an earlier uncapped line is nearer")
			}
			if found < last and apart({ left: at + row.to_u128(), right: top.to_u128() }) <= distance {
				return Err("a later uncapped line is at least as near")
			}
		}
	} else {
		if Log.offset_of(map, last) != extent {
			return Err("the capped last window must reach the scrollbar end")
		}
		# Compare integer distances in the proportional plane. Wide products
		# also exercise counts whose line-height product cannot fit in U64.
		line_distance = apart({ left: found.to_u128() * extent.to_u128(), right: top.to_u128() * last.to_u128() })
		pixel_distance = apart({ left: offset.to_u128() * last.to_u128(), right: line.to_u128() * extent.to_u128() })
		if line_distance * 2 > extent.to_u128() or pixel_distance * 2 > last.to_u128() {
			return Err("a capped coordinate is farther than half a rounding step")
		}
		if line_distance * 2 == extent.to_u128() and found.to_u128() * extent.to_u128() < top.to_u128() * last.to_u128() {
			return Err("a capped line tie must choose the later line")
		}
		if pixel_distance * 2 == last.to_u128() and offset.to_u128() * last.to_u128() < line.to_u128() * extent.to_u128() {
			return Err("a capped pixel tie must choose the later pixel")
		}
		recovered = Log.first_at(map, offset)
		line_error = apart({ left: recovered.to_u128(), right: line.to_u128() })
		lines_per_pixel = (last.to_u128() + extent.to_u128() - 1) // extent.to_u128()
		if line_error > lines_per_pixel {
			return Err("a capped line round trip exceeded one pixel's lines")
		}
		recovered_top = Log.offset_of(map, found)
		pixel_error = apart({ left: recovered_top.to_u128(), right: top.to_u128() })
		pixels_per_line = (extent.to_u128() + last.to_u128() - 1) // last.to_u128()
		if pixel_error > pixels_per_line {
			return Err("a capped pixel round trip exceeded one line's pixels")
		}
	}
	Ok({})
}

apart : { left : U128, right : U128 } -> U128
apart = |{ left, right }| if (left > right) left - right else right - left

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash "${problem}: ${Str.inspect(input)}"
}

example : Str, Input -> Fuzz.Example(Input)
example = |name, input| Fuzz.example({ name, revision: "1", make: || input })

## Keep ordinary uncapped and capped geometry common without losing full-width
## counts, heights, out-of-range coordinates or unscrollable viewports.
generated_input : Input -> Input
generated_input = |raw| {
	total = match raw.total % 4 {
		0 => raw.total // 4 % 400001
		1 => 400001 + raw.total // 4 % 2000000000
		_ => raw.total
	}
	row_height = match raw.row_height % 4 {
		0 => 20
		1 => raw.row_height // 4 % 100 + 1
		_ => raw.row_height
	}
	viewport = match raw.viewport % 4 {
		0 => raw.viewport // 4 % 2001
		1 => raw.viewport // 4 % row_height.max(1)
		2 => 8000000
		_ => raw.viewport
	}
	{
		total,
		row_height,
		viewport,
		top: if (raw.top % 2 == 0) raw.top // 2 % 8000001 else raw.top,
		first: if (raw.first % 2 == 0 and total > 0) raw.first // 2 % total else raw.first,
	}
}

target = Fuzz.target_with!({
	name: "log-scroll-map",
	examples: [
		example("empty", { total: 0, row_height: 20, viewport: 400, top: 4294967295.U32, first: 18446744073709551615.U64 }),
		example("short", { total: 10, row_height: 20, viewport: 400, top: 100, first: 9 }),
		example("nearest-tie", { total: 100, row_height: 20, viewport: 400, top: 30, first: 79 }),
		example("partial-end", { total: 100, row_height: 20, viewport: 39, top: 1961, first: 99 }),
		example("sub-row-end", { total: 100, row_height: 20, viewport: 19, top: 1981, first: 99 }),
		example("one-pixel-view", { total: 100, row_height: 20, viewport: 1, top: 1999, first: 99 }),
		example("zero-height-view", { total: 100, row_height: 20, viewport: 0, top: 2000, first: 99 }),
		example("at-cap", { total: 400000, row_height: 20, viewport: 399, top: 7999601, first: 399981 }),
		example("just-capped", { total: 400001, row_height: 20, viewport: 399, top: 7999600, first: 399982 }),
		example("many-lines-per-pixel", { total: 2000000000, row_height: 20, viewport: 401, top: 3456789, first: 123456789 }),
		example("whole-u64", { total: 18446744073709551615.U64, row_height: 4294967295.U32, viewport: 399, top: 7999601, first: 18446744073709551615.U64 }),
		example("wide-midpoint", { total: 18446744073709551615.U64, row_height: 20, viewport: 601, top: 3999699, first: 9223372036854775807 }),
		example("cap-sized-view", { total: 18446744073709551615.U64, row_height: 20, viewport: 8000000, top: 4294967295.U32, first: 18446744073709551615.U64 }),
		example("large-row", { total: 3, row_height: 4294967295.U32, viewport: 1, top: 3456789, first: 1 }),
		example("odd-row", { total: 500, row_height: 3, viewport: 7, top: 10, first: 498 }),
	],
	generator: Fuzz.map({ total: Fuzz.u64, row_height: Fuzz.map(Fuzz.u64, U64.to_u32_wrap), viewport: Fuzz.map(Fuzz.u64, U64.to_u32_wrap), top: Fuzz.map(Fuzz.u64, U64.to_u32_wrap), first: Fuzz.u64 }.Fuzz, generated_input),
	test!,
	show: Str.inspect,
})
