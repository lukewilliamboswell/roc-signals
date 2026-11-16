## Independent reference predicates transcribed from DOM name validation and
## Fetch's HTTP-token and forbidden-method rules. No Web code is imported.
NameModel := [].{
	Flags : { tag : Bool, attribute : Bool, method : Bool }

	## Report raw grammar acceptance, without the literal-only authoring rules.
	accepts : Str -> Flags
	accepts = |text| { tag: is_tag(text), attribute: is_attribute(text), method: is_method(text) }
}

is_tag : Str -> Bool
is_tag = |text| {
	bytes = text.to_utf8()
	first = bytes.first() ?? return False
	letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".to_utf8()
	if letters.contains(first) {
		return !bytes.any(|byte| [0.U8, 9, 10, 12, 13, 32, 47, 62].contains(byte))
	}
	if first < 128 and first != 58 and first != 95 {
		return False
	}
	permitted = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.:_".to_utf8()
	!bytes.any(|byte| byte < 128 and !permitted.contains(byte))
}

is_attribute : Str -> Bool
is_attribute = |text| {
	bytes = text.to_utf8()
	bytes.len() > 0 and !bytes.any(|byte| [0.U8, 9, 10, 12, 13, 32, 47, 61, 62].contains(byte))
}

is_method : Str -> Bool
is_method = |text| {
	alphabet = "!#$%&'*+-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ^_`abcdefghijklmnopqrstuvwxyz|~".to_utf8()
	bytes = text.to_utf8()
	if bytes.is_empty() or bytes.any(|byte| !alphabet.contains(byte)) {
		return False
	}
	lower = Str.from_utf8(bytes.map(|byte| if (byte >= 65 and byte <= 90) byte + 32 else byte)) ?? crash "NameModel.is_method: ASCII folding preserves a token"
	!["connect", "trace", "track"].contains(lower)
}
