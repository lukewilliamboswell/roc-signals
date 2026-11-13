import PictureCapture
import PictureCodec

## The engine's claim check uses its decided command boundaries and allocator
## facts. It neither reads an oracle tree nor retains application storage.
PicturePlan :: [].{

	## Actions preserve the ordinary command order. A kept picture already has
	## final placement, so moves and clears must not replay physical mutations.
	Action : [Apply, Skip, ClaimStatic(U32), ClaimRow({ binding : U32, holes : List(U32), aliases : List(U32) }), ClearSite(U32), KeepPlacement]
	Operation : { at : U32, end : U32, action : Action }
	Error : [PlanLimit, BadCapture(Str), ClaimsDiffer(Str)]
	Props : { batch : List(U8), frames : List(PictureCapture.Frame), next : U32, free : List(U32), envelope : PictureCodec.Envelope }
	Plan :: { batch_bytes : U32, operations : List(Operation) }

	## Every live birth and compiled hole must have exactly one matching claim.
	## Recycled numeric addresses are compared by their command birth offset;
	## a free address is never made live by a supplied envelope.
	build : Props -> Try(Plan, Error)
	build = |props| build_plan(props)

	## Hand the engine-decided operation list to the command encoder. These
	## references index the checked envelope, never application identities.
	operations : Plan -> List(Operation)
	operations = |plan| plan.operations
}

Key : { birth : U32, role : PictureCodec.BindingRole, address : U32, slot : U32, kind : PictureCodec.BindingKind }

RowKey : { birth : U32, address : U32 }

TargetKind : [Element, Text, Comment]

Expected : { target : TargetKind, owner : [Standalone, InRow(RowKey)] }

## Fixed-prefix reads are independent of variable-size effect payloads. Their
## capture boundary is checked before any word can be indexed.
word : List(U8), { at : U64, end : U64 } -> Try(U32, PicturePlan.Error)
word = |bytes, { at, end }| {
	if end > bytes.len() or at > end or end - at < 4 {
		return Err(BadCapture("truncated fixed command operand"))
	}
	var $value = 0.U32
	for index in 0.U64..<4 {
		byte = bytes.get(at + index) ?? crash "PicturePlan.word: checked word"
		$value = $value.bitwise_or(byte.to_u32().shl_wrap((index * 8).to_u8_wrap()))
	}
	Ok($value)
}

## An internal hole code becomes the codec's closed kind at this one boundary.
hole_kind : U8 -> Try(PictureCodec.BindingKind, PicturePlan.Error)
hole_kind = |kind| match kind {
	1 => Ok(Text)
	2 => Ok(Attribute)
	3 => Ok(Event)
	4 => Ok(Bind)
	5 => Ok(Reference)
	6 => Ok(Property)
	_ => Err(BadCapture("unknown compiled hole kind"))
}

## No text/comment can become an element through a claim role. Constructed
## originals and split text parts keep their decided logical node kind.
logical_kind : PictureCodec.Logical -> TargetKind
logical_kind = |logical| match logical {
	ExistingElement(_) => Element
	TextPart(_) | ConstructedText(_) => Text
	ExistingComment(_) | ConstructedComment(_) => Comment
}

## A principal birth, as opposed to a command using an earlier incarnation.
is_birth : U8 -> Bool
is_birth = |opcode| opcode == 0 or opcode == 1 or opcode == 8 or opcode == 10 or opcode == 26

## Only addressed DOM operations participate in incarnation matching. Service
## request ids belong to their own space and are never looked up as DOM ids.
has_target : U8 -> Bool
has_target = |opcode| match opcode {
	2 | 3 | 4 | 5 | 6 | 9 | 11 | 12 | 18 | 21 | 22 | 23 => True
	_ => False
}

