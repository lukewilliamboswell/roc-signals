import Protocol
import cbor.Cbor

## The module's closed consumer vocabularies travel as one deterministic CBOR
## item. This transport supplies metadata only, never command semantics.
ProtocolFacts := [].{

	## Derived record encoding keeps field names and shapes with Protocol.Facts.
	## Sorted map keys and shortest heads give one encoding of each accepted item.
	encode : Protocol.Facts -> List(U8)
	encode = |facts| match Cbor.encode_with(facts, { key_order: Sorted }) {
		Ok(bytes) => bytes
		Err(problem) => crash "ProtocolFacts.encode: derived facts encoder failed: ${Str.inspect(problem)}"
	}

	## Malformed metadata is refused before a module initializes. CBOR failures
	## retain the byte position or missing required field supplied by the codec.
	Error : [InvalidCbor(U64), MissingRequiredField(Str), Malformed, TooLarge]

	## Bound the input before parsing. The released reader validates the whole
	## item's depth and item budget before allocating its typed result; field
	## counts and names are then checked before accepting any vocabulary.
	decode : List(U8) -> Try(Protocol.Facts, Error)
	decode = |bytes| {
		if bytes.len() > 65_536 {
			return Err(TooLarge)
		}
		facts : Protocol.Facts
		facts = Cbor.parse_with(
			bytes,
			{
				key_order: Sorted,
				unknown_fields: Reject,
				max_depth: 4,
				max_items: 7383,
				forms: Encoder,
			},
		)?
		if !valid_facts(facts) {
			return Err(Malformed)
		}
		Ok(facts)
	}

	## Only the platform boundary adds consumer metadata to the engine's own
	## declarations. Core keeps its independent declaration producer and numbers.
	append_declaration : List(U8) -> List(U8)
	append_declaration = |declarations| {
		body = ProtocolFacts.encode(Protocol.facts)
		u32(declarations.append(12), body.len().to_u32_wrap()).concat(body)
	}
}

u32 : List(U8), U32 -> List(U8)
u32 = |out, value| out.append(value.bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(16).bitwise_and(255).to_u8_wrap()).append(value.shr_zf_wrap(24).to_u8_wrap())

unique : List(a) -> Bool where [a.is_eq : a, a -> Bool, a.to_hash : a, Hasher -> Hasher]
unique = |values| values.fold(Dict.empty(), |seen, value| seen.insert(value, {})).len() == values.len()

valid_names : List(Str), U64 -> Bool
valid_names = |values, maximum| values.len() <= maximum and unique(values) and values.all(|value| value.count_utf8_bytes() >= 1 and value.count_utf8_bytes() <= 128 and !value.to_utf8().contains(0))

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

# The field cardinalities bound the shape to four nested containers and at
# most 7,383 CBOR items, before stricter vocabulary checks:
# root and its keys/arrays, six code tables, policy rows, two tables with nested
# name arrays, and two plain name lists. These budgets bound allocation globally;
# the semantic limits below apply to every field before acceptance.
valid_facts : Protocol.Facts -> Bool
valid_facts = |facts| {
	groups = [facts.ops.map(|row| row.name), facts.kinds.map(|row| row.name), facts.policies.map(|row| row.name), facts.properties.map(|row| row.name), facts.http_cache.map(|row| row.name), facts.http_credentials.map(|row| row.name), facts.namespaces.map(|row| row.name), facts.template_nodes.map(|row| row.name), facts.child_containers.map(|row| row.name)]
	bits = facts.policies.map(|row| row.bit)
	groups.all(|values| !values.is_empty() and valid_names(values, 64)) and
		valid_names(facts.text_entry_excluded, 64) and
			!facts.fault_classes.is_empty() and valid_names(facts.fault_classes, 64) and
				facts.kinds.all(|row| valid_names(row.events, 32)) and
					facts.properties.all(|row| valid_names(row.elements, 32)) and
						dense_from(facts.ops.map(|row| row.code), 1) and
							dense_from(facts.kinds.map(|row| row.code), 1) and
								dense_from(facts.properties.map(|row| row.index), 1) and
									dense_from(facts.http_cache.map(|row| row.code), 1) and
										dense_from(facts.http_credentials.map(|row| row.code), 1) and
											dense_from(facts.namespaces.map(|row| row.code), 0) and
												dense_from(facts.template_nodes.map(|row| row.code), 1) and
													dense_from(facts.child_containers.map(|row| row.code), 0) and
														unique(bits) and bits.all(|bit| bit > 0 and bit.bitwise_and(bit - 1) == 0)
}

