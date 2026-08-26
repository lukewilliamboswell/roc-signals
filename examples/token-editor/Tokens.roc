## Domain layer for the design token editor.
##
## Everything here is pure and integer-only: hex colours parse to integer
## channels, sRGB linearisation comes from a fixed lookup table scaled by
## 100000, and contrast ratios are reported as hundredths (454 means 4.54:1).
## No `Frac` appears anywhere, so every derived value is bit-for-bit
## reproducible on the native host and in the browser.
##
## Parsing returns `Try`, never a record with an `ok` flag: an unparseable
## draft carries an error tag that the UI turns into both a message and a tone,
## and `?` propagates that tag out of the parsers for free.
Tokens :: [].{
	## A parsed colour token: three integer channels.
	Colour : {
		r : U64,
		g : U64,
		b : U64,
	}

	## Why a colour draft failed: it was not `#rrggbb`.
	ColourError : [NotAHexColour]

	## Why a size draft failed: it was empty, too long, or not all digits.
	SizeError : [NotADecimalSize]

	## A colour token as the editor holds it: parsed, or the reason it is not.
	ColourToken : Try(Colour, ColourError)

	## A parsed non-negative size token, in pixels.
	SizeToken : Try(U64, SizeError)

	## WCAG relative luminance, scaled by 100000. A colour that never parsed has
	## no luminance, and the error travels with it.
	Luminance : Try(U64, ColourError)

	## A contrast measurement between two colours, in hundredths.
	Contrast : Try(U64, ColourError)

	## One preview component, fully resolved from the current token values.
	Preview : {
		id : Str,
		fg : Str,
		bg : Str,
		pad : Str,
		size : Str,
	}

	## WCAG AA minimum contrast for normal text, in hundredths.
	aa_threshold : U64
	aa_threshold = 450

	byte_at : List(U8), U64 -> U64
	byte_at = |bytes, index|
		match bytes.get(index) {
			Ok(byte) => byte.to_u64()
			Err(_) => 0
		}

	## One hex digit as a value.
	hex_digit : U64 -> Try(U64, ColourError)
	hex_digit = |code|
		if code >= 48 and code <= 57 {
			Ok(code - 48)
		} else if code >= 97 and code <= 102 {
			Ok((code - 97) + 10)
		} else if code >= 65 and code <= 70 {
			Ok((code - 65) + 10)
		} else {
			Err(NotAHexColour)
		}

	hex_pair : List(U8), U64 -> Try(U64, ColourError)
	hex_pair = |bytes, index| {
		high = hex_digit(byte_at(bytes, index))?
		low = hex_digit(byte_at(bytes, index + 1))?
		Ok((high * 16) + low)
	}

	## Parse `#rrggbb` into integer channels. Anything else is `Err`.
	parse_colour : Str -> ColourToken
	parse_colour = |raw| {
		text = raw.trim()
		bytes = text.to_utf8()
		if bytes.len() != 7 or !text.starts_with("#") {
			Err(NotAHexColour)
		} else {
			red = hex_pair(bytes, 1)?
			green = hex_pair(bytes, 3)?
			blue = hex_pair(bytes, 5)?
			Ok({ r: red, g: green, b: blue })
		}
	}

	expect parse_colour("#2563eb") == Ok({ r: 37, g: 99, b: 235 })
	expect parse_colour("#2563EB") == Ok({ r: 37, g: 99, b: 235 })
	expect parse_colour("#77zz77") == Err(NotAHexColour)
	expect parse_colour("#777") == Err(NotAHexColour)
	expect parse_colour("white") == Err(NotAHexColour)

	## Parse a decimal pixel size. Empty text and non-digits are invalid; zero is
	## a perfectly good spacing value and stays valid. The explicit digit filter
	## is what keeps `"-2"` and `"1 2"` invalid, which `U64.from_str` alone would
	## not, and the length bound keeps the conversion in range.
	parse_size : Str -> SizeToken
	parse_size = |raw| {
		text = raw.trim()
		bytes = text.to_utf8()
		if bytes.len() == 0 or bytes.len() > 4 or !bytes.all(|byte| byte >= 48 and byte <= 57) {
			Err(NotADecimalSize)
		} else {
			Try.map_err(U64.from_str(text), |_| NotADecimalSize)
		}
	}

	expect parse_size("0") == Ok(0)
	expect parse_size("16") == Ok(16)
	expect parse_size("") == Err(NotADecimalSize)
	expect parse_size("-2") == Err(NotADecimalSize)
	expect parse_size("abc") == Err(NotADecimalSize)
	expect parse_size("12345") == Err(NotADecimalSize)

	## sRGB linearisation table, scaled by 100000. `linear_table.get(c)` is the
	## linearised value of channel byte `c`.
	linear_table : List(U64)
	linear_table = [
		0, 30, 61, 91, 121, 152, 182, 212,
		243, 273, 304, 335, 368, 402, 439, 478,
		518, 561, 605, 651, 700, 750, 802, 857,
		913, 972, 1033, 1096, 1161, 1229, 1298, 1370,
		1444, 1521, 1600, 1681, 1764, 1850, 1938, 2029,
		2122, 2217, 2315, 2416, 2519, 2624, 2732, 2843,
		2956, 3071, 3190, 3310, 3434, 3560, 3689, 3820,
		3955, 4092, 4231, 4374, 4519, 4667, 4817, 4971,
		5127, 5286, 5448, 5613, 5781, 5951, 6125, 6301,
		6480, 6663, 6848, 7036, 7227, 7421, 7619, 7819,
		8022, 8228, 8438, 8650, 8866, 9084, 9306, 9531,
		9759, 9990, 10224, 10462, 10702, 10946, 11193, 11444,
		11697, 11954, 12214, 12477, 12744, 13014, 13287, 13563,
		13843, 14126, 14413, 14703, 14996, 15293, 15593, 15896,
		16203, 16513, 16827, 17144, 17465, 17789, 18116, 18447,
		18782, 19120, 19462, 19807, 20156, 20508, 20864, 21223,
		21586, 21953, 22323, 22697, 23074, 23455, 23840, 24228,
		24620, 25016, 25415, 25818, 26225, 26636, 27050, 27468,
		27889, 28315, 28744, 29177, 29614, 30054, 30499, 30947,
		31399, 31855, 32314, 32778, 33245, 33716, 34191, 34670,
		35153, 35640, 36131, 36625, 37124, 37626, 38133, 38643,
		39157, 39676, 40198, 40724, 41254, 41789, 42327, 42869,
		43415, 43966, 44520, 45079, 45641, 46208, 46778, 47353,
		47932, 48515, 49102, 49693, 50289, 50888, 51492, 52100,
		52712, 53328, 53948, 54572, 55201, 55834, 56471, 57112,
		57758, 58408, 59062, 59720, 60383, 61050, 61721, 62396,
		63076, 63760, 64448, 65141, 65837, 66539, 67244, 67954,
		68669, 69387, 70110, 70838, 71569, 72306, 73046, 73791,
		74540, 75294, 76052, 76815, 77582, 78354, 79130, 79910,
		80695, 81485, 82279, 83077, 83880, 84687, 85499, 86316,
		87137, 87962, 88792, 89627, 90466, 91310, 92158, 93011,
		93869, 94731, 95597, 96469, 97345, 98225, 99110, 100000,
	]

	linear : U64 -> U64
	linear = |channel|
		match linear_table.get(channel) {
			Ok(value) => value
			Err(_) => 0
		}
	## WCAG relative luminance, scaled by 100000.
	luminance : ColourToken -> Luminance
	luminance = |colour|
		Try.map_ok(
			colour,
			|c| ((2126 * linear(c.r)) + (7152 * linear(c.g)) + (722 * linear(c.b))) / 10000,
		)

	## Contrast ratio between two luminances, in hundredths (454 = 4.54:1).
	## `?` short-circuits: one unparseable colour makes the whole pair `Err`.
	contrast : Luminance, Luminance -> Contrast
	contrast = |left, right| {
		l = left?
		r = right?
		lighter = if l >= r { l } else { r }
		darker = if l >= r { r } else { l }
		Ok(((lighter + 5000) * 100) / (darker + 5000))
	}

	passes_aa : Contrast -> Bool
	passes_aa = |value|
		match value {
			Ok(ratio) => ratio >= aa_threshold
			Err(_) => False
		}

	pad_two : U64 -> Str
	pad_two = |value|
		if value < 10 {
			"0${value.to_str()}"
		} else {
			value.to_str()
		}

	## "4.54:1", or "n/a" when either colour failed to parse.
	format_ratio : Contrast -> Str
	format_ratio = |value|
		match value {
			Ok(ratio) => "${(ratio / 100).to_str()}.${pad_two(ratio % 100)}:1"
			Err(_) => "n/a"
		}

	expect format_ratio(contrast(luminance(parse_colour("#767676")), luminance(parse_colour("#ffffff")))) == "4.54:1"
	expect format_ratio(contrast(luminance(parse_colour("#77zz77")), luminance(parse_colour("#ffffff")))) == "n/a"

	hex_alphabet : List(Str)
	hex_alphabet = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

	hex_char : U64 -> Str
	hex_char = |value|
		match hex_alphabet.get(value) {
			Ok(text) => text
			Err(_) => "0"
		}

	hex_byte : U64 -> Str
	hex_byte = |value| "${hex_char(value / 16)}${hex_char(value % 16)}"

	## Canonical lowercase `#rrggbb`, or a CSS comment when the token is invalid.
	colour_css : ColourToken -> Str
	colour_css = |colour|
		match colour {
			Ok(c) => "#${hex_byte(c.r)}${hex_byte(c.g)}${hex_byte(c.b)}"
			Err(_) => "/* invalid */"
		}

	expect colour_css(parse_colour("#2563EB")) == "#2563eb"
	expect colour_css(parse_colour("nope")) == "/* invalid */"

	size_css : SizeToken -> Str
	size_css = |size|
		match size {
			Ok(px) => "${px.to_str()}px"
			Err(_) => "/* invalid */"
		}

	expect size_css(parse_size("0")) == "0px"
	expect size_css(parse_size("")) == "/* invalid */"

	css_declaration : Str, Str -> Str
	css_declaration = |name, value| "--${name}: ${value};"

	css_block : List(Str) -> Str
	css_block = |declarations| ":root { ${Str.join_with(declarations, " ")} }"

	preview_style : Preview -> Str
	preview_style = |preview|
		"color: ${preview.fg}; background: ${preview.bg}; padding: ${preview.pad}; font-size: ${preview.size}"
}