## Capture is produced inside Core. Still check its complete byte coverage,
## metadata extents and fixed operands before accepting any supplied claim.
check_capture : PicturePlan.Props -> Try({}, PicturePlan.Error)
check_capture = |props| {
	if props.frames.len() > PictureCapture.max_records or props.batch.len() > 4294967295 {
		return Err(PlanLimit)
	}
	if props.next == 0 {
		return Err(BadCapture("invalid allocator frontier"))
	}
	if props.batch.is_empty() {
		return if (props.frames.is_empty()) Ok({}) else Err(BadCapture("empty batch has capture records"))
	}
	if props.batch.first() != Ok(0) {
		return Err(BadCapture("picture mount is not an unmarked batch"))
	}
	var $cursor = 1.U32
	var $row = { at: 0.U32, end: 0.U32, address: 0.U32 }
	var $hole = 0.U32
	var $last_hole = { slot: 0.U32, kind: 0.U8 }
	for frame in props.frames {
		if frame.at == 0 or frame.end <= frame.at or frame.end.to_u64() > props.batch.len() {
			return Err(BadCapture("capture boundary outside ordinary batch"))
		}
		if frame.opcode == 0 or frame.opcode == 255 {
			if frame.at != $row.at or frame.end != $row.end or $row.address == 0 {
				return Err(BadCapture("row metadata has no matching INST"))
			}
			if frame.opcode == 255 {
				if frame.address != $row.address or frame.slot != $hole {
					return Err(BadCapture("row holes are not complete in compiled order"))
				}
				_ = hole_kind(frame.kind)?
				$last_hole = { slot: frame.slot, kind: frame.kind }
				$hole = $hole + 1
			} else if frame.address == 0 or frame.address >= props.next or frame.slot != $last_hole.slot or frame.kind != $last_hole.kind or (frame.kind != 4 and frame.kind != 5) {
				return Err(BadCapture("alias differs from its compiled bind or reference hole"))
			}
		} else {
			if frame.opcode > 26 or frame.at != $cursor or frame.kind != 0 or props.batch.get(frame.at.to_u64()) != Ok(frame.opcode) {
				return Err(BadCapture("ordinary commands do not cover the batch exactly"))
			}
			$cursor = frame.end
			$row = if (frame.opcode == 1) { at: frame.at, end: frame.end, address: frame.address } else { at: 0, end: 0, address: 0 }
			$hole = 0
			$last_hole = { slot: 0, kind: 0 }
			address = match frame.opcode {
				1 | 2 | 3 | 4 | 5 | 6 | 8 | 9 | 10 | 11 | 12 | 21 | 22 | 23 | 26 => word(props.batch, { at: frame.at.to_u64() + 1, end: frame.end.to_u64() })?
				18 => word(props.batch, { at: frame.at.to_u64() + 2, end: frame.end.to_u64() })?
				_ => 0
			}
			if address != frame.address or (address != 0 and address >= props.next) {
				return Err(BadCapture("command target differs from its fixed operand"))
			}
			if is_birth(frame.opcode) and address == 0 {
				return Err(BadCapture("a birth cannot use the mount address"))
			}
			slot = match frame.opcode {
				1 => word(props.batch, { at: frame.at.to_u64() + 13, end: frame.end.to_u64() })?
				6 => word(props.batch, { at: frame.at.to_u64() + 5, end: frame.end.to_u64() })?
				7 => word(props.batch, { at: frame.at.to_u64() + 1, end: frame.end.to_u64() })?
				_ => 0
			}
			if frame.slot != slot {
				return Err(BadCapture("command site differs from its fixed operand"))
			}
		}
	}
	if $cursor.to_u64() != props.batch.len() {
		return Err(BadCapture("capture does not end with the ordinary batch"))
	}
	Ok({})
}

## Keys include the birth as well as the numeric address. Hole and principal
## roles remain separate even when both target the same logical element.
frame_key : PictureCapture.Frame -> Try(Key, PicturePlan.Error)
frame_key = |frame| {
	role = match frame.opcode {
		0 => Alias
		1 => Row
		255 => Hole
		8 | 10 | 26 => Static
		_ => return Err(BadCapture("non-birth has no binding key"))
	}
	kind = if (frame.opcode == 0 or frame.opcode == 255) hole_kind(frame.kind)? else Unused
	Ok({ birth: frame.at, role, address: frame.address, slot: if (role == Static) 0 else frame.slot, kind })
}