## A canonical CBOR map preserves every vocabulary, including nested names.
expect ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts)) == Ok(Protocol.facts)

## Exactly one complete item is required, including for empty and cut input.
expect ProtocolFacts.decode([]).is_err() and ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts).drop_last(1)).is_err() and ProtocolFacts.decode(ProtocolFacts.encode(Protocol.facts).append(0)).is_err()

## The encoder starts a definite map of eleven fields; the shortest first key
## is ops under deterministic encoded-key ordering.
expect ProtocolFacts.encode(Protocol.facts).take_first(5) == [0xab, 0x63, 'o', 'p', 's']

## A padded map head, indefinite map or byte string is outside this profile.
expect ProtocolFacts.decode([0xb8, 11].concat(ProtocolFacts.encode(Protocol.facts).drop_first(1))).is_err() and ProtocolFacts.decode([0xbf, 0xff]).is_err() and ProtocolFacts.decode([0x40]).is_err()

## Input bytes are bounded before the library's structural and typed passes.
expect ProtocolFacts.decode(List.repeat(0.U8, 65_537)) == Err(TooLarge)

## A vocabulary cannot overwrite an earlier consumer binding.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: "HTML" }, { code: 1, name: "HTML" }] })) == Err(Malformed)

## Numbered dispatch tables retain canonical, dense one-based codes.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, ops: [{ code: 2, name: "INST" }] })) == Err(Malformed)

## One policy cannot own two bits, and no policy can have bit zero.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, policies: [{ bit: 3, name: "PREVENT" }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, policies: [{ bit: 0, name: "PREVENT" }] })) == Err(Malformed)

## Names retain their byte bound and refuse embedded NUL before acceptance.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: "" }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: Str.repeat("x", 129) }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: Str.from_utf8([72, 0, 84, 77, 76]) ?? crash "fixed UTF-8 name" }] })) == Err(Malformed)

## Namespace codes begin at zero and template node kinds independently at one.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 1, name: "HTML" }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, template_nodes: [{ code: 0, name: "ELEMENT" }] })) == Err(Malformed)

## Table limits apply even when the CBOR item fits its global allocation bound.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, text_entry_excluded: (0.U64..<65).iter().fold([], |out, value| out.append(value.to_str())) })) == Err(Malformed)

## Nested event limits and uniqueness apply independently to every row.
expect ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, kinds: [{ code: 1, name: "TEXT", events: (0.U64..<33).iter().fold([], |out, value| out.append(value.to_str())) }] })) == Err(Malformed) and ProtocolFacts.decode(ProtocolFacts.encode({ ..Protocol.facts, kinds: [{ code: 1, name: "TEXT", events: ["input", "input"] }] })) == Err(Malformed)

