## Compile-time theming. A flat `theme.json` next to `main.roc` is imported as
## a string and parsed by this module while the compiler evaluates top-level
## definitions, so a malformed theme fails `roc build` with a message naming
## the file and the offending key. Colors are `"#RRGGBB"` strings and layout
## knobs are unsigned integers; nesting, escapes, and other JSON forms are
## rejected because a theme never needs them.
Theme := [].{
	Palette : {
		background : U32,
		surface : U32,
		card : U32,
		border : U32,
		text_primary : U32,
		text_secondary : U32,
		text_tertiary : U32,
		accent : U32,
		danger : U32,
		warning : U32,
		success : U32,
		radius : U32,
		control_padding : U32,
		gap : U32,
	}

	Value := [Color(U32), Number(U32)].{
		is_eq : _
	}

	Entry : { key : Str, value : Value }

	## Parse a theme document, crashing the build on any problem.
	## `file` is only used to point error messages at the right theme.json.
	from_json : Str, Str -> Palette
	from_json = |file, json| {
		entries = parse_object(file, json)
		{
			background: color(entries, file, "background"),
			surface: color(entries, file, "surface"),
			card: color(entries, file, "card"),
			border: color(entries, file, "border"),
			text_primary: color(entries, file, "text_primary"),
			text_secondary: color(entries, file, "text_secondary"),
			text_tertiary: color(entries, file, "text_tertiary"),
			accent: color(entries, file, "accent"),
			danger: color(entries, file, "danger"),
			warning: color(entries, file, "warning"),
			success: color(entries, file, "success"),
			radius: number(entries, file, "radius"),
			control_padding: number(entries, file, "control_padding"),
			gap: number(entries, file, "gap"),
		}
	}

	color : List(Entry), Str, Str -> U32
	color = |entries, file, key|
		match lookup(entries, key) {
			Ok(Value.Color(value)) => value
			Ok(Value.Number(_)) => crash "${file}: key \"${key}\" must be a \"#RRGGBB\" color string, not a number"
			Err(Missing) => crash "${file}: missing key \"${key}\""
		}

	number : List(Entry), Str, Str -> U32
	number = |entries, file, key|
		match lookup(entries, key) {
			Ok(Value.Number(value)) => value
			Ok(Value.Color(_)) => crash "${file}: key \"${key}\" must be an unsigned integer, not a color string"
			Err(Missing) => crash "${file}: missing key \"${key}\""
		}

	lookup : List(Entry), Str -> Try(Value, [Missing])
	lookup = |entries, key| {
		for entry in entries {
			if entry.key == key {
				return Ok(entry.value)
			}
		}
		Err(Missing)
	}

	## Parse `{ "key": value, ... }` where every value is a `"#RRGGBB"` string
	## or a bare unsigned integer. Duplicate keys are refused so a typo cannot
	## silently shadow an earlier definition.
	parse_object : Str, Str -> List(Entry)
	parse_object = |file, json| {
		bytes = json.to_utf8()
		var $i = skip_ws(bytes, 0)
		if bytes.get($i) ?? 0 != 123 {
			crash "${file}: a theme must be a single JSON object starting with \"{\""
		}
		$i = skip_ws(bytes, $i + 1)
		var $entries = []
		if bytes.get($i) ?? 0 == 125 {
			return check_trailing(file, bytes, $i + 1, $entries)
		}
		while True {
			key = parse_string(file, bytes, $i, "an object key")
			$i = skip_ws(bytes, key.next)
			if bytes.get($i) ?? 0 != 58 {
				crash "${file}: expected \":\" after key \"${key.value}\""
			}
			$i = skip_ws(bytes, $i + 1)
			value = parse_value(file, bytes, $i, key.value)
			if $entries.any(|entry| entry.key == key.value) {
				crash "${file}: duplicate key \"${key.value}\""
			}
			$entries = $entries.append({ key: key.value, value: value.value })
			$i = skip_ws(bytes, value.next)
			match bytes.get($i) ?? 0 {
				44 => {
					$i = skip_ws(bytes, $i + 1)
				}
				125 => return check_trailing(file, bytes, $i + 1, $entries)
				_ => crash "${file}: expected \",\" or \"}\" after the value for key \"${key.value}\""
			}
		}
		$entries
	}

	check_trailing : Str, List(U8), U64, List(Entry) -> List(Entry)
	check_trailing = |file, bytes, index, entries| {
		if skip_ws(bytes, index) != bytes.len() {
			crash "${file}: unexpected content after the closing \"}\""
		}
		entries
	}

	parse_value : Str, List(U8), U64, Str -> { value : Value, next : U64 }
	parse_value = |file, bytes, index, key|
		match bytes.get(index) ?? 0 {
			34 => {
				text = parse_string(file, bytes, index, "the value for key \"${key}\"")
				{ value: Value.Color(parse_color(file, key, text.value)), next: text.next }
			}
			byte if byte >= 48 and byte <= 57 => parse_number(file, bytes, index, key)
			_ => crash "${file}: key \"${key}\" must be a \"#RRGGBB\" color string or an unsigned integer"
		}

	## Strings carry hex colors only, so escapes are refused rather than decoded.
	parse_string : Str, List(U8), U64, Str -> { value : Str, next : U64 }
	parse_string = |file, bytes, index, what| {
		if bytes.get(index) ?? 0 != 34 {
			crash "${file}: expected a quoted string for ${what}"
		}
		var $i = index + 1
		var $content = []
		while True {
			match bytes.get($i) {
				Ok(34) => {
					text = Str.from_utf8($content) ?? crash "${file}: invalid UTF-8 in ${what}"
					return { value: text, next: $i + 1 }
				}
				Ok(92) => crash "${file}: escape sequences are not supported, in ${what}"
				Ok(byte) => {
					$content = $content.append(byte)
					$i = $i + 1
				}
				Err(_) => crash "${file}: unterminated string for ${what}"
			}
		}
		{ value: "", next: $i }
	}

	parse_number : Str, List(U8), U64, Str -> { value : Value, next : U64 }
	parse_number = |file, bytes, index, key| {
		var $i = index
		var $value = 0.U32
		while True {
			match bytes.get($i) {
				Ok(byte) if byte >= 48 and byte <= 57 => {
					if $value > 429496728 {
						crash "${file}: the number for key \"${key}\" does not fit in a U32"
					}
					$value = $value * 10 + (byte - 48).to_u32()
					$i = $i + 1
				}
				_ => return { value: Value.Number($value), next: $i }
			}
		}
		{ value: Value.Number($value), next: $i }
	}

	parse_color : Str, Str, Str -> U32
	parse_color = |file, key, text| {
		digits = text.to_utf8()
		if digits.len() != 7 or digits.get(0) ?? 0 != 35 {
			crash "${file}: key \"${key}\" must be a \"#RRGGBB\" color, got \"${text}\""
		}
		digits.drop_first(1).fold(
			0.U32,
			|acc, byte| {
				digit = if byte >= 48 and byte <= 57 {
					byte - 48
				} else if byte >= 65 and byte <= 70 {
					byte - 55
				} else if byte >= 97 and byte <= 102 {
					byte - 87
				} else {
					crash "${file}: key \"${key}\" has a non-hex digit in \"${text}\""
				}
				acc * 16 + digit.to_u32()
			},
		)
	}

	skip_ws : List(U8), U64 -> U64
	skip_ws = |bytes, start| {
		var $i = start
		while True {
			match bytes.get($i) {
				Ok(32) | Ok(9) | Ok(10) | Ok(13) => {
					$i = $i + 1
				}
				_ => return $i
			}
		}
		$i
	}
}