## Scan only bounded capture/claim records. The allocator's existing free list
## deletes captured candidates directly, without allocating a second free set.
build_plan : PicturePlan.Props -> Try(PicturePlan.Plan, PicturePlan.Error)
build_plan = |props| {
	check_capture(props)?
	parts = PictureCodec.parts(props.envelope)
	if parts.batch_bytes.to_u64() != props.batch.len() {
		return Err(ClaimsDiffer("ordinary batch length"))
	}
	if parts.bindings.len() > props.frames.len() {
		return Err(ClaimsDiffer("more claims than captured births and holes"))
	}
	var $final = Dict.empty()
	for frame in props.frames {
		if is_birth(frame.opcode) {
			$final = $final.insert(frame.address, frame)
		}
	}
	for address in props.free {
		if address == 0 or address >= props.next {
			return Err(BadCapture("free address outside allocator frontier"))
		}
		$final = $final.remove(address)
	}
	var $expected = Dict.empty()
	var $owner = { birth: 0.U32, address: 0.U32 }
	for frame in props.frames {
		if frame.opcode == 1 {
			$owner = { birth: frame.at, address: frame.address }
		}
		live = if frame.opcode == 255 {
			match $final.get(frame.address) {
				Ok(birth) => birth.at == frame.at and birth.opcode == 1
				Err(_) => False
			}
		} else is_birth(frame.opcode) and $final.get(frame.address) == Ok(frame)
		if live {
			key = frame_key(frame)?
			if $expected.contains(key) {
				return Err(BadCapture("duplicate expected binding"))
			}
			owner = if (frame.opcode == 0 or frame.opcode == 255) InRow($owner) else Standalone
			if frame.opcode == 0 {
				match $final.get($owner.address) {
					Ok(row) if row.opcode == 1 and row.at == $owner.birth => {}
					_ => return Err(BadCapture("live alias belongs to a dead row"))
				}
			}
			target = match frame.opcode {
				10 => Text
				26 => Comment
				0 | 255 if frame.kind == 1 or frame.kind == 4 => Text
				_ => Element
			}
			fact : Expected
			fact = { target, owner }
			$expected = $expected.insert(key, fact)
		}
	}
	var $accepted = Dict.empty()
	var $binding_index = 0.U32
	for binding in parts.bindings {
		key = { birth: binding.birth_offset, role: binding.role, address: binding.address, slot: binding.slot, kind: binding.kind }
		expected = $expected.get(key) ? |_| ClaimsDiffer("claim has no final birth or compiled hole")
		logical = parts.logical.get(binding.logical.to_u64()) ?? crash "PicturePlan: codec checked logical reference"
		if logical_kind(logical) != expected.target {
			return Err(ClaimsDiffer("claim changes the logical node kind"))
		}
		$expected = $expected.remove(key)
		$accepted = $accepted.insert(key, $binding_index)
		$binding_index = $binding_index + 1
	}
	if !$expected.is_empty() {
		return Err(ClaimsDiffer("a final birth or compiled hole has no claim"))
	}
	var $holes = Dict.empty()
	var $aliases = Dict.empty()
	for frame in props.frames {
		if frame.opcode == 1 {
			$owner = { birth: frame.at, address: frame.address }
		} else if frame.opcode == 0 or frame.opcode == 255 {
			key = frame_key(frame)?
			match $accepted.get(key) {
				Ok(binding) => if frame.opcode == 0 {
					$aliases = $aliases.insert($owner, ($aliases.get($owner) ?? []).append(binding))
				} else {
					$holes = $holes.insert($owner, ($holes.get($owner) ?? []).append(binding))
				}
				Err(_) => {}
			}
		}
	}
	var $current = Dict.empty()
	var $live_rows = Dict.empty()
	var $operations = []
	for frame in props.frames {
		if is_birth(frame.opcode) {
			$current = $current.insert(frame.address, frame.at)
		}
		if frame.opcode != 0 and frame.opcode != 255 {
			live = match $current.get(frame.address) {
				Ok(at) => match $final.get(frame.address) {
					Ok(birth) => birth.at == at
					Err(_) => False
				}
				Err(_) => False
			}
			action = if frame.opcode == 1 or frame.opcode == 8 or frame.opcode == 10 or frame.opcode == 26 {
				if live {
					binding = $accepted.get(frame_key(frame)?) ?? crash "PicturePlan: checked principal binding"
					if frame.opcode == 1 {
						$live_rows = $live_rows.insert(frame.slot, ($live_rows.get(frame.slot) ?? 0.U64) + 1)
						owner = { birth: frame.at, address: frame.address }
						ClaimRow({ binding, holes: $holes.get(owner) ?? [], aliases: $aliases.get(owner) ?? [] })
					} else ClaimStatic(binding)
				} else Skip
			} else if frame.opcode == 6 {
				if ($live_rows.get(frame.slot) ?? 0) != 0 {
					return Err(BadCapture("CLEAR follows a surviving row of its site"))
				}
				ClearSite(frame.slot)
			} else if frame.opcode == 5 {
				if live {
					return Err(BadCapture("REMOVE retains its final address incarnation"))
				}
				Skip
			} else if frame.opcode == 4 {
				if (live) KeepPlacement else Skip
			} else if has_target(frame.opcode) {
				if (live) Apply else Skip
			} else {
				if frame.opcode == 7 and ($live_rows.get(frame.slot) ?? 0) != 0 {
					return Err(BadCapture("TEMPLATE replaces a surviving row's site"))
				}
				Apply
			}
			$operations = $operations.append({ at: frame.at, end: frame.end, action })
		}
	}
	Ok(PicturePlan.Plan.{ batch_bytes: parts.batch_bytes, operations: $operations })
}

