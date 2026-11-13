## Data-only SPC1/schema1 framing for a first-page claim envelope. This codec
## checks bounded topology and references, not hashes, DOM names, command meaning
## or an adoption verdict. Those independent boundaries consume its checked data.
PictureCodec :: [].{

	## Protocol ceilings may be lowered for a deployment, never enlarged.
	Limits := { max_bytes : U64 ?? 16777179, max_nodes : U32 ?? 262144, max_depth : U32 ?? 1024 }

	## Expanded identity is retained as facts. Only local must be nonempty;
	## neither a QName validator nor a creation factory belongs in this codec.
	Name : { namespace : Str, prefix : Str, local : Str }

	## The external mount is outside the physical/application node table.
	Owner : [Mount, Element(U32)]
	ContainerRole : [Children, Content]
	Container : { owner : Owner, role : ContainerRole, children : List(U32) }

	## Constructed indices refer to the final logical container after scaffolds
	## are removed; they are not physical child-array indices.
	Constructed : { container : U32, logical_child_index : U32, data : Str }
	Logical : [ExistingElement(U32), ExistingComment(U32), TextPart({ run : U32, part : U32 }), ConstructedText(Constructed), ConstructedComment(Constructed)]
	Physical : [Omitted, Physical(U32)]
	Part : { logical : U32, utf16_units : U32 }
	Run : { container : U32, child_index : U32, physical : Physical, parts : List(Part) }

	## Codes remain closed symbolic data until the writer's boundary. Unused
	## is valid only where the selected role carries no hole-kind operand.
	BindingKind : [Unused, Text, Attribute, Event, Bind, Reference, Property]
	BindingRole : [Static, Row, Hole, Alias]
	Binding : { birth_offset : U32, role : BindingRole, address : U32, slot : U32, kind : BindingKind, logical : U32 }
	Presence : [Absent, Present(Str)]
	Scaffold : [ControlText({ owner : U32, container : U32, physical : Physical }), AttributeOverride({ owner : U32, name : Name, original : Presence, physical : Presence }), NoSelectionOption({ owner : U32, physical_option : U32 })]

	## Producer records contain no model lifetime indices or executable policy.
	## Fingerprint and expected digest are uninterpreted exact32-byte values.
	Parts : { root_name : Name, batch_bytes : U32, fingerprint : List(U8), expected : List(U8), physical_count : U32, containers : List(Container), logical : List(Logical), runs : List(Run), bindings : List(Binding), scaffolds : List(Scaffold) }

	## A malformed byte range and an invalid producer graph remain separate
	## typed failures; neither is an absent-picture or replacement decision.
	Error : [InvalidLimits, ByteLimit({ maximum : U64, minimum : U64 }), NodeLimit({ maximum : U32, actual : U64 }), DepthLimit({ maximum : U32, actual : U32 }), Malformed({ at : U64, rule : Str }), InvalidParts(Str)]

	## Only make/read create an envelope. encoded_bytes is measured before a
	## writer grows its buffer, and cannot be invalidated by an external update.
	Envelope :: { parts : Parts, encoded_bytes : U64 }

	## Validate producer references and topology, then measure the exact bounded
	## representation before allocating its encoded output.
	make : Parts, Limits -> Try(Envelope, Error)
	make = |value, limits| {
		check_limits(limits)?
		validate(value, limits)?
		encoded_bytes = measure(value, limits.max_bytes)?
		Ok(Envelope.{ parts: value, encoded_bytes })
	}

	## Read every byte exactly once through checked fields. Counts are bounded
	## by remaining bytes before lists grow; exact graph validation follows.
	read : List(U8), Limits -> Try(Envelope, Error)
	read = |bytes, limits| {
		check_limits(limits)?
		if bytes.len() > limits.max_bytes {
			return Err(ByteLimit({ maximum: limits.max_bytes, minimum: bytes.len() }))
		}
		value = decode(bytes, limits)?
		PictureCodec.make(value, limits)
	}

	## Write one canonical representation into its measured capacity. A checked
	## envelope cannot exceed its accepted limit midway through serialization.
	encode : Envelope -> List(U8)
	encode = |envelope| {
		bytes = encode_parts(envelope.parts, List.with_capacity(envelope.encoded_bytes))
		if bytes.len() != envelope.encoded_bytes {
			crash "PictureCodec.encode: checked size and writer disagree"
		}
		bytes
	}

	## Move checked records to their consumer without deciding their meaning.
	parts : Envelope -> Parts
	parts = |envelope| envelope.parts
}

## A deployment cannot raise the protocol's established structural ceilings.
check_limits : PictureCodec.Limits -> Try({}, PictureCodec.Error)
check_limits = |limits| if limits.max_bytes > 16777179 or limits.max_nodes > 262144 or limits.max_depth > 1024 {
	Err(InvalidLimits)
} else {
	Ok({})
}

## A cursor holds only immutable input and its next unread byte offset.
Cursor : { bytes : List(U8), at : U64 }

## Frame errors point to the field which could not be consumed or interpreted.
need : Cursor, U64 -> Try({}, PictureCodec.Error)
need = |cursor, count| if count > cursor.bytes.len() - cursor.at {
	Err(Malformed({ at: cursor.at, rule: "truncated field" }))
} else {
	Ok({})
}

## Fixed-width words are checked before indexing any input byte.
read_u8 : Cursor -> Try({ value : U8, rest : Cursor }, PictureCodec.Error)
read_u8 = |cursor| {
	need(cursor, 1)?
	Ok({ value: cursor.bytes.get(cursor.at) ?? crash "PictureCodec.read_u8: guarded byte", rest: { ..cursor, at: cursor.at + 1 } })
}

## Little-endian widths are protocol facts, independent of a native layout.
read_u16 : Cursor -> Try({ value : U16, rest : Cursor }, PictureCodec.Error)
read_u16 = |cursor| {
	need(cursor, 2)?
	low = cursor.bytes.get(cursor.at) ?? crash "PictureCodec.read_u16: guarded byte"
	high = cursor.bytes.get(cursor.at + 1) ?? crash "PictureCodec.read_u16: guarded byte"
	Ok({ value: low.to_u16().bitwise_or(high.to_u16().shl_wrap(8)), rest: { ..cursor, at: cursor.at + 2 } })
}

## No host word or seamless boundary list is interpreted as a Roc record.
read_u32 : Cursor -> Try({ value : U32, rest : Cursor }, PictureCodec.Error)
read_u32 = |cursor| {
	need(cursor, 4)?
	first = (cursor.bytes.get(cursor.at) ?? crash "PictureCodec.read_u32: guarded byte").to_u32()
	second = (cursor.bytes.get(cursor.at + 1) ?? crash "PictureCodec.read_u32: guarded byte").to_u32()
	third = (cursor.bytes.get(cursor.at + 2) ?? crash "PictureCodec.read_u32: guarded byte").to_u32()
	fourth = (cursor.bytes.get(cursor.at + 3) ?? crash "PictureCodec.read_u32: guarded byte").to_u32()
	Ok({ value: first.bitwise_or(second.shl_wrap(8)).bitwise_or(third.shl_wrap(16)).bitwise_or(fourth.shl_wrap(24)), rest: { ..cursor, at: cursor.at + 4 } })
}

## Count prefixes cannot cause an allocation for records absent from the input.
read_count : Cursor, { minimum : U64, maximum : U64, label : Str } -> Try({ value : U64, rest : Cursor }, PictureCodec.Error)
read_count = |cursor, props| {
	decoded = read_u32(cursor)?
	count = decoded.value.to_u64()
	if count > props.maximum or count > (cursor.bytes.len() - decoded.rest.at) // props.minimum {
		return Err(Malformed({ at: cursor.at, rule: "${props.label} count exceeds its bound or remaining bytes" }))
	}
	Ok({ value: count, rest: decoded.rest })
}

