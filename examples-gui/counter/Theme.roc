## Compile-time theming. A flat `theme.json` next to `main.roc` is imported as
## a string and decoded by this module while the compiler evaluates top-level
## definitions, so a malformed theme fails `roc build` with a message naming
## the file and the offending key. The JSON grammar itself — strings, escapes,
## `\uXXXX`, numbers, whitespace — belongs to the builtin `Json` parser; this
## module only adds the theme's own rules: `"#RRGGBB"` colors, which parse
## straight to `Gui.Color` values, layout bounds, and required, unknown, and
## duplicate keys.
import pf.Gui

Theme := [].{
	Palette : {
		background : Gui.Color,
		surface : Gui.Color,
		card : Gui.Color,
		border : Gui.Color,
		text_primary : Gui.Color,
		text_secondary : Gui.Color,
		text_tertiary : Gui.Color,
		accent : Gui.Color,
		accent_hover : Gui.Color,
		accent_active : Gui.Color,
		danger : Gui.Color,
		warning : Gui.Color,
		success : Gui.Color,
		radius : U32,
		control_padding : U32,
		gap : U32,
	}

	## Every rejection carries the finished message, so `decode` can be tested
	## for the exact text the build would print.
	Error := [Invalid(Str)].{
		is_eq : _
	}

	## Every theme value is a JSON string or a JSON unsigned integer. Which one
	## a key requires is checked later, so a wrong type names its key.
	Value := [Color(Str), Layout(U32)].{
		is_eq : _

		# The pinned compiler rejects every spelling of an explicit annotation
		# on a hand-written `parser_for`, so this method is inferred. See
		# UPSTREAM_COMPILER_BUGS.md entry 15.
		parser_for = |encoding|
			|state|
				match encoding.parse_str(state) {
					Ok(parsed) => Ok({ value: Value.Color(parsed.value), rest: parsed.rest })
					Err(_) =>
						match encoding.parse_u32(state) {
							Ok(parsed) => Ok({ value: Value.Layout(parsed.value), rest: parsed.rest })
							Err(err) => Err(err)
						}
				}
	}

	Entry : { key : Str, value : Value }

	## A theme document in source order. A derived record and a `Dict` both keep
	## only the last of two same-named keys, and the theme contract rejects
	## duplicates, so the object is collected into a list instead. The bytes are
	## still tokenized entirely by the builtin parser's object hooks.
	Doc := [Doc(List(Entry))].{
		# Inferred for the same reason as `Value.parser_for` above.
		parser_for = |encoding| {
			parse_value = Value.parser_for(encoding)

			|state| {
				started = encoding.parse_dict_start(state)?
				var $cursor = match started {
					Counted(counted) => counted.rest
					Uncounted(rest) => rest
				}
				var $entries = []
				while True {
					match encoding.parse_dict_next($cursor)? {
						Done(rest) => return Ok({ value: Doc.Doc($entries), rest })
						Entry(rest) => {
							key = encoding.parse_key_str(rest)?
							after_key = encoding.parse_dict_after_key(key.rest)?
							parsed = parse_value(after_key)?
							$entries = $entries.append({ key: key.value, value: parsed.value })
							match encoding.parse_dict_after_entry(parsed.rest)? {
								Continue(next) => {
									$cursor = next
								}
								Done(done) => return Ok({ value: Doc.Doc($entries), rest: done })
							}
						}
					}
				}
				Ok({ value: Doc.Doc($entries), rest: $cursor })
			}
		}
	}

	color_keys : List(Str)
	color_keys = ["background", "surface", "card", "border", "text_primary", "text_secondary", "text_tertiary", "accent", "accent_hover", "accent_active", "danger", "warning", "success"]

	layout_keys : List(Str)
	layout_keys = ["radius", "control_padding", "gap"]

	## Layout knobs are pixel counts on one control, not arbitrary U32 values.
	max_layout : U32
	max_layout = 512

	## Parse a theme document, crashing the build on any problem.
	## `file` is only used to point error messages at the right theme.json.
	from_json : Str, Str -> Palette
	from_json = |file, json|
		match decode(file, json) {
			Ok(palette) => palette
			Err(Invalid(message)) => crash message
		}

	## The whole contract as a value, so every rejection is testable.
	decode : Str, Str -> Try(Palette, Error)
	decode = |file, json| {
		entries = parse_object(file, json)?
		Ok(
			{
				background: color(entries, file, "background")?,
				surface: color(entries, file, "surface")?,
				card: color(entries, file, "card")?,
				border: color(entries, file, "border")?,
				text_primary: color(entries, file, "text_primary")?,
				text_secondary: color(entries, file, "text_secondary")?,
				text_tertiary: color(entries, file, "text_tertiary")?,
				accent: color(entries, file, "accent")?,
				accent_hover: color(entries, file, "accent_hover")?,
				accent_active: color(entries, file, "accent_active")?,
				danger: color(entries, file, "danger")?,
				warning: color(entries, file, "warning")?,
				success: color(entries, file, "success")?,
				radius: number(entries, file, "radius")?,
				control_padding: number(entries, file, "control_padding")?,
				gap: number(entries, file, "gap")?,
			},
		)
	}

	## Decode `{ "key": value, ... }` with the builtin JSON parser, then apply
	## the theme's own key rules. Duplicate keys are refused so a typo cannot
	## silently shadow an earlier definition, and unknown keys are refused so a
	## misspelled key is not silently ignored.
	parse_object : Str, Str -> Try(List(Entry), Error)
	parse_object = |file, json| {
		decoded : Try(Doc, [InvalidJson(Str)])
		decoded = Json.parse(json)
		entries = match decoded {
			Ok(Doc.Doc(list)) => list
			Err(InvalidJson(_)) => return Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))
		}
		for entry in entries {
			if entries.keep_if(|other| other.key == entry.key).len() > 1 {
				return Err(Invalid("${file}: duplicate key \"${entry.key}\""))
			}
			if !color_keys.contains(entry.key) and !layout_keys.contains(entry.key) {
				return Err(Invalid("${file}: unknown key \"${entry.key}\""))
			}
		}
		Ok(entries)
	}

	color : List(Entry), Str, Str -> Try(Gui.Color, Error)
	color = |entries, file, key|
		match lookup(entries, key) {
			Ok(Value.Color(text)) => Ok(Rgb(parse_color(file, key, text)?))
			Ok(Value.Layout(_)) => Err(Invalid("${file}: key \"${key}\" must be a \"#RRGGBB\" color string, not a number"))
			Err(Missing) => Err(Invalid("${file}: missing key \"${key}\""))
		}

	number : List(Entry), Str, Str -> Try(U32, Error)
	number = |entries, file, key|
		match lookup(entries, key) {
			Ok(Value.Layout(value)) =>
				if value > max_layout {
					Err(Invalid("${file}: key \"${key}\" must be at most ${max_layout.to_str()} pixels"))
				} else {
					Ok(value)
				}

			Ok(Value.Color(_)) => Err(Invalid("${file}: key \"${key}\" must be an unsigned integer, not a color string"))
			Err(Missing) => Err(Invalid("${file}: missing key \"${key}\""))
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

	parse_color : Str, Str, Str -> Try(U32, Error)
	parse_color = |file, key, text| {
		digits = text.to_utf8()
		if digits.len() != 7 or digits.get(0) ?? 0 != 35 {
			return Err(Invalid("${file}: key \"${key}\" must be a \"#RRGGBB\" color, got \"${text}\""))
		}
		var $value = 0.U32
		for byte in digits.drop_first(1) {
			digit = if byte >= 48 and byte <= 57 {
				byte - 48
			} else if byte >= 65 and byte <= 70 {
				byte - 55
			} else if byte >= 97 and byte <= 102 {
				byte - 87
			} else {
				return Err(Invalid("${file}: key \"${key}\" has a non-hex digit in \"${text}\""))
			}
			$value = $value * 16 + digit.to_u32()
		}
		Ok($value)
	}
}