## This complete minimal map is encoded independently by the JavaScript test
## fixture, rather than by the library whose transport is under test.
expect {
	bytes : List(U8)
	bytes = [0xab, 0x63, 0x6f, 0x70, 0x73, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x64, 0x49, 0x4e, 0x53, 0x54, 0x65, 0x6b, 0x69, 0x6e, 0x64, 0x73, 0x81, 0xa3, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x64, 0x54, 0x45, 0x58, 0x54, 0x66, 0x65, 0x76, 0x65, 0x6e, 0x74, 0x73, 0x80, 0x68, 0x70, 0x6f, 0x6c, 0x69, 0x63, 0x69, 0x65, 0x73, 0x81, 0xa2, 0x63, 0x62, 0x69, 0x74, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x67, 0x50, 0x52, 0x45, 0x56, 0x45, 0x4e, 0x54, 0x6a, 0x68, 0x74, 0x74, 0x70, 0x5f, 0x63, 0x61, 0x63, 0x68, 0x65, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x67, 0x64, 0x65, 0x66, 0x61, 0x75, 0x6c, 0x74, 0x6a, 0x6e, 0x61, 0x6d, 0x65, 0x73, 0x70, 0x61, 0x63, 0x65, 0x73, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x00, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x64, 0x48, 0x54, 0x4d, 0x4c, 0x6a, 0x70, 0x72, 0x6f, 0x70, 0x65, 0x72, 0x74, 0x69, 0x65, 0x73, 0x81, 0xa3, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x65, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x65, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x01, 0x68, 0x65, 0x6c, 0x65, 0x6d, 0x65, 0x6e, 0x74, 0x73, 0x81, 0x65, 0x69, 0x6e, 0x70, 0x75, 0x74, 0x6d, 0x66, 0x61, 0x75, 0x6c, 0x74, 0x5f, 0x63, 0x6c, 0x61, 0x73, 0x73, 0x65, 0x73, 0x82, 0x64, 0x6e, 0x6f, 0x6e, 0x65, 0x68, 0x63, 0x6f, 0x6e, 0x74, 0x72, 0x61, 0x63, 0x74, 0x6e, 0x74, 0x65, 0x6d, 0x70, 0x6c, 0x61, 0x74, 0x65, 0x5f, 0x6e, 0x6f, 0x64, 0x65, 0x73, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x67, 0x45, 0x4c, 0x45, 0x4d, 0x45, 0x4e, 0x54, 0x70, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x5f, 0x63, 0x6f, 0x6e, 0x74, 0x61, 0x69, 0x6e, 0x65, 0x72, 0x73, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x00, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x68, 0x43, 0x48, 0x49, 0x4c, 0x44, 0x52, 0x45, 0x4e, 0x70, 0x68, 0x74, 0x74, 0x70, 0x5f, 0x63, 0x72, 0x65, 0x64, 0x65, 0x6e, 0x74, 0x69, 0x61, 0x6c, 0x73, 0x81, 0xa2, 0x64, 0x63, 0x6f, 0x64, 0x65, 0x01, 0x64, 0x6e, 0x61, 0x6d, 0x65, 0x6b, 0x73, 0x61, 0x6d, 0x65, 0x2d, 0x6f, 0x72, 0x69, 0x67, 0x69, 0x6e, 0x73, 0x74, 0x65, 0x78, 0x74, 0x5f, 0x65, 0x6e, 0x74, 0x72, 0x79, 0x5f, 0x65, 0x78, 0x63, 0x6c, 0x75, 0x64, 0x65, 0x64, 0x81, 0x66, 0x62, 0x75, 0x74, 0x74, 0x6f, 0x6e]
	facts : Protocol.Facts
	facts = { ops: [{ code: 1, name: "INST" }], kinds: [{ code: 1, name: "TEXT", events: [] }], policies: [{ bit: 1, name: "PREVENT" }], properties: [{ index: 1, name: "value", elements: ["input"] }], http_cache: [{ code: 1, name: "default" }], http_credentials: [{ code: 1, name: "same-origin" }], namespaces: [{ code: 0, name: "HTML" }], text_entry_excluded: ["button"], fault_classes: ["none", "contract"], template_nodes: [{ code: 1, name: "ELEMENT" }], child_containers: [{ code: 0, name: "CHILDREN" }] }
	decoded = ProtocolFacts.decode(bytes)?
	decoded == facts and ProtocolFacts.encode(facts) == bytes
}

## Duplicate keys, invalid UTF-8 and excessive nesting fail the released
## structural reader before a typed Facts value can be accepted.
expect ProtocolFacts.decode([0xa2, 0x61, 'a', 0, 0x61, 'a', 0]).is_err() and ProtocolFacts.decode([0xa1, 0x61, 255, 0]).is_err() and ProtocolFacts.decode([0x81, 0x81, 0x81, 0x81, 0x81, 0]).is_err()