## A text length is checked before slicing, and invalid UTF-8 is never repaired.
read_string : Cursor -> Try({ value : Str, rest : Cursor }, PictureCodec.Error)
read_string = |cursor| {
	size = read_u32(cursor)?
	count = size.value.to_u64()
	need(size.rest, count)?
	value = Str.from_utf8(cursor.bytes.sublist({ start: size.rest.at, len: count })) ? |_| Malformed({ at: size.rest.at, rule: "invalid UTF-8" })
	Ok({ value, rest: { ..size.rest, at: size.rest.at + count } })
}

## Names carry complete expanded facts; a colon stays local data.
read_name : Cursor -> Try({ value : PictureCodec.Name, rest : Cursor }, PictureCodec.Error)
read_name = |cursor| {
	namespace = read_string(cursor)?
	prefix = read_string(namespace.rest)?
	local = read_string(prefix.rest)?
	if local.value.is_empty() {
		return Err(Malformed({ at: prefix.rest.at, rule: "empty local name" }))
	}
	Ok({ value: { namespace: namespace.value, prefix: prefix.value, local: local.value }, rest: local.rest })
}

## Presence flags have exactly two encodings and no truthy extension.
read_presence : Cursor -> Try({ value : PictureCodec.Presence, rest : Cursor }, PictureCodec.Error)
read_presence = |cursor| {
	flag = read_u8(cursor)?
	match flag.value {
		0 => Ok({ value: Absent, rest: flag.rest })
		1 => {
			text = read_string(flag.rest)?
			Ok({ value: Present(text.value), rest: text.rest })
		}
		_ => Err(Malformed({ at: cursor.at, rule: "unknown presence" }))
	}
}

## Optional physical references retain omitted-run gaps distinctly from nodes.
read_physical : Cursor, U32 -> Try({ value : PictureCodec.Physical, rest : Cursor }, PictureCodec.Error)
read_physical = |cursor, count| {
	flag = read_u8(cursor)?
	match flag.value {
		0 => Ok({ value: Omitted, rest: flag.rest })
		1 => {
			node = read_u32(flag.rest)?
			physical_ref({ index: node.value, count })?
			Ok({ value: Physical(node.value), rest: node.rest })
		}
		_ => Err(Malformed({ at: cursor.at, rule: "unknown physical presence" }))
	}
}

## Range checks happen before a reference is indexed or appended as valid data.
physical_ref : { index : U32, count : U32 } -> Try({}, PictureCodec.Error)
physical_ref = |props| if props.index >= props.count {
	Err(InvalidParts("physical reference outside table"))
} else {
	Ok({})
}

## Fixed digest width is framing only; no hash is computed or certified here.
read_digest : Cursor -> Try({ value : List(U8), rest : Cursor }, PictureCodec.Error)
read_digest = |cursor| {
	need(cursor, 32)?
	Ok({ value: cursor.bytes.sublist({ start: cursor.at, len: 32 }), rest: { ..cursor, at: cursor.at + 32 } })
}

## Decode closed kind data before any consumer sees a numeric hole code.
read_binding_kind : Cursor -> Try({ value : PictureCodec.BindingKind, rest : Cursor }, PictureCodec.Error)
read_binding_kind = |cursor| {
	field = read_u8(cursor)?
	value = match field.value {
		0 => Unused
		1 => Text
		2 => Attribute
		3 => Event
		4 => Bind
		5 => Reference
		6 => Property
		_ => return Err(Malformed({ at: cursor.at, rule: "unknown binding kind" }))
	}
	Ok({ value, rest: field.rest })
}