## A tiny independent wire fixture: two text incarnations reuse address1;
## the live release must remain, while the earlier release and removal skip.
expect {
	text = [10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	release = [23, 1, 0, 0, 0]
	batch = [0].concat(text).concat(release).concat([5, 1, 0, 0, 0]).concat(text).concat([12, 1, 0, 0, 0, 0, 0, 0, 0]).concat(release)
	frames = [
		{ at: 1, end: 18, opcode: 10, address: 1, slot: 0, kind: 0 },
		{ at: 18, end: 23, opcode: 23, address: 1, slot: 0, kind: 0 },
		{ at: 23, end: 28, opcode: 5, address: 1, slot: 0, kind: 0 },
		{ at: 28, end: 45, opcode: 10, address: 1, slot: 0, kind: 0 },
		{ at: 45, end: 54, opcode: 12, address: 1, slot: 0, kind: 0 },
		{ at: 54, end: 59, opcode: 23, address: 1, slot: 0, kind: 0 },
	]
	envelope = text_envelope({ batch_bytes: 59, births: [{ address: 1, at: 28 }] })?
	plan = PicturePlan.build({ batch, frames, next: 2, free: [], envelope })?
	PicturePlan.operations(plan).map(|operation| operation.action) == [Skip, Skip, Skip, ClaimStatic(0), Apply, Apply]
}

## A free final address has no claim and cannot make an earlier incarnation
## live again. CLEAR is an explicit metadata action, never physical clearing.
expect {
	batch = [0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 7, 0, 0, 0]
	frames = [
		{ at: 1, end: 18, opcode: 10, address: 1, slot: 0, kind: 0 },
		{ at: 18, end: 27, opcode: 6, address: 0, slot: 7, kind: 0 },
	]
	empty = text_envelope({ batch_bytes: 27, births: [] })?
	plan = PicturePlan.build({ batch, frames, next: 2, free: [1], envelope: empty })?
	PicturePlan.operations(plan).map(|operation| operation.action) == [Skip, ClearSite(7)] and PicturePlan.build({ batch, frames, next: 2, free: [1], envelope: text_envelope({ batch_bytes: 27, births: [{ address: 1, at: 1 }] })? }).is_err()
}

## Surviving movement keeps the measured final placement; a stale before
## address is never looked up. Ordinary text changes remain ordered applies.
expect {
	batch = [0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 99, 0, 0, 0]
	frames = [
		{ at: 1, end: 18, opcode: 10, address: 1, slot: 0, kind: 0 },
		{ at: 18, end: 27, opcode: 4, address: 1, slot: 0, kind: 0 },
	]
	plan = PicturePlan.build({ batch, frames, next: 2, free: [], envelope: text_envelope({ batch_bytes: 27, births: [{ address: 1, at: 1 }] })? })?
	PicturePlan.operations(plan).map(|operation| operation.action) == [ClaimStatic(0), KeepPlacement]
}

## A checked envelope still cannot omit a birth, change a node kind, invent a
## birth offset, or refer to a batch with different length.
expect {
	batch = [0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	frames = [{ at: 1, end: 18, opcode: 10, address: 1, slot: 0, kind: 0 }]
	base = PictureCodec.parts(text_envelope({ batch_bytes: 18, births: [{ address: 1, at: 1 }] })?)
	first = base.bindings.first()?
	variants = [
		{ ..base, bindings: [] },
		{ ..base, bindings: [{ ..first, birth_offset: 2 }] },
		{ ..base, batch_bytes: 19 },
		{ ..base, physical_count: 1, containers: [{ owner: Mount, role: Children, children: [0] }, { owner: Element(0), role: Children, children: [] }], logical: [ExistingElement(0)], runs: [] },
	]
	variants.all(
		|parts| {
			envelope = PictureCodec.make(parts, {}) ?? crash "PicturePlan negative fixture must pass framing"
			PicturePlan.build({ batch, frames, next: 2, free: [], envelope }).is_err()
		},
	)
}

## Capture words must fit their own command extent; missing boundaries,
## unknown metadata and a target different from the real bytes are refused.
expect {
	batch = [0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	frame = { at: 1, end: 18, opcode: 10, address: 1, slot: 0, kind: 0 }
	envelope = text_envelope({ batch_bytes: 18, births: [{ address: 1, at: 1 }] })?
	cases = [[], [{ ..frame, end: 3 }], [{ ..frame, address: 2 }], [{ ..frame, opcode: 255 }], [{ ..frame, at: 2 }]]
	cases.all(|frames| PicturePlan.build({ batch, frames, next: 3, free: [], envelope }).is_err())
}

## Empty init may contain no flag byte or just the unused flag. Neither has
## a creation claim, and an unused allocated route is not a DOM birth.
expect {
	[[], [0]].all(
		|batch| {
			envelope = text_envelope({ batch_bytes: batch.len().to_u32_wrap(), births: [] }) ?? crash "valid empty plan fixture"
			plan = PicturePlan.build({ batch, frames: [], next: 8, free: [1, 2], envelope }) ?? crash "empty capture has no birth"
			PicturePlan.operations(plan).is_empty()
		},
	)
}

## Test-owned canonical topology for adjacent logical text leaves. A single
## physical run represents them without pretending HTML retains empty nodes.
text_envelope : { batch_bytes : U32, births : List({ address : U32, at : U32 }) } -> Try(PictureCodec.Envelope, PictureCodec.Error)
text_envelope = |props| {
	var $logical = []
	var $parts = []
	var $bindings = []
	var $index = 0.U32
	for birth in props.births {
		$logical = $logical.append(TextPart({ run: 0, part: $index }))
		$parts = $parts.append({ logical: $index, utf16_units: 0 })
		$bindings = $bindings.append({ birth_offset: birth.at, role: Static, address: birth.address, slot: 0, kind: Unused, logical: $index })
		$index = $index + 1
	}
	PictureCodec.make({ root_name: { namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "main" }, batch_bytes: props.batch_bytes, fingerprint: List.repeat(0, 32), expected: List.repeat(0, 32), physical_count: 0, containers: [{ owner: Mount, role: Children, children: [] }], logical: $logical, runs: if ($parts.is_empty()) [] else [{ container: 0, child_index: 0, physical: Omitted, parts: $parts }], bindings: $bindings, scaffolds: [] }, {})
}

## A live row needs every compiled hole and both secondary aliases. The row
## action carries explicit binding indices in compiled order, even when two
## addresses name one logical element.
expect {
	fixture = row_fixture({})?
	plan = PicturePlan.build({ batch: fixture.batch, frames: fixture.frames, next: 4, free: [], envelope: fixture.envelope })?
	PicturePlan.operations(plan).map(|operation| operation.action) == [ClaimRow({ binding: 0, holes: [1, 2, 3, 4, 5, 6], aliases: [7, 8] })]
}

## Framing-valid hole mutations cannot change a compiled kind or discard an
## alias. Invalid internal metadata cannot become a new ordinary command.
expect {
	fixture = row_fixture({})?
	parts = PictureCodec.parts(fixture.envelope)
	hole = parts.bindings.get(2)?
	variants = [
		{ ..parts, bindings: parts.bindings.set(2, { ..hole, kind: Event })? },
		{ ..parts, bindings: parts.bindings.drop_last(1) },
	]
	variants.all(
		|value| {
			envelope = PictureCodec.make(value, {}) ?? crash "framing-valid row mutation"
			PicturePlan.build({ batch: fixture.batch, frames: fixture.frames, next: 4, free: [], envelope }).is_err()
		},
	) and PicturePlan.build({ batch: fixture.batch, frames: fixture.frames.set(1, { at: 1, end: 40, opcode: 255, address: 1, slot: 1, kind: 1 })?, next: 4, free: [], envelope: fixture.envelope }).is_err()
}

## Independently authored row wire and roles pin all six holes without using
## the production kind conversion or a renderer to manufacture expectations.
row_fixture : {} -> Try({ batch : List(U8), frames : List(PictureCapture.Frame), envelope : PictureCodec.Envelope }, PictureCodec.Error)
row_fixture = |_unused| {
	batch = [0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 5, 0, 0, 0, 102, 97, 108, 115, 101]
	var $frames = [{ at: 1, end: 40, opcode: 1, address: 1, slot: 7, kind: 0 }]
	var $bindings = [{ birth_offset: 1, role: Row, address: 1, slot: 7, kind: Unused, logical: 0 }]
	var $index = 0.U32
	for specification in [{ kind: Text, logical: 1.U32 }, { kind: Attribute, logical: 0 }, { kind: Event, logical: 2 }, { kind: Bind, logical: 1 }, { kind: Reference, logical: 2 }, { kind: Property, logical: 2 }] {
		kind = ($index + 1).to_u8_wrap()
		$frames = $frames.append({ at: 1, end: 40, opcode: 255, address: 1, slot: $index, kind })
		if kind == 4 or kind == 5 {
			$frames = $frames.append({ at: 1, end: 40, opcode: 0, address: if (kind == 4) 2 else 3, slot: $index, kind })
		}
		$bindings = $bindings.append({ birth_offset: 1, role: Hole, address: 1, slot: $index, kind: specification.kind, logical: specification.logical })
		$index = $index + 1
	}
	$bindings = $bindings.concat([{ birth_offset: 1, role: Alias, address: 2, slot: 3, kind: Bind, logical: 1 }, { birth_offset: 1, role: Alias, address: 3, slot: 4, kind: Reference, logical: 2 }])
	envelope = PictureCodec.make({ root_name: { namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "main" }, batch_bytes: 40, fingerprint: List.repeat(0, 32), expected: List.repeat(0, 32), physical_count: 3, containers: [{ owner: Mount, role: Children, children: [0] }, { owner: Element(0), role: Children, children: [1, 2] }, { owner: Element(2), role: Children, children: [] }], logical: [ExistingElement(0), TextPart({ run: 0, part: 0 }), ExistingElement(2)], runs: [{ container: 1, child_index: 0, physical: Physical(1), parts: [{ logical: 1, utf16_units: 0 }] }], bindings: $bindings, scaffolds: [] }, {})?
	Ok({ batch, frames: $frames, envelope })
}

## A surviving row can release its registrations without losing identity.
## Clearing or redefining its site would contradict the final allocator facts.
expect {
	fixture = row_fixture({})?
	parts = PictureCodec.parts(fixture.envelope)
	release = { batch: fixture.batch.concat([23, 1, 0, 0, 0]), frame: { at: 40, end: 45, opcode: 23, address: 1, slot: 0, kind: 0 } }
	plan = PicturePlan.build({ batch: release.batch, frames: fixture.frames.append(release.frame), next: 4, free: [], envelope: PictureCodec.make({ ..parts, batch_bytes: 45 }, {})? })?
	invalid = [
		{ batch: fixture.batch.concat([6, 0, 0, 0, 0, 7, 0, 0, 0]), frame: { at: 40, end: 49, opcode: 6, address: 0, slot: 7, kind: 0 } },
		{ batch: fixture.batch.concat([7, 7, 0, 0, 0, 0, 0, 0, 0]), frame: { at: 40, end: 49, opcode: 7, address: 0, slot: 7, kind: 0 } },
	]
	PicturePlan.operations(plan).last()?.action == Apply and invalid.all(
		|changed| {
			envelope = PictureCodec.make({ ..parts, batch_bytes: 49 }, {}) ?? crash "checked site contradiction fixture"
			PicturePlan.build({ batch: changed.batch, frames: fixture.frames.append(changed.frame), next: 4, free: [], envelope }).is_err()
		},
	)
}