## A complete theme parses to the exact color and layout values it spells out.
expect {
	json = "{\n\t\"background\": \"#16252C\",\n\t\"surface\": \"#1B2A33\",\n\t\"card\": \"#283A47\",\n\t\"border\": \"#3A4F5C\",\n\t\"text_primary\": \"#F2F5F6\",\n\t\"text_secondary\": \"#A9BFCC\",\n\t\"text_tertiary\": \"#93A9B6\",\n\t\"accent\": \"#2E6FA3\",\n\t\"danger\": \"#F09A93\",\n\t\"warning\": \"#E8C27A\",\n\t\"success\": \"#8FD4A8\",\n\t\"radius\": 6,\n\t\"control_padding\": 10,\n\t\"gap\": 8\n}\n"
	theme = Theme.from_json("test/theme.json", json)
	theme.background == 0x16252C
	and theme.accent == 0x2E6FA3
	and theme.success == 0x8FD4A8
	and theme.radius == 6
	and theme.control_padding == 10
	and theme.gap == 8
}

## Lowercase hex digits and compact whitespace both parse.
expect {
	entries = Theme.parse_object("test/theme.json", "{\"accent\":\"#2e6fa3\",\"gap\":12}")
	Theme.color(entries, "test/theme.json", "accent") == 0x2E6FA3
	and Theme.number(entries, "test/theme.json", "gap") == 12
}

## An empty object parses to no entries; lookups on it report Missing.
expect {
	entries = Theme.parse_object("test/theme.json", "{}")
	entries.is_empty() and Theme.lookup(entries, "accent") == Err(Missing)
}

## Numbers accumulate digit by digit rather than stopping at the first one.
expect {
	entries = Theme.parse_object("test/theme.json", "{ \"radius\": 4095 }")
	Theme.number(entries, "test/theme.json", "radius") == 4095
}