file : Str
file = "test/theme.json"

complete_theme : Str
complete_theme = "{\n\t\"background\": \"#16252C\",\n\t\"surface\": \"#1B2A33\",\n\t\"card\": \"#283A47\",\n\t\"border\": \"#3A4F5C\",\n\t\"text_primary\": \"#F2F5F6\",\n\t\"text_secondary\": \"#A9BFCC\",\n\t\"text_tertiary\": \"#93A9B6\",\n\t\"accent\": \"#2E6FA3\",\n\t\"accent_hover\": \"#3A80B8\",\n\t\"accent_active\": \"#265D89\",\n\t\"danger\": \"#F09A93\",\n\t\"warning\": \"#E8C27A\",\n\t\"success\": \"#8FD4A8\",\n\t\"radius\": 6,\n\t\"control_padding\": 10,\n\t\"gap\": 8\n}\n"

## A complete theme parses to the exact color and layout values it spells out.
expect {
	theme = Theme.from_json(file, complete_theme)
	theme.background == Rgb(0x16252C)
	and theme.accent == Rgb(0x2E6FA3)
	and theme.accent_hover == Rgb(0x3A80B8)
	and theme.accent_active == Rgb(0x265D89)
	and theme.success == Rgb(0x8FD4A8)
	and theme.radius == 6
	and theme.control_padding == 10
	and theme.gap == 8
}

## Lowercase hex digits and compact whitespace both parse.
expect {
	entries = Theme.parse_object(file, "{\"accent\":\"#2e6fa3\",\"gap\":12}")?
	Theme.color(entries, file, "accent")? == Rgb(0x2E6FA3)
	and Theme.number(entries, file, "gap")? == 12
}

## An empty object parses to no entries; lookups on it report Missing.
expect {
	entries = Theme.parse_object(file, "{}")?
	entries.is_empty() and Theme.lookup(entries, "accent") == Err(Missing)
}

