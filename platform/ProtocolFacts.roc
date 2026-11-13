import Protocol

## Declaration-section transport for the protocol's closed vocabularies. This
## temporary, length-delimited format is fallback (a) until the owner's roc-cbor
## port has a release. It contains metadata only, never command semantics.
ProtocolFacts := [].{

	## Encode all eleven fields in their required order. A field has a byte tag,
	## a little-endian u32 body length and its body. Counts and UTF-8 lengths
	## inside each body are u32; codes are u8 except policy bits, which are u32.
	encode : Protocol.Facts -> List(U8)
	encode = |facts| {
		fields = [
			codes(facts.ops),
			facts.kinds.fold(count(facts.kinds.len()), |out, row| strings(text(out.append(row.code), row.name), row.events)),
			facts.policies.fold(count(facts.policies.len()), |out, row| text(u32(out, row.bit), row.name)),
			facts.properties.fold(count(facts.properties.len()), |out, row| strings(text(out.append(row.index), row.name), row.elements)),
			codes(facts.http_cache),
			codes(facts.http_credentials),
			codes(facts.namespaces),
			strings([], facts.text_entry_excluded),
			strings([], facts.fault_classes),
			codes(facts.template_nodes),
			codes(facts.child_containers),
		]
		var $out = []
		var $tag = 1.U8
		for body in fields {
			$out = u32($out.append($tag), body.len().to_u32_wrap()).concat(body)
			$tag = $tag + 1
		}
		$out
	}

	## Structural refusal from the fallback reader. Every count is bounded by
	## its owning slice before allocation; malformed input never reaches Core.
	Error : [Truncated, InvalidUtf8, Malformed, TooLarge, TrailingBytes]

	## Decode exactly one metadata item without interpreting any commands.
	## Canonical field order and complete consumption make accepted items round
	## trip byte for byte, which the fixed fuzz target checks independently.
	decode : List(U8) -> Try(Protocol.Facts, Error)
	decode = |bytes| {
		if bytes.len() > 65_536 {
			return Err(TooLarge)
		}
		start = { bytes, at: 0 }
		(ops, s1) = field(start, 1, read_codes)?
		(kinds, s2) = field(s1, 2, |state| rows(state, read_kind, 64))?
		(policies, s3) = field(s2, 3, |state| rows(state, read_policy, 64))?
		(properties, s4) = field(s3, 4, |state| rows(state, read_property, 64))?
		(http_cache, s5) = field(s4, 5, read_codes)?
		(http_credentials, s6) = field(s5, 6, read_codes)?
		(namespaces, s7) = field(s6, 7, read_codes)?
		(text_entry_excluded, s8) = field(s7, 8, read_names)?
		(fault_classes, s9) = field(s8, 9, read_names)?
		(template_nodes, s10) = field(s9, 10, read_codes)?
		(child_containers, end) = field(s10, 11, read_codes)?
		if end.at != bytes.len() {
			return Err(TrailingBytes)
		}
		facts = { ops, kinds, policies, properties, http_cache, http_credentials, namespaces, template_nodes, child_containers, text_entry_excluded, fault_classes }
		if !valid_facts(facts) {
			return Err(Malformed)
		}
		Ok(facts)
	}

	## Append the mandatory protocol metadata section to the engine's own
	## declarations. The engine retains its independent declaration producer.
	append_declaration : List(U8) -> List(U8)
	append_declaration = |declarations| {
		body = ProtocolFacts.encode(Protocol.facts)
		u32(declarations.append(12), body.len().to_u32_wrap()).concat(body)
	}
}

# Metadata is bounded independently of app data: each vocabulary has at most
# 64 rows, each row's event/element list at most 32 names, names at most 128
# UTF-8 bytes and the entire item at most 64 KiB. The independent readers enforce
# these bounds before accepting a module; these fixed producer facts fit them.
count : U64 -> List(U8)
count = |size| u32([], size.to_u32_wrap())

u32 : List(U8), U32 -> List(U8)
u32 = |out, value| out.append(value.bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(16).bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(24).to_u8_wrap())