## Each section checks record counts and individual references before growing
## its decoded lists. Future run references first obey their logical-table cap.
decode : List(U8), PictureCodec.Limits -> Try(PictureCodec.Parts, PictureCodec.Error)
decode = |bytes, limits| {
	var $cursor = { bytes, at: 0 }
	magic_field = read_u32($cursor)?
	$cursor = magic_field.rest
	magic = magic_field.value
	if magic != 0x31435053 {
		return Err(Malformed({ at: 0, rule: "magic" }))
	}
	schema_field = read_u16($cursor)?
	$cursor = schema_field.rest
	schema = schema_field.value
	protocol_field = read_u16($cursor)?
	$cursor = protocol_field.rest
	protocol = protocol_field.value
	flags_field = read_u32($cursor)?
	$cursor = flags_field.rest
	flags = flags_field.value
	if schema != 1 or protocol != 19 or flags != 0 {
		return Err(Malformed({ at: 4, rule: "schema, protocol or flags" }))
	}
	root_name_field = read_name($cursor)?
	$cursor = root_name_field.rest
	root_name = root_name_field.value
	batch_bytes_field = read_u32($cursor)?
	$cursor = batch_bytes_field.rest
	batch_bytes = batch_bytes_field.value
	fingerprint_field = read_digest($cursor)?
	$cursor = fingerprint_field.rest
	fingerprint = fingerprint_field.value
	expected_field = read_digest($cursor)?
	$cursor = expected_field.rest
	expected = expected_field.value
	physical_count_field = read_u32($cursor)?
	$cursor = physical_count_field.rest
	physical_count = physical_count_field.value
	if physical_count > limits.max_nodes {
		return Err(NodeLimit({ maximum: limits.max_nodes, actual: physical_count.to_u64() }))
	}
	if physical_count.to_u64() > (bytes.len() - $cursor.at) // 4 {
		return Err(Malformed({ at: $cursor.at, rule: "physical count exceeds placement bytes" }))
	}
	container_count_field = read_count($cursor, { minimum: 9, maximum: physical_count.to_u64() * 2 + 1, label: "container" })?
	$cursor = container_count_field.rest
	container_count = container_count_field.value
	if container_count == 0 {
		return Err(InvalidParts("missing mount container"))
	}
	var $containers = []
	for _container in 0..<container_count {
		owner_word_field = read_u32($cursor)?
		$cursor = owner_word_field.rest
		owner_word = owner_word_field.value
		role_word_field = read_u8($cursor)?
		$cursor = role_word_field.rest
		role_word = role_word_field.value

		owner = if owner_word == 0xffffffff {
			Mount
		} else {
			physical_ref({ index: owner_word, count: physical_count })?
			Element(owner_word)
		}
		role = match role_word {
			0 => Children
			1 => Content
			_ => return Err(Malformed({ at: $cursor.at - 1, rule: "unknown container role" }))
		}
		child_count_field = read_count($cursor, { minimum: 4, maximum: physical_count.to_u64(), label: "child" })?
		$cursor = child_count_field.rest
		child_count = child_count_field.value

		var $children = []
		for _child in 0..<child_count {
			child_field = read_u32($cursor)?
			$cursor = child_field.rest
			child = child_field.value
			physical_ref({ index: child, count: physical_count })?
			$children = $children.append(child)
		}
		$containers = $containers.append({ owner, role, children: $children })
	}
	containers = $containers
	logical_count_field = read_count($cursor, { minimum: 5, maximum: limits.max_nodes.to_u64(), label: "logical" })?
	$cursor = logical_count_field.rest
	logical_count = logical_count_field.value
	var $logical = []
	for _logical in 0..<logical_count {
		target_field = read_u8($cursor)?
		$cursor = target_field.rest
		target = target_field.value
		entry = match target {
			0 | 1 => {
				physical_field = read_u32($cursor)?
				$cursor = physical_field.rest
				physical = physical_field.value
				physical_ref({ index: physical, count: physical_count })?
				if (target == 0) ExistingElement(physical) else ExistingComment(physical)
			}
			2 => {
				run_field = read_u32($cursor)?
				$cursor = run_field.rest
				run = run_field.value
				part_field = read_u32($cursor)?
				$cursor = part_field.rest
				part = part_field.value
				if run.to_u64() >= logical_count or part.to_u64() >= logical_count {
					return Err(InvalidParts("text part reference exceeds logical table"))
				}
				TextPart({ run, part })
			}
			3 | 4 => {
				container_field = read_u32($cursor)?
				$cursor = container_field.rest
				container = container_field.value
				logical_child_index_field = read_u32($cursor)?
				$cursor = logical_child_index_field.rest
				logical_child_index = logical_child_index_field.value
				if container.to_u64() >= containers.len() or logical_child_index.to_u64() >= logical_count {
					return Err(InvalidParts("constructed container or logical position reference"))
				}
				data_field = read_string($cursor)?
				$cursor = data_field.rest
				data = data_field.value
				value = { container, logical_child_index, data }
				if (target == 3) ConstructedText(value) else ConstructedComment(value)
			}
			_ => return Err(Malformed({ at: $cursor.at - 1, rule: "unknown logical target" }))
		}
		$logical = $logical.append(entry)
	}
	logical = $logical
	run_count_field = read_count($cursor, { minimum: 13, maximum: logical_count, label: "run" })?
	$cursor = run_count_field.rest
	run_count = run_count_field.value
	for entry in logical {
		match entry {
			TextPart(value) if value.run.to_u64() >= run_count => return Err(InvalidParts("unknown text run"))
			_ => {}
		}
	}
	var $runs = []
	var $run_index = 0.U32
	for _run in 0..<run_count {
		container_field = read_u32($cursor)?
		$cursor = container_field.rest
		container = container_field.value
		child_index_field = read_u32($cursor)?
		$cursor = child_index_field.rest
		child_index = child_index_field.value
		if container.to_u64() >= containers.len() {
			return Err(InvalidParts("run container reference"))
		}
		declared_container = containers.get(container.to_u64()) ?? crash "PictureCodec.decode: checked run container"
		if child_index.to_u64() > declared_container.children.len() {
			return Err(InvalidParts("run child index beyond container"))
		}
		physical_field = read_physical($cursor, physical_count)?
		$cursor = physical_field.rest
		physical = physical_field.value
		part_count_field = read_count($cursor, { minimum: 8, maximum: logical_count, label: "text part" })?
		$cursor = part_count_field.rest
		part_count = part_count_field.value
		if part_count == 0 {
			return Err(InvalidParts("empty text run"))
		}
		var $parts = []
		var $part_index = 0.U32
		for _part in 0..<part_count {
			logical_index_field = read_u32($cursor)?
			$cursor = logical_index_field.rest
			logical_index = logical_index_field.value
			utf16_units_field = read_u32($cursor)?
			$cursor = utf16_units_field.rest
			utf16_units = utf16_units_field.value
			if logical_index.to_u64() >= logical.len() {
				return Err(InvalidParts("part logical reference"))
			}
			match logical.get(logical_index.to_u64()) ?? crash "PictureCodec.decode: checked logical index" {
				TextPart(value) if value.run == $run_index and value.part == $part_index => {}
				_ => return Err(InvalidParts("text part back reference"))
			}
			$parts = $parts.append({ logical: logical_index, utf16_units })
			$part_index = $part_index + 1
		}
		$runs = $runs.append({ container, child_index, physical, parts: $parts })
		$run_index = $run_index + 1
	}
	runs = $runs
	binding_count_field = read_count($cursor, { minimum: 18, maximum: limits.max_bytes // 18, label: "binding" })?
	$cursor = binding_count_field.rest
	binding_count = binding_count_field.value
	var $bindings = []
	for _binding in 0..<binding_count {
		birth_offset_field = read_u32($cursor)?
		$cursor = birth_offset_field.rest
		birth_offset = birth_offset_field.value
		role_word_field = read_u8($cursor)?
		$cursor = role_word_field.rest
		role_word = role_word_field.value
		if birth_offset == 0 or birth_offset >= batch_bytes {
			return Err(InvalidParts("binding birth outside ordinary batch"))
		}
		role = match role_word {
			0 => Static
			1 => Row
			2 => Hole
			3 => Alias
			_ => return Err(Malformed({ at: $cursor.at - 1, rule: "unknown binding role" }))
		}
		address_field = read_u32($cursor)?
		$cursor = address_field.rest
		address = address_field.value
		slot_field = read_u32($cursor)?
		$cursor = slot_field.rest
		slot = slot_field.value
		kind_field = read_binding_kind($cursor)?
		$cursor = kind_field.rest
		kind = kind_field.value
		logical_index_field = read_u32($cursor)?
		$cursor = logical_index_field.rest
		logical_index = logical_index_field.value
		if address == 0 or address == 0xffffffff or logical_index.to_u64() >= logical.len() {
			return Err(InvalidParts("binding address or logical reference"))
		}
		check_binding_fields({ role, slot, kind })?
		$bindings = $bindings.append({ birth_offset, role, address, slot, kind, logical: logical_index })
	}
	bindings = $bindings
	scaffold_count_field = read_count($cursor, { minimum: 9, maximum: limits.max_bytes // 9, label: "scaffold" })?
	$cursor = scaffold_count_field.rest
	scaffold_count = scaffold_count_field.value
	var $scaffolds = []
	for _scaffold in 0..<scaffold_count {
		role_field = read_u8($cursor)?
		$cursor = role_field.rest
		role = role_field.value
		owner_field = read_u32($cursor)?
		$cursor = owner_field.rest
		owner = owner_field.value
		physical_ref({ index: owner, count: physical_count })?
		scaffold = match role {
			0 => {
				container_field = read_u32($cursor)?
				$cursor = container_field.rest
				container = container_field.value
				if container.to_u64() >= containers.len() {
					return Err(InvalidParts("control text container reference"))
				}
				physical_field = read_physical($cursor, physical_count)?
				$cursor = physical_field.rest
				physical = physical_field.value
				ControlText({ owner, container, physical })
			}
			1 => {
				name_field = read_name($cursor)?
				$cursor = name_field.rest
				name = name_field.value
				original_field = read_presence($cursor)?
				$cursor = original_field.rest
				original = original_field.value
				physical_field = read_presence($cursor)?
				$cursor = physical_field.rest
				physical = physical_field.value
				AttributeOverride({ owner, name, original, physical })
			}
			2 => {
				physical_option_field = read_u32($cursor)?
				$cursor = physical_option_field.rest
				physical_option = physical_option_field.value
				physical_ref({ index: physical_option, count: physical_count })?
				NoSelectionOption({ owner, physical_option })
			}
			_ => return Err(Malformed({ at: $cursor.at, rule: "unknown scaffold role" }))
		}
		$scaffolds = $scaffolds.append(scaffold)
	}
	if $cursor.at != bytes.len() {
		return Err(Malformed({ at: $cursor.at, rule: "trailing bytes" }))
	}
	Ok({ root_name, batch_bytes, fingerprint, expected, physical_count, containers, logical, runs, bindings, scaffolds: $scaffolds })
}

## These are temporary validation facts, never engine node storage or a view.
Placement : [Unplaced, Placed({ container : U32, index : U32 })]

PhysicalKind : [Unclaimed, Element, Text, Comment]

TextCoverage : [Unseen, Seen]

## A declared role must cover its physical ordinal exactly once.
claim_physical : List(PhysicalKind), { node : U32, kind : PhysicalKind } -> Try(List(PhysicalKind), PictureCodec.Error)
claim_physical = |kinds, props| {
	match kinds.get(props.node.to_u64()) {
		Ok(Unclaimed) => Ok(kinds.set(props.node.to_u64(), props.kind) ?? crash "PictureCodec.claim_physical: checked ordinal")
		Ok(_) => Err(InvalidParts("duplicate physical claim"))
		Err(_) => Err(InvalidParts("physical claim outside table"))
	}
}

## Read a bounded container by its ordinal without a fallback container.
container_at : List(PictureCodec.Container), U32 -> Try(PictureCodec.Container, PictureCodec.Error)
container_at = |containers, index| containers.get(index.to_u64()).map_err(|_| InvalidParts("container reference outside table"))

## Logical children are counted only after their physical placement is known.
placed_in : List(Placement), U32 -> Try({ container : U32, index : U32 }, PictureCodec.Error)
placed_in = |parents, node| match parents.get(node.to_u64()) {
	Ok(Placed(parent)) => Ok(parent)
	_ => Err(InvalidParts("unplaced physical node"))
}

## Every count remains within protocol/deployment bounds before validation
## allocates its temporary parent, kind, coverage or depth arrays.
validate : PictureCodec.Parts, PictureCodec.Limits -> Try({}, PictureCodec.Error)
validate = |value, limits| {
	count = value.physical_count.to_u64()
	if value.physical_count > limits.max_nodes {
		return Err(NodeLimit({ maximum: limits.max_nodes, actual: count }))
	}
	if value.logical.len() > limits.max_nodes.to_u64() {
		return Err(NodeLimit({ maximum: limits.max_nodes, actual: value.logical.len() }))
	}
	if value.containers.is_empty() or value.containers.len() > count * 2 + 1 {
		return Err(InvalidParts("container count"))
	}
	if value.runs.len() > value.logical.len() or value.bindings.len() > limits.max_bytes // 18 or value.scaffolds.len() > limits.max_bytes // 9 {
		return Err(InvalidParts("record count"))
	}
	if value.root_name.local.is_empty() {
		return Err(InvalidParts("empty root local name"))
	}
	if value.fingerprint.len() != 32 or value.expected.len() != 32 {
		return Err(InvalidParts("digest width must be 32 bytes"))
	}
	var $parents = List.repeat(Unplaced, count)
	var $kinds = List.repeat(Unclaimed, count)
	var $container_keys = Dict.empty()
	var $container_index = 0.U32
	for container in value.containers {
		if $container_index == 0 {
			if container.owner != Mount or container.role != Children {
				return Err(InvalidParts("container0 must be external mount Children"))
			}
		} else {
			match container.owner {
				Mount => return Err(InvalidParts("only container0 may have Mount owner"))
				Element(owner) => physical_ref({ index: owner, count: value.physical_count })?
			}
		}
		key = { owner: container.owner, role: container.role }
		if $container_keys.contains(key) {
			return Err(InvalidParts("duplicate container owner/role"))
		}
		$container_keys = $container_keys.insert(key, $container_index)
		if container.children.len() > count {
			return Err(InvalidParts("child count exceeds physical table"))
		}
		var $previous = NoPrevious
		var $child_index = 0.U32
		for child in container.children {
			physical_ref({ index: child, count: value.physical_count })?
			match $previous {
				Previous(prior) if child <= prior => return Err(InvalidParts("physical sibling preorder"))
				_ => {}
			}
			match container.owner {
				Element(owner) if child <= owner => return Err(InvalidParts("owner must precede child"))
				_ => {}
			}
			match $parents.get(child.to_u64()) ?? crash "PictureCodec.validate: checked child" {
				Unplaced => {}
				_ => return Err(InvalidParts("duplicate physical placement"))
			}
			$parents = $parents.set(child.to_u64(), Placed({ container: $container_index, index: $child_index })) ?? crash "PictureCodec.validate: checked child"
			$previous = Previous(child)
			$child_index = $child_index + 1
		}
		$container_index = $container_index + 1
	}
	parents = $parents
	var $logical_children = List.repeat(0.U32, value.containers.len())
	var $constructed = Dict.empty()
	for entry in value.logical {
		match entry {
			ExistingElement(node) | ExistingComment(node) => {
				physical_ref({ index: node, count: value.physical_count })?
				parent = placed_in(parents, node)?
				kind = match entry {
					ExistingElement(_) => Element
					_ => Comment
				}
				$kinds = claim_physical($kinds, { node, kind })?
				before = $logical_children.get(parent.container.to_u64()) ?? crash "PictureCodec.validate: checked container"
				$logical_children = $logical_children.set(parent.container.to_u64(), before + 1) ?? crash "PictureCodec.validate: checked container"
			}
			TextPart(part) => if part.run.to_u64() >= value.runs.len() {
				return Err(InvalidParts("unknown text run"))
			}
			ConstructedText(item) | ConstructedComment(item) => {
				_ = container_at(value.containers, item.container)?
				key = { container: item.container, index: item.logical_child_index }
				if $constructed.contains(key) {
					return Err(InvalidParts("duplicate constructed logical position"))
				}
				$constructed = $constructed.insert(key, {})
				before = $logical_children.get(item.container.to_u64()) ?? crash "PictureCodec.validate: checked constructed container"
				$logical_children = $logical_children.set(item.container.to_u64(), before + 1) ?? crash "PictureCodec.validate: checked constructed container"
			}
		}
	}
	var $seen_parts = List.repeat(Unseen, value.logical.len())
	var $run_positions = Dict.empty()
	var $run_containers = Dict.empty()
	var $run_index = 0.U32
	for run in value.runs {
		container = container_at(value.containers, run.container)?
		key = { container: run.container, index: run.child_index }
		if $run_positions.contains(key) {
			return Err(InvalidParts("duplicate run position"))
		}
		$run_positions = $run_positions.insert(key, {})
		$run_containers = $run_containers.insert(run.container, {})
		match run.physical {
			Omitted => if run.child_index.to_u64() > container.children.len() {
				return Err(InvalidParts("omitted run gap"))
			}
			Physical(node) => {
				physical_ref({ index: node, count: value.physical_count })?
				if container.children.get(run.child_index.to_u64()) != Ok(node) {
					return Err(InvalidParts("run physical position"))
				}
				$kinds = claim_physical($kinds, { node, kind: Text })?
			}
		}
		if run.parts.is_empty() or run.parts.len() > value.logical.len() {
			return Err(InvalidParts("text part count"))
		}
		var $part_index = 0.U32
		for part in run.parts {
			if part.logical.to_u64() >= value.logical.len() {
				return Err(InvalidParts("text part logical reference"))
			}
			match value.logical.get(part.logical.to_u64()) ?? crash "PictureCodec.validate: checked part" {
				TextPart(target) if target.run == $run_index and target.part == $part_index => {}
				_ => return Err(InvalidParts("text part back reference"))
			}
			if ($seen_parts.get(part.logical.to_u64()) ?? crash "PictureCodec.validate: checked part") != Unseen {
				return Err(InvalidParts("duplicate text part"))
			}
			if run.physical == Omitted and part.utf16_units != 0 {
				return Err(InvalidParts("omitted text has nonzero units"))
			}
			$seen_parts = $seen_parts.set(part.logical.to_u64(), Seen) ?? crash "PictureCodec.validate: checked part"
			$part_index = $part_index + 1
		}
		before = $logical_children.get(run.container.to_u64()) ?? crash "PictureCodec.validate: checked run container"
		$logical_children = $logical_children.set(run.container.to_u64(), before + run.parts.len().to_u32_wrap()) ?? crash "PictureCodec.validate: checked run container"
		$run_index = $run_index + 1
	}
	var $logical_index = 0.U64
	for entry in value.logical {
		match entry {
			TextPart(_) if ($seen_parts.get($logical_index) ?? crash "PictureCodec.validate: checked logical coverage") != Seen => return Err(InvalidParts("missing text part"))
			ConstructedText(item) | ConstructedComment(item) => if item.logical_child_index >= ($logical_children.get(item.container.to_u64()) ?? crash "PictureCodec.validate: checked logical container") {
				return Err(InvalidParts("constructed final logical position"))
			}
			_ => {}
		}
		$logical_index = $logical_index + 1
	}
	var $principals = Dict.empty()
	var $holes = Dict.empty()
	for binding in value.bindings {
		if binding.birth_offset == 0 or binding.birth_offset >= value.batch_bytes {
			return Err(InvalidParts("binding birth outside ordinary batch"))
		}
		if binding.address == 0 or binding.address == 0xffffffff or binding.logical.to_u64() >= value.logical.len() {
			return Err(InvalidParts("binding address or logical reference"))
		}
		check_binding_fields({ role: binding.role, slot: binding.slot, kind: binding.kind })?
		if binding.role == Hole {
			key = { birth_offset: binding.birth_offset, address: binding.address, slot: binding.slot }
			if $holes.contains(key) {
				return Err(InvalidParts("duplicate Hole binding"))
			}
			$holes = $holes.insert(key, {})
		} else {
			key = { birth_offset: binding.birth_offset, address: binding.address }
			if $principals.contains(key) {
				return Err(InvalidParts("duplicate principal binding"))
			}
			$principals = $principals.insert(key, {})
		}
	}
	var $control_keys = Dict.empty()
	var $attribute_keys = Dict.empty()
	var $selection_keys = Dict.empty()
	for scaffold in value.scaffolds {
		match scaffold {
			ControlText(item) => {
				physical_ref({ index: item.owner, count: value.physical_count })?
				container = container_at(value.containers, item.container)?
				if container.owner != Element(item.owner) or $run_containers.contains(item.container) {
					return Err(InvalidParts("control text container owner or run"))
				}
				match item.physical {
					Omitted => if !container.children.is_empty() {
						return Err(InvalidParts("omitted control text has physical children"))
					}
					Physical(node) => {
						if container.children != [node] {
							return Err(InvalidParts("control text must be sole physical child"))
						}
						$kinds = claim_physical($kinds, { node, kind: Text })?
					}
				}
				key = { owner: item.owner, container: item.container }
				if $control_keys.contains(key) {
					return Err(InvalidParts("duplicate control text scaffold"))
				}
				$control_keys = $control_keys.insert(key, {})
			}
			AttributeOverride(item) => {
				physical_ref({ index: item.owner, count: value.physical_count })?
				if item.name.local.is_empty() {
					return Err(InvalidParts("empty attribute local name"))
				}
				key = { owner: item.owner, namespace: item.name.namespace, local: item.name.local }
				if $attribute_keys.contains(key) {
					return Err(InvalidParts("duplicate scaffold attribute identity"))
				}
				$attribute_keys = $attribute_keys.insert(key, {})
			}
			NoSelectionOption(item) => {
				physical_ref({ index: item.owner, count: value.physical_count })?
				parent = placed_in(parents, item.physical_option)?
				container = container_at(value.containers, parent.container)?
				if container.owner != Element(item.owner) or container.role != Children {
					return Err(InvalidParts("selection scaffold direct parent"))
				}
				$kinds = claim_physical($kinds, { node: item.physical_option, kind: Element })?
				if $selection_keys.contains(item.owner) {
					return Err(InvalidParts("duplicate selection scaffold"))
				}
				$selection_keys = $selection_keys.insert(item.owner, {})
			}
		}
	}
	kinds = $kinds
	for container in value.containers {
		match container.owner {
			Mount => {}
			Element(owner) => if kinds.get(owner.to_u64()) != Ok(Element) {
				return Err(InvalidParts("container owner is not an Element"))
			}
		}
	}
	for scaffold in value.scaffolds {
		owner = match scaffold {
			ControlText(item) => item.owner
			AttributeOverride(item) => item.owner
			NoSelectionOption(item) => item.owner
		}
		if kinds.get(owner.to_u64()) != Ok(Element) {
			return Err(InvalidParts("scaffold owner is not an Element"))
		}
	}
	var $depths = List.repeat(0.U32, count)
	var $ancestry = []
	var $ordinal = 0.U32
	for kind in kinds {
		if kind == Unclaimed {
			return Err(InvalidParts("missing physical coverage"))
		}
		if kind == Element and !$container_keys.contains({ owner: Element($ordinal), role: Children }) {
			return Err(InvalidParts("missing Element Children container"))
		}
		parent = placed_in(parents, $ordinal)?
		container = container_at(value.containers, parent.container)?
		depth = match container.owner {
			Mount => {
				$ancestry = []
				1
			}
			Element(owner) => {
				while !$ancestry.is_empty() and $ancestry.last() != Ok(owner) {
					$ancestry = $ancestry.drop_last(1)
				}
				if $ancestry.is_empty() {
					return Err(InvalidParts("physical forest is not preorder"))
				}
				($depths.get(owner.to_u64()) ?? crash "PictureCodec.validate: earlier parent depth") + 1
			}
		}
		if depth > limits.max_depth {
			return Err(DepthLimit({ maximum: limits.max_depth, actual: depth }))
		}
		$depths = $depths.set($ordinal.to_u64(), depth) ?? crash "PictureCodec.validate: bounded physical ordinal"
		$ancestry = $ancestry.append($ordinal)
		$ordinal = $ordinal + 1
	}
	depths = $depths
	for entry in value.logical {
		match entry {
			ConstructedText(item) | ConstructedComment(item) => {
				container = container_at(value.containers, item.container)?
				check_leaf_depth(depths, { owner: container.owner, maximum: limits.max_depth })?
			}
			_ => {}
		}
	}
	for run in value.runs {
		container = container_at(value.containers, run.container)?
		check_leaf_depth(depths, { owner: container.owner, maximum: limits.max_depth })?
	}
	Ok({})
}

## Reserve a measured term before the writer allocates or grows any output.
## minimum names the required prefix size, not a promise to measure rejected tails.
charge : { used : U64, more : U64, maximum : U64 } -> Try(U64, PictureCodec.Error)
charge = |props| if props.more > props.maximum - props.used {
	Err(ByteLimit({ maximum: props.maximum, minimum: props.used + props.more }))
} else {
	Ok(props.used + props.more)
}

## A string's explicit u32 prefix must represent its complete UTF-8 byte length.
string_size : Str -> Try(U64, PictureCodec.Error)
string_size = |text| {
	count = text.count_utf8_bytes()
	if count > 0xffffffff {
		return Err(InvalidParts("string exceeds u32 framing"))
	}
	Ok(4 + count)
}

## Expanded names have three independent string fields, without canonicalization.
name_size : PictureCodec.Name -> Try(U64, PictureCodec.Error)
name_size = |name| {
	namespace = string_size(name.namespace)?
	prefix = string_size(name.prefix)?
	local = string_size(name.local)?
	Ok(namespace + prefix + local)
}

## Optional values and physical references use their one-byte presence flag.
presence_size : PictureCodec.Presence -> Try(U64, PictureCodec.Error)
presence_size = |value| match value {
	Absent => Ok(1)
	Present(text) => string_size(text).map_ok(|count| count + 1)
}

## Every variable-size term is charged against the configured ceiling. Record
## counts have already been bounded by validate before these multiplications.
measure : PictureCodec.Parts, U64 -> Try(U64, PictureCodec.Error)
measure = |value, maximum| {
	var $used = charge({ used: 0, more: 104, maximum })?
	$used = charge({ used: $used, more: name_size(value.root_name)?, maximum })?
	for container in value.containers {
		$used = charge({ used: $used, more: 9 + 4 * container.children.len(), maximum })?
	}
	for entry in value.logical {
		size = match entry {
			ExistingElement(_) | ExistingComment(_) => 5
			TextPart(_) => 9
			ConstructedText(item) | ConstructedComment(item) => 9 + string_size(item.data)?
		}
		$used = charge({ used: $used, more: size, maximum })?
	}
	for run in value.runs {
		$used = charge({
			used: $used,
			more: 13 + 8 * run.parts.len() + match run.physical {
				Omitted => 0
				Physical(_) => 4
			},
			maximum,
		})?
	}
	$used = charge({ used: $used, more: 18 * value.bindings.len(), maximum })?
	for scaffold in value.scaffolds {
		size = match scaffold {
			ControlText(item) => 10 + match item.physical {
				Omitted => 0
				Physical(_) => 4
			}
			AttributeOverride(item) => 5 + name_size(item.name)? + presence_size(item.original)? + presence_size(item.physical)?
			NoSelectionOption(_) => 9
		}
		$used = charge({ used: $used, more: size, maximum })?
	}
	Ok($used)
}

## Fixed-width words are written independently of the compiler's struct layout.
put_u32 : List(U8), U32 -> List(U8)
put_u32 = |bytes, value| bytes.append(value.to_u8_wrap()).append(value.shr_wrap(8).to_u8_wrap()).append(value.shr_wrap(16).to_u8_wrap()).append(value.shr_wrap(24).to_u8_wrap())

## The source envelope proved this string fits its u32 length prefix.
put_string : List(U8), Str -> List(U8)
put_string = |bytes, text| put_u32(bytes, text.count_utf8_bytes().to_u32_wrap()).concat(text.to_utf8())

## A name is exactly URI, prefix and local; local colons stay untouched.
put_name : List(U8), PictureCodec.Name -> List(U8)
put_name = |bytes, name| put_string(put_string(put_string(bytes, name.namespace), name.prefix), name.local)

## Only explicit absence omits a value operand; present empty text survives.
put_presence : List(U8), PictureCodec.Presence -> List(U8)
put_presence = |bytes, value| match value {
	Absent => bytes.append(0)
	Present(text) => put_string(bytes.append(1), text)
}

## Omitted text gaps have no physical ordinal operand.
put_physical : List(U8), PictureCodec.Physical -> List(U8)
put_physical = |bytes, value| match value {
	Omitted => bytes.append(0)
	Physical(node) => put_u32(bytes.append(1), node)
}

## Keep closed role data symbolic until the single byte boundary.
binding_kind_byte : PictureCodec.BindingKind -> U8
binding_kind_byte = |kind| match kind {
	Unused => 0
	Text => 1
	Attribute => 2
	Event => 3
	Bind => 4
	Reference => 5
	Property => 6
}

## The writer consumes only checked records and its own pre-sized buffer.
encode_parts : PictureCodec.Parts, List(U8) -> List(U8)
encode_parts = |value, allocated| {
	var $out = allocated.concat([83, 80, 67, 49, 1, 0, 19, 0, 0, 0, 0, 0])
	$out = put_u32(put_name($out, value.root_name), value.batch_bytes).concat(value.fingerprint).concat(value.expected)
	$out = put_u32(put_u32($out, value.physical_count), value.containers.len().to_u32_wrap())
	for container in value.containers {
		owner = match container.owner {
			Mount => 0xffffffff
			Element(node) => node
		}
		role = match container.role {
			Children => 0
			Content => 1
		}
		$out = put_u32(put_u32($out, owner).append(role), container.children.len().to_u32_wrap())
		for child in container.children {
			$out = put_u32($out, child)
		}
	}
	$out = put_u32($out, value.logical.len().to_u32_wrap())
	for entry in value.logical {
		$out = match entry {
			ExistingElement(node) => put_u32($out.append(0), node)
			ExistingComment(node) => put_u32($out.append(1), node)
			TextPart(part) => put_u32(put_u32($out.append(2), part.run), part.part)
			ConstructedText(item) => put_string(put_u32(put_u32($out.append(3), item.container), item.logical_child_index), item.data)
			ConstructedComment(item) => put_string(put_u32(put_u32($out.append(4), item.container), item.logical_child_index), item.data)
		}
	}
	$out = put_u32($out, value.runs.len().to_u32_wrap())
	for run in value.runs {
		$out = put_u32(put_physical(put_u32(put_u32($out, run.container), run.child_index), run.physical), run.parts.len().to_u32_wrap())
		for part in run.parts {
			$out = put_u32(put_u32($out, part.logical), part.utf16_units)
		}
	}
	$out = put_u32($out, value.bindings.len().to_u32_wrap())
	for binding in value.bindings {
		role = match binding.role {
			Static => 0
			Row => 1
			Hole => 2
			Alias => 3
		}
		$out = put_u32(put_u32(put_u32(put_u32($out, binding.birth_offset).append(role), binding.address), binding.slot).append(binding_kind_byte(binding.kind)), binding.logical)
	}
	$out = put_u32($out, value.scaffolds.len().to_u32_wrap())
	for scaffold in value.scaffolds {
		$out = match scaffold {
			ControlText(item) => put_physical(put_u32(put_u32($out.append(0), item.owner), item.container), item.physical)
			AttributeOverride(item) => put_presence(put_presence(put_name(put_u32($out.append(1), item.owner), item.name), item.original), item.physical)
			NoSelectionOption(item) => put_u32(put_u32($out.append(2), item.owner), item.physical_option)
		}
	}
	$out
}

## The minimal record facts are authored separately from the golden wire bytes.
empty_fixture : {} -> PictureCodec.Parts
empty_fixture = |_| {
	root_name: { namespace: "", prefix: "", local: "div" },
	batch_bytes: 0,
	fingerprint: List.repeat(17, 32),
	expected: List.repeat(34, 32),
	physical_count: 0,
	containers: [{ owner: Mount, role: Children, children: [] }],
	logical: [],
	runs: [],
	bindings: [],
	scaffolds: [],
}

## A hand-authored wire item pins header order, the batch word, hashes and the
## external empty container without consulting the encoder under test.
golden_empty = [83, 80, 67, 49, 1, 0, 19, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 'd', 'i', 'v', 0, 0, 0, 0]
	.concat(List.repeat(17, 32)).concat(List.repeat(34, 32))
	.concat([0, 0, 0, 0, 1, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

## Every data role appears in this independent graph: ordinary/content edges,
## omitted text, constructed originals, all bindings and control scaffolds.
rich_fixture : {} -> PictureCodec.Parts
rich_fixture = |_| {
	root_name: { namespace: "urn:root", prefix: "", local: "xmlns" },
	batch_bytes: 32,
	fingerprint: List.repeat(17, 32),
	expected: List.repeat(34, 32),
	physical_count: 8,
	containers: [
		{ owner: Mount, role: Children, children: [0, 4, 6] },
		{ owner: Element(0), role: Children, children: [1, 2] },
		{ owner: Element(0), role: Content, children: [3] },
		{ owner: Element(4), role: Children, children: [5] },
		{ owner: Element(6), role: Children, children: [7] },
		{ owner: Element(7), role: Children, children: [] },
	],
	logical: [ExistingElement(0), TextPart({ run: 0, part: 0 }), TextPart({ run: 0, part: 1 }), ExistingComment(2), ExistingComment(3), ExistingElement(4), ConstructedText({ container: 3, logical_child_index: 0, data: "original\nλ" }), ConstructedComment({ container: 3, logical_child_index: 1, data: "original comment" }), ExistingElement(6), TextPart({ run: 1, part: 0 })],
	runs: [
		{ container: 1, child_index: 0, physical: Physical(1), parts: [{ logical: 1, utf16_units: 0 }, { logical: 2, utf16_units: 2 }] },
		{ container: 0, child_index: 3, physical: Omitted, parts: [{ logical: 9, utf16_units: 0 }] },
	],
	bindings: [
		{ birth_offset: 1, role: Static, address: 1, slot: 0, kind: Unused, logical: 0 },
		{ birth_offset: 2, role: Row, address: 2, slot: 7, kind: Unused, logical: 5 },
		{ birth_offset: 2, role: Hole, address: 2, slot: 0, kind: Text, logical: 2 },
		{ birth_offset: 2, role: Alias, address: 3, slot: 1, kind: Reference, logical: 8 },
		{ birth_offset: 2, role: Hole, address: 2, slot: 1, kind: Reference, logical: 8 },
		{ birth_offset: 31, role: Static, address: 4, slot: 0, kind: Unused, logical: 6 },
	],
	scaffolds: [
		ControlText({ owner: 4, container: 3, physical: Physical(5) }),
		AttributeOverride({ owner: 6, name: { namespace: "urn:a", prefix: "p", local: "x" }, original: Present(""), physical: Present("false") }),
		NoSelectionOption({ owner: 6, physical_option: 7 }),
	],
}

## Independent schema bytes pin every variant and the actual order of operands.
golden_rich = [
	83,
	80,
	67,
	49,
	1,
	0,
	19,
	0,
	0,
	0,
	0,
	0,
	8,
	0,
	0,
	0,
	117,
	114,
	110,
	58,
	114,
	111,
	111,
	116,
	0,
	0,
	0,
	0,
	5,
	0,
	0,
	0,
	120,
	109,
	108,
	110,
	115,
	32,
	0,
	0,
	0,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	17,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	34,
	8,
	0,
	0,
	0,
	6,
	0,
	0,
	0,
	255,
	255,
	255,
	255,
	0,
	3,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	4,
	0,
	0,
	0,
	6,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	0,
	0,
	0,
	3,
	0,
	0,
	0,
	4,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	5,
	0,
	0,
	0,
	6,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	7,
	0,
	0,
	0,
	7,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	10,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	1,
	2,
	0,
	0,
	0,
	1,
	3,
	0,
	0,
	0,
	0,
	4,
	0,
	0,
	0,
	3,
	3,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	11,
	0,
	0,
	0,
	111,
	114,
	105,
	103,
	105,
	110,
	97,
	108,
	10,
	206,
	187,
	4,
	3,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	16,
	0,
	0,
	0,
	111,
	114,
	105,
	103,
	105,
	110,
	97,
	108,
	32,
	99,
	111,
	109,
	109,
	101,
	110,
	116,
	0,
	6,
	0,
	0,
	0,
	2,
	1,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	3,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	9,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	6,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	1,
	2,
	0,
	0,
	0,
	7,
	0,
	0,
	0,
	0,
	5,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	2,
	2,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	2,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	3,
	3,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	5,
	8,
	0,
	0,
	0,
	2,
	0,
	0,
	0,
	2,
	2,
	0,
	0,
	0,
	1,
	0,
	0,
	0,
	5,
	8,
	0,
	0,
	0,
	31,
	0,
	0,
	0,
	0,
	4,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	6,
	0,
	0,
	0,
	3,
	0,
	0,
	0,
	0,
	4,
	0,
	0,
	0,
	3,
	0,
	0,
	0,
	1,
	5,
	0,
	0,
	0,
	1,
	6,
	0,
	0,
	0,
	5,
	0,
	0,
	0,
	117,
	114,
	110,
	58,
	97,
	1,
	0,
	0,
	0,
	112,
	1,
	0,
	0,
	0,
	120,
	1,
	0,
	0,
	0,
	0,
	1,
	5,
	0,
	0,
	0,
	102,
	97,
	108,
	115,
	101,
	2,
	6,
	0,
	0,
	0,
	7,
	0,
	0,
	0,
]

## A known wire fixture decodes into separately authored facts; writer equality
## is an additional assertion, not the only oracle for either direction.
expect {
	decoded = PictureCodec.read(golden_empty, {})?
	made = PictureCodec.make(empty_fixture({}), {})?
	{ parts: PictureCodec.parts(decoded), bytes: PictureCodec.encode(made), length: golden_empty.len() } == { parts: empty_fixture({}), bytes: golden_empty, length: 128 }
}

## Constructed position1 remains legal beside one physical control text child;
## prefix and raw text values survive without DOM/name semantics in the codec.
expect {
	decoded = PictureCodec.read(golden_rich, {})?
	made = PictureCodec.make(rich_fixture({}), {})?
	{ parts: PictureCodec.parts(decoded), bytes: PictureCodec.encode(made) } == { parts: rich_fixture({}), bytes: golden_rich }
}

## Header changes, invalid UTF-8, unknown roles and count bombs are refusals,
## never a silently absent or partially accepted deployment picture.
expect {
	corruptions = [
		golden_empty.set(0, 0)?,
		golden_empty.set(4, 2)?,
		golden_empty.set(6, 18)?,
		golden_empty.set(8, 1)?,
		golden_empty.set(24, 255)?,
		golden_empty.set(20, 0)?,
		golden_empty.set(95, 255)?,
		golden_empty.set(99, 255)?.set(100, 255)?.set(101, 255)?.set(102, 255)?,
		golden_empty.set(107, 2)?,
		golden_empty.append(0),
	]
	corruptions.all(|bytes| PictureCodec.read(bytes, {}).is_err())
}

## Every incomplete prefix of an independently authored valid item is rejected.
expect {
	var $has_accepted_prefix = False
	for end in 0..<golden_rich.len() {
		if PictureCodec.read(golden_rich.take_first(end), {}).is_ok() {
			$has_accepted_prefix = True
		}
	}
	!$has_accepted_prefix
}

## Byte/depth/node limits are inclusive, and the empty tree needs no node/depth
## capacity. A deployment cannot enlarge the protocol's hard ceilings.
expect {
	empty = PictureCodec.read(golden_empty, { max_bytes: 128, max_nodes: 0, max_depth: 0 })?
	exact = PictureCodec.read(golden_rich, { max_bytes: golden_rich.len(), max_nodes: 10, max_depth: 2 })?
	{
		empty: PictureCodec.parts(empty).physical_count,
		rich: PictureCodec.parts(exact).physical_count,
		bytes: PictureCodec.read(golden_rich, { max_bytes: golden_rich.len() - 1 }).is_err(),
		physical_nodes: PictureCodec.read(golden_rich, { max_nodes: 7 }).is_err(),
		logical_nodes: PictureCodec.read(golden_rich, { max_nodes: 9 }).is_err(),
		depth: PictureCodec.read(golden_rich, { max_depth: 1 }).is_err(),
		raised: PictureCodec.read(golden_rich, { max_bytes: 16777216 }).is_err(),
	} == { empty: 0, rich: 8, bytes: True, physical_nodes: True, logical_nodes: True, depth: True, raised: True }
}

## Binding offsets cannot name flags, an empty batch or the first byte beyond
## its declaration. Exact command-boundary matching remains Core's job.
expect {
	base = rich_fixture({})
	first = base.bindings.first()?
	bad = [
		{ ..base, batch_bytes: 0 },
		{ ..base, bindings: [{ ..first, birth_offset: 0 }] },
		{ ..base, bindings: [{ ..first, birth_offset: 32 }] },
		{ ..base, bindings: [{ ..first, address: 0 }] },
		{ ..base, bindings: [{ ..first, address: 0xffffffff }] },
		{ ..base, bindings: [{ ..first, slot: 1 }] },
		{ ..base, bindings: [{ ..first, kind: Text }] },
		{ ..base, bindings: [first, first] },
	]
	bad.all(|parts| PictureCodec.make(parts, {}).is_err())
}

## Malformed ownership cannot hide in a valid byte representation: placement,
## element containers, backreferences, constructed slots and claims are checked.
expect {
	base = rich_fixture({})
	mount = base.containers.first()?
	control = base.containers.get(3)?
	first_run = base.runs.first()?
	bad = [
		{ ..base, containers: [] },
		{ ..base, containers: base.containers.set(0, { ..mount, children: [0, 6, 4] })? },
		{ ..base, containers: base.containers.set(0, { ..mount, children: [0, 4, 4] })? },
		{ ..base, containers: base.containers.drop_last(1) },
		{ ..base, logical: base.logical.set(4, ExistingComment(2))? },
		{ ..base, logical: base.logical.set(7, ConstructedComment({ container: 3, logical_child_index: 2, data: "x" }))? },
		{ ..base, runs: base.runs.set(0, { ..first_run, child_index: 1 })? },
		{ ..base, runs: base.runs.set(0, { ..first_run, parts: [] })? },
		{ ..base, containers: base.containers.set(3, { ..control, children: [] })? },
	]
	bad.all(|parts| PictureCodec.make(parts, {}).is_err())
}

## URI/local alone identifies an attribute override; another prefix cannot
## introduce a second scaffold for the same attribute on the same owner.
expect {
	base = rich_fixture({})
	duplicate = AttributeOverride({ owner: 6, name: { namespace: "urn:a", prefix: "other", local: "x" }, original: Absent, physical: Absent })
	PictureCodec.make({ ..base, scaffolds: base.scaffolds.append(duplicate) }, {}).is_err()
}

## Reserved prefixes, local colons and custom URIs are transport facts, not a
## factory or XML QName decision at this data-only layer.
expect {
	base = empty_fixture({})
	names = [
		{ namespace: "http://www.w3.org/2000/svg", prefix: "", local: "h:div" },
		{ namespace: "urn:entry", prefix: "", local: "xmlns" },
		{ namespace: "http://www.w3.org/1999/xhtml", prefix: "h", local: "div" },
		{ namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "h:div" },
	]
	names.all(|name| PictureCodec.make({ ..base, root_name: name }, {}).is_ok())
}

## Independent byte offsets pin the distinct role/presence/birth fields, so
## an encoder and decoder sharing a wrong field order cannot pass by agreement.
expect {
	bad = [golden_rich.set(117, 2)?, golden_rich.set(203, 5)?, golden_rich.set(254, 255)?, golden_rich.set(370, 0)?, golden_rich.set(370, 32)?, golden_rich.set(374, 4)?, golden_rich.set(383, 7)?, golden_rich.set(482, 3)?, golden_rich.set(491, 2)?]
	bad.all(|bytes| PictureCodec.read(bytes, {}).is_err())
}

## A flags-only ordinary batch is valid without addresses. The first command
## byte becomes bindable only when the declared batch has at least two bytes.
expect {
	empty = empty_fixture({})
	flags = PictureCodec.make({ ..empty, batch_bytes: 1 }, {})?
	decoded = PictureCodec.read(PictureCodec.encode(flags), {})?
	PictureCodec.parts(decoded).batch_bytes == 1
}

## Known hole-kind bytes pin every closed mapping independently in both
## directions. Logical DOM compatibility is deliberately checked later.
expect {
	base = rich_fixture({})
	hole = base.bindings.get(2)?
	cases = [{ byte: 1.U8, kind: Text }, { byte: 2, kind: Attribute }, { byte: 3, kind: Event }, { byte: 4, kind: Bind }, { byte: 5, kind: Reference }, { byte: 6, kind: Property }]
	cases.all(
		|item| {
			expected = { ..base, bindings: base.bindings.set(2, { ..hole, kind: item.kind }) ?? crash "known hole binding" }
			wire = golden_rich.set(419, item.byte) ?? crash "known hole kind byte"
			decoded = PictureCodec.read(wire, {}) ?? crash "known hole kind refused"
			envelope = PictureCodec.make(expected, {}) ?? crash "known hole parts refused"
			PictureCodec.parts(decoded) == expected and PictureCodec.encode(envelope) == wire
		},
	)
}

## Alias Bind and Reference are distinct wire kinds; changing role-unused
## fields or colliding a principal/hole key must not create another binding.
expect {
	base = rich_fixture({})
	alias = base.bindings.get(3)?
	row = base.bindings.get(1)?
	hole = base.bindings.get(4)?
	known = { ..base, bindings: base.bindings.set(3, { ..alias, kind: Bind })? }
	envelope = PictureCodec.make(known, {})?
	rejected = [
		{ ..base, bindings: base.bindings.set(1, { ..row, kind: Event })? },
		{ ..base, bindings: base.bindings.set(3, { ..alias, kind: Unused })? },
		{ ..base, bindings: base.bindings.set(3, { ..alias, address: row.address })? },
		{ ..base, bindings: base.bindings.set(4, { ..hole, slot: 0 })? },
		{ ..base, bindings: base.bindings.set(4, { ..hole, kind: Unused })? },
	]
	PictureCodec.encode(envelope) == golden_rich.set(437, 4)? and rejected.all(|parts| PictureCodec.make(parts, {}).is_err())
}

## A later root subtree cannot return to an earlier owner's children, even
## when every owner precedes its child and all physical roles are covered.
expect {
	base = rich_fixture({})
	earlier = base.containers.get(2)?
	later = base.containers.get(4)?
	bad = {
		..base,
		containers: base.containers.set(2, { ..earlier, children: [3, 7] })?.set(4, { ..later, children: [] })?,
		logical: base.logical.append(ExistingElement(7)),
		scaffolds: base.scaffolds.drop_last(1),
	}
	PictureCodec.make(bad, {}).is_err()
}

## Role-unused operands are checked before a decoded binding is appended, and
## the same policy validates producer records without a second closed list.
check_binding_fields : { role : PictureCodec.BindingRole, slot : U32, kind : PictureCodec.BindingKind } -> Try({}, PictureCodec.Error)
check_binding_fields = |binding| match binding.role {
	Static if binding.slot != 0 or binding.kind != Unused => Err(InvalidParts("Static binding unused fields"))
	Row if binding.kind != Unused => Err(InvalidParts("Row binding unused kind"))
	Hole if binding.kind == Unused => Err(InvalidParts("Hole requires a kind"))
	Alias if binding.kind != Bind and binding.kind != Reference => Err(InvalidParts("Alias kind"))
	_ => Ok({})
}

## Materialized text/comment leaves count even when projection omitted their
## physical node. Their container owner is already a checked physical element.
check_leaf_depth : List(U32), { owner : PictureCodec.Owner, maximum : U32 } -> Try({}, PictureCodec.Error)
check_leaf_depth = |depths, props| {
	actual = match props.owner {
		Mount => 1
		Element(owner) => (depths.get(owner.to_u64()) ?? crash "PictureCodec.check_leaf_depth: checked physical owner") + 1
	}
	if actual > props.maximum {
		Err(DepthLimit({ maximum: props.maximum, actual }))
	} else {
		Ok({})
	}
}

## A physically empty root still needs depth1 for an omitted logical text run;
## constructed control originals require depth2 under their physical owner.
expect {
	base = empty_fixture({})
	run = { ..base, logical: [TextPart({ run: 0, part: 0 })], runs: [{ container: 0, child_index: 0, physical: Omitted, parts: [{ logical: 0, utf16_units: 0 }] }] }
	control = { ..base, physical_count: 1, containers: [{ owner: Mount, role: Children, children: [0] }, { owner: Element(0), role: Children, children: [] }], logical: [ExistingElement(0), ConstructedText({ container: 1, logical_child_index: 0, data: "" })], scaffolds: [ControlText({ owner: 0, container: 1, physical: Omitted })] }
	{
		empty_zero: PictureCodec.make(base, { max_depth: 0 }).is_ok(),
		run_zero: PictureCodec.make(run, { max_depth: 0 }).is_err(),
		run_one: PictureCodec.make(run, { max_depth: 1 }).is_ok(),
		control_zero: PictureCodec.make(control, { max_depth: 0 }).is_err(),
		control_one: PictureCodec.make(control, { max_depth: 1 }).is_err(),
		control_two: PictureCodec.make(control, { max_depth: 2 }).is_ok(),
	} == { empty_zero: True, run_zero: True, run_one: True, control_zero: True, control_one: True, control_two: True }
}