## Multi-digit layout numbers are read whole, not truncated at the first digit.
expect {
	entries = Theme.parse_object(file, "{ \"radius\": 409 }")?
	Theme.number(entries, file, "radius")? == 409
}

## Duplicate keys are rejected rather than silently keeping the last one, which
## is what a derived record or a `Dict` would do.
expect Theme.parse_object(file, "{\"gap\":8,\"gap\":9}") == Err(Invalid("${file}: duplicate key \"gap\""))

## A duplicate is caught even when the two spellings disagree in type.
expect Theme.parse_object(file, "{\"accent\":\"#2E6FA3\",\"accent\":4}") == Err(Invalid("${file}: duplicate key \"accent\""))

## A misspelled key is refused instead of leaving its intended key missing.
expect Theme.parse_object(file, "{\"acccent\":\"#2E6FA3\"}") == Err(Invalid("${file}: unknown key \"acccent\""))

## Malformed JSON is refused by the builtin parser, not by a local grammar.
expect Theme.parse_object(file, "{\"gap\": 8") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## A trailing comma is not valid JSON.
expect Theme.parse_object(file, "{\"gap\": 8,}") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## Content after the closing brace is refused.
expect Theme.parse_object(file, "{\"gap\": 8} junk") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## A theme is an object, not an array or a bare scalar.
expect Theme.parse_object(file, "[]") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## Nested objects, booleans, and nulls are not theme values.
expect Theme.parse_object(file, "{\"gap\": {\"x\": 1}}") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## A leading zero is not a valid JSON number, and the builtin parser says so.
expect Theme.parse_object(file, "{\"gap\": 01}") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## A number too large for U32 is rejected by the builtin parser.
expect Theme.parse_object(file, "{\"gap\": 4294967296}") == Err(Invalid("${file}: a theme must be a JSON object whose values are \"#RRGGBB\" color strings or unsigned integers"))

## U32's maximum still parses; the theme's own bound rejects it as a layout.
expect {
	entries = Theme.parse_object(file, "{\"gap\": 4294967295}")?
	Theme.number(entries, file, "gap") == Err(Invalid("${file}: key \"gap\" must be at most 512 pixels"))
}

## The layout bound admits its own edge and refuses the next pixel.
expect {
	entries = Theme.parse_object(file, "{\"gap\": 512, \"radius\": 513}")?
	Theme.number(entries, file, "gap")? == 512
	and Theme.number(entries, file, "radius") == Err(Invalid("${file}: key \"radius\" must be at most 512 pixels"))
}

## Zero is a usable layout value.
expect {
	entries = Theme.parse_object(file, "{\"gap\": 0}")?
	Theme.number(entries, file, "gap")? == 0
}

## JSON escapes are decoded by the builtin parser instead of being refused, so
## a color may be written with `\u` escapes. The old handwritten grammar could
## not read this document at all.
expect {
	entries = Theme.parse_object(file, "{\"accent\": \"\\u0023\\u0032E6FA3\"}")?
	Theme.color(entries, file, "accent")? == Rgb(0x2E6FA3)
}

## Non-ASCII text decodes, and then fails the color rule rather than the grammar.
expect {
	entries = Theme.parse_object(file, "{\"accent\": \"#\\u00E9FA3C\"}")?
	Theme.color(entries, file, "accent") == Err(Invalid("${file}: key \"accent\" has a non-hex digit in \"#éFA3C\""))
}

## A missing key names itself.
expect {
	entries = Theme.parse_object(file, "{\"gap\": 8}")?
	Theme.color(entries, file, "accent") == Err(Invalid("${file}: missing key \"accent\""))
}

## A number where a color belongs names the key and the expected form.
expect {
	entries = Theme.parse_object(file, "{\"accent\": 8}")?
	Theme.color(entries, file, "accent") == Err(Invalid("${file}: key \"accent\" must be a \"#RRGGBB\" color string, not a number"))
}

## A color string where a layout number belongs names the key too.
expect {
	entries = Theme.parse_object(file, "{\"gap\": \"#2E6FA3\"}")?
	Theme.number(entries, file, "gap") == Err(Invalid("${file}: key \"gap\" must be an unsigned integer, not a color string"))
}

## A color needs the leading `#` and exactly six hex digits.
expect {
	entries = Theme.parse_object(file, "{\"accent\": \"2E6FA3\"}")?
	Theme.color(entries, file, "accent") == Err(Invalid("${file}: key \"accent\" must be a \"#RRGGBB\" color, got \"2E6FA3\""))
}

## Non-hex digits inside a well-shaped color are reported separately.
expect {
	entries = Theme.parse_object(file, "{\"accent\": \"#2E6FAZ\"}")?
	Theme.color(entries, file, "accent") == Err(Invalid("${file}: key \"accent\" has a non-hex digit in \"#2E6FAZ\""))
}

## A theme missing one key reports that key through `decode`.
expect {
	json = complete_theme.replace_first(",\n\t\"gap\": 8", "")
	Theme.decode(file, json) == Err(Invalid("${file}: missing key \"gap\""))
}