text : List(U8), Str -> List(U8)
text = |out, value| {
	bytes = value.to_utf8()
	u32(out, bytes.len().to_u32_wrap()).concat(bytes)
}

strings : List(U8), List(Str) -> List(U8)
strings = |out, names| names.fold(u32(out, names.len().to_u32_wrap()), text)

codes : List(Protocol.Code) -> List(U8)
codes = |entries| entries.fold(count(entries.len()), |out, row| text(out.append(row.code), row.name))

## The first and last fields have their own lengths, so missing, appended or
## reordered fields cannot be mistaken for another table's contents.
expect {
	bytes = ProtocolFacts.encode(Protocol.facts)
	bytes.first() == Ok(1) and bytes.len() < 65_536 and bytes.take_last(21) == [1, 16, 0, 0, 0, 'T', 'E', 'M', 'P', 'L', 'A', 'T', 'E', '_', 'C', 'O', 'N', 'T', 'E', 'N', 'T']
}

# The reader carries one bounded immutable slice plus an offset. Each nested
# field gets its own slice, so a count cannot consume a following field.
State : { bytes : List(U8), at : U64 }

byte : State -> Try((U8, State), ProtocolFacts.Error)
byte = |state| {
	value = state.bytes.get(state.at).map_err(|_| Truncated)?
	Ok((value, { ..state, at: state.at + 1 }))
}

word : State -> Try((U32, State), ProtocolFacts.Error)
word = |state| {
	(a, s1) = byte(state)?
	(b, s2) = byte(s1)?
	(c, s3) = byte(s2)?
	(d, end) = byte(s3)?
	Ok((a.to_u32().bitwise_or(b.to_u32().shl_wrap(8)).bitwise_or(c.to_u32().shl_wrap(16)).bitwise_or(d.to_u32().shl_wrap(24)), end))
}

slice : State, U64 -> Try((List(U8), State), ProtocolFacts.Error)
slice = |state, size| {
	if size > state.bytes.len() - state.at {
		return Err(Truncated)
	}
	Ok((state.bytes.drop_first(state.at).take_first(size), { ..state, at: state.at + size }))
}

name : State -> Try((Str, State), ProtocolFacts.Error)
name = |state| {
	(size, after_size) = word(state)?
	if size < 1 or size > 128 {
		return Err(Malformed)
	}
	(bytes, end) = slice(after_size, size.to_u64())?
	value = Str.from_utf8(bytes).map_err(|_| InvalidUtf8)?
	if value.to_utf8().contains(0) {
		return Err(Malformed)
	}
	Ok((value, end))
}

rows : State, (State -> Try((a, State), ProtocolFacts.Error)), U64 -> Try((List(a), State), ProtocolFacts.Error)
rows = |state, read, maximum| {
	(size, after_size) = word(state)?
	if size.to_u64() > maximum or size.to_u64() > after_size.bytes.len() - after_size.at {
		return Err(Malformed)
	}
	var $out = []
	var $rest = after_size
	for _ in 0..<size.to_u64() {
		(item, next) = read($rest)?
		$out = $out.append(item)
		$rest = next
	}
	Ok(($out, $rest))
}

read_names : State -> Try((List(Str), State), ProtocolFacts.Error)
read_names = |state| {
	(values, rest) = rows(state, name, 64)?
	if !unique(values) {
		return Err(Malformed)
	}
	Ok((values, rest))
}

read_codes : State -> Try((List(Protocol.Code), State), ProtocolFacts.Error)
read_codes = |state| rows(
	state,
	|start| {
		(code, after_code) = byte(start)?
		(label, end) = name(after_code)?
		Ok(({ code, name: label }, end))
	},
	64,
)

read_kind : State -> Try((Protocol.Kind, State), ProtocolFacts.Error)
read_kind = |state| {
	(code, after_code) = byte(state)?
	(label, after_name) = name(after_code)?
	(events, end) = read_names(after_name)?
	if events.len() > 32 {
		return Err(Malformed)
	}
	Ok(({ code, name: label, events }, end))
}

read_policy : State -> Try((Protocol.Policy, State), ProtocolFacts.Error)
read_policy = |state| {
	(bit, after_bit) = word(state)?
	(label, end) = name(after_bit)?
	Ok(({ bit, name: label }, end))
}

read_property : State -> Try((Protocol.Property, State), ProtocolFacts.Error)
read_property = |state| {
	(index, after_index) = byte(state)?
	(label, after_name) = name(after_index)?
	(elements, end) = read_names(after_name)?
	if elements.len() > 32 {
		return Err(Malformed)
	}
	Ok(({ index, name: label, elements }, end))
}

field : State, U8, (State -> Try((a, State), ProtocolFacts.Error)) -> Try((a, State), ProtocolFacts.Error)
field = |state, expected, read| {
	(tag, after_tag) = byte(state)?
	if tag != expected {
		return Err(Malformed)
	}
	(size, after_size) = word(after_tag)?
	(body, end) = slice(after_size, size.to_u64())?
	(value, rest) = read({ bytes: body, at: 0 })?
	if rest.at != body.len() {
		return Err(TrailingBytes)
	}
	Ok((value, end))
}

unique = |values| values.fold(Dict.empty(), |seen, value| seen.insert(value, {})).len() == values.len()

dense : List(U8) -> Bool
dense = |numbers| dense_from(numbers, 1)

dense_from : List(U8), U64 -> Bool
dense_from = |numbers, start| {
	var $expected = start
	for code in numbers {
		if code.to_u64() != $expected {
			return False
		}
		$expected = $expected + 1
	}
	!numbers.is_empty()
}

valid_facts : Protocol.Facts -> Bool
valid_facts = |facts| {
	groups = [facts.ops.map(|row| row.name), facts.kinds.map(|row| row.name), facts.policies.map(|row| row.name), facts.properties.map(|row| row.name), facts.http_cache.map(|row| row.name), facts.http_credentials.map(|row| row.name), facts.namespaces.map(|row| row.name), facts.template_nodes.map(|row| row.name), facts.child_containers.map(|row| row.name)]
	bits = facts.policies.map(|row| row.bit)
	groups.all(|values| !values.is_empty() and unique(values)) and !facts.fault_classes.is_empty() and dense(facts.ops.map(|row| row.code)) and dense(facts.kinds.map(|row| row.code)) and dense(facts.properties.map(|row| row.index)) and dense(facts.http_cache.map(|row| row.code)) and dense(facts.http_credentials.map(|row| row.code)) and dense_from(facts.namespaces.map(|row| row.code), 0) and dense(facts.template_nodes.map(|row| row.code)) and dense_from(facts.child_containers.map(|row| row.code), 0) and unique(bits) and bits.all(|bit| bit > 0 and bit.bitwise_and(bit - 1) == 0)
}

expect ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts)) == Ok(Protocol.facts)
expect ProtocolFacts.decode([]) == Err(Truncated)
expect ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts).append(0)) == Err(TrailingBytes)
expect ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts).take_first(7)).is_err()

## A count cannot allocate more rows than its field or the metadata bound allows.
expect ProtocolFacts.decode([1, 4, 0, 0, 0, 255, 255, 255, 255]) == Err(Malformed)

## Name decoding refuses invalid UTF-8 before it reaches another field.
expect ProtocolFacts.decode([1, 10, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 255]) == Err(InvalidUtf8)

## A vocabulary cannot overwrite an earlier name when consumers build maps.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: "HTML" }, { code: 1, name: "HTML" }] })) == Err(Malformed)

## Numbered dispatch tables retain canonical, dense one-based codes.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, ops: [{ code: 2, name: "INST" }] })) == Err(Malformed)

## Policy names cannot give a single policy ownership of two bits.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, policies: [{ bit: 3, name: "PREVENT" }] })) == Err(Malformed)

## A NUL-bearing spelling cannot enter a browser lookup table.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: Str.from_utf8([72, 0, 84, 77, 76]) ?? crash "fixed UTF-8 name" }] })) == Err(Malformed)

## Namespace codes begin at zero while template kinds have a separate dense
## one-based space. Missing, duplicate or shifted rows fail structurally.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 1, name: "HTML" }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, template_nodes: [{ code: 0, name: "ELEMENT" }] })) == Err(Malformed)
