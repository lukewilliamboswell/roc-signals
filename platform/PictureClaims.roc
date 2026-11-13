import Dom
import PictureCapture
import PictureCodec

## Native picture production joins independent oracle lifetimes to passive
## command births. No application storage or engine implementation enters here.
PictureClaims :: [].{

	## Canonical inputs have their own ceiling, independent of page/envelope caps.
	Limits := { codec : PictureCodec.Limits ?? {}, max_measurement_bytes : U64 ?? 67108864 }
	Error : [InvalidClaims(Str), MeasurementLimit({ maximum : U64, required : U64 }), InvalidMeasurementLimit, Codec(PictureCodec.Error)]
	Props : { dom : Dom.Model, rendered : Dom.Rendered, frames : List(PictureCapture.Frame), batch : List(U8), fingerprint : List(U8), expected : List(U8), limits : Limits }

	## Only final attached lifetimes receive bindings. A removed incarnation's
	## numeric address cannot identify the later incarnation which reused it.
	assemble : Props -> Try(PictureCodec.Envelope, Error)
	assemble = |props| assemble_claims(props)

	## Mount hashing includes exactly the ordinary batch, including its flags
	## byte when present. The caller supplies these bytes to Io.sha256! once.
	fingerprint_bytes : List(U8), Limits -> Try(List(U8), Error)
	fingerprint_bytes = |batch, limits| {
		check_measurement_limit(limits.max_measurement_bytes)?
		if batch.len() > 4294967295 {
			return Err(InvalidClaims("ordinary batch exceeds u32"))
		}
		domain = "roc-signals/mount/19/1".to_utf8()
		required = domain.len() + 1 + 4 + batch.len()
		check_measurement_size({ required, maximum: limits.max_measurement_bytes })?
		Ok(write_u32(List.with_capacity(required).concat(domain).append(0), batch.len().to_u32_wrap()).concat(batch))
	}

	## Hash framing is independently written from checked names and physical
	## facts. Only the two stored digest fields are omitted from the envelope;
	## offsets follow lengths, never a search for matching byte content.
	MeasurementProps := { rendered : Dom.Rendered, max_bytes : U64 ?? 67108864 }
	measurement_bytes : PictureCodec.Envelope, MeasurementProps -> Try(List(U8), Error)
	measurement_bytes = |envelope, props| measure_picture(envelope, props)
}

## Every narrowing is checked before a producer table grows.
narrow : U64 -> Try(U32, PictureClaims.Error)
narrow = |value| if value > 4294967295 {
	Err(InvalidClaims("picture index exceeds u32"))
} else {
	Ok(value.to_u32_wrap())
}

## The native producer accepts deployment limits only below the protocol cap.
check_measurement_limit : U64 -> Try({}, PictureClaims.Error)
check_measurement_limit = |maximum| if maximum > 67108864 {
	Err(InvalidMeasurementLimit)
} else {
	Ok({})
}

## Report the complete required size before allocating a canonical buffer.
check_measurement_size : { required : U64, maximum : U64 } -> Try({}, PictureClaims.Error)
check_measurement_size = |props| if props.required > props.maximum {
	Err(MeasurementLimit({ maximum: props.maximum, required: props.required }))
} else {
	Ok({})
}

## Renderer indices are separately bounded before converting its records.
check_render_bounds : Dom.Rendered, PictureClaims.Limits -> Try({}, PictureClaims.Error)
check_render_bounds = |rendered, limits| {
	if limits.codec.max_nodes > 262144 or limits.codec.max_bytes > 16777179 or limits.codec.max_depth > 1024 {
		return Err(InvalidClaims("invalid codec deployment limits"))
	}
	maximum = limits.codec.max_nodes.to_u64()
	if rendered.physical.len() > maximum or rendered.logical.len() > maximum or rendered.containers.len() > maximum * 2 + 1 or rendered.text_runs.len() > maximum or rendered.scaffolds.len() > maximum * 3 {
		return Err(InvalidClaims("rendered table exceeds picture bounds"))
	}
	var $children = 0.U64
	for container in rendered.containers {
		$children = $children + container.children.len()
	}
	var $parts = 0.U64
	for run in rendered.text_runs {
		$parts = $parts + run.parts.len()
	}
	if $children > maximum or $parts > maximum {
		return Err(InvalidClaims("rendered child or text-part count exceeds node bound"))
	}
	Ok({})
}

## Build bounded transient joins over accepted records, never scan the oracle's
## append-only detached lifetimes or its potentially sparse address array.
assemble_claims : PictureClaims.Props -> Try(PictureCodec.Envelope, PictureClaims.Error)
assemble_claims = |props| {
	check_measurement_limit(props.limits.max_measurement_bytes)?
	check_render_bounds(props.rendered, props.limits)?
	if props.frames.len() > PictureCapture.max_records {
		return Err(InvalidClaims("capture record limit"))
	}
	batch_bytes = narrow(props.batch.len())?
	root_name = match props.rendered.root_name {
		ElementRoot(name) => name
		NonElementRoot => return Err(InvalidClaims("picture requires an external element root"))
	}
	if Dom.node(props.dom, props.dom.root).namespace != root_name.namespace or Dom.node(props.dom, props.dom.root).prefix != root_name.prefix or Dom.node(props.dom, props.dom.root).tag != root_name.local {
		return Err(InvalidClaims("rendered external root differs from oracle root"))
	}
	var $models = Dict.empty()
	var $logical = []
	var $logical_index = 0.U32
	for entry in props.rendered.logical {
		if $models.contains(entry.model) {
			return Err(InvalidClaims("duplicate logical model lifetime"))
		}
		if entry.model >= props.dom.nodes.len() {
			return Err(InvalidClaims("logical lifetime outside oracle"))
		}
		$models = $models.insert(entry.model, $logical_index)
		target = match entry.target {
			Node(index) => match props.rendered.physical.get(index) {
				Ok(Element(_)) => ExistingElement(narrow(index)?)
				Ok(Comment(_)) => ExistingComment(narrow(index)?)
				_ => return Err(InvalidClaims("logical node must name an element or comment"))
			}
			TextPart(part) => TextPart({ run: narrow(part.run)?, part: narrow(part.part)? })
			Constructed(value) => {
				container = narrow(value.container)?
				logical_child_index = narrow(value.logical_child_index)?
				match value.data {
					Text(data) => ConstructedText({ container, logical_child_index, data })
					Comment(data) => ConstructedComment({ container, logical_child_index, data })
				}
			}
		}
		$logical = $logical.append(target)
		$logical_index = $logical_index + 1
	}
	var $containers = []
	for container in props.rendered.containers {
		owner = match container.owner {
			Mount => Mount
			Element(index) => Element(narrow(index)?)
		}
		var $children = []
		for child in container.children {
			$children = $children.append(narrow(child)?)
		}
		$containers = $containers.append({ owner, role: container.role, children: $children })
	}
	var $runs = []
	for run in props.rendered.text_runs {
		var $parts = []
		for part in run.parts {
			$parts = $parts.append({ logical: narrow(part.logical)?, utf16_units: narrow(part.utf16_units)? })
		}
		$runs = $runs.append({ container: narrow(run.container)?, child_index: narrow(run.child_index)?, physical: physical_ref(run.physical)?, parts: $parts })
	}
	var $scaffolds = []
	for scaffold in props.rendered.scaffolds {
		converted = match scaffold {
			ControlText(value) => ControlText({ owner: narrow(value.owner)?, container: narrow(value.container)?, physical: physical_ref(value.physical_text)? })
			AttributeOverride(value) => AttributeOverride({ owner: narrow(value.owner)?, name: value.name, logical_index: narrow(value.logical_index)?, original: value.logical, physical: value.physical })
			NoSelectionOption(value) => NoSelectionOption({ owner: narrow(value.owner)?, physical_option: narrow(value.physical_option)? })
		}
		$scaffolds = $scaffolds.append(converted)
	}
	captured = final_births(props.frames, props.batch)?
	latest = captured.latest
	var $bindings = []
	var $template_owners = Dict.empty()
	var $row_birth = { at: 0.U32, end: 0.U32, opcode: 0.U8, address: 0.U32, slot: 0.U32, kind: 0.U8 }
	for frame in props.frames {
		if frame.opcode == 1 {
			$row_birth = frame
		}
		if is_birth(frame) and latest.get(frame.address) == Ok(frame) {
			packed = props.dom.statics.get(frame.address.to_u64()) ?? 0
			lifetime1 = packed.bitwise_and(1099511627775)
			if lifetime1 != 0 {
				model = lifetime1 - 1
				match $models.get(model) {
					Err(_) => {}
					Ok(logical) => {
						if frame.opcode == 0 {
							parent_packed = props.dom.statics.get($row_birth.address.to_u64()) ?? 0
							parent_lifetime1 = parent_packed.bitwise_and(1099511627775)
							if parent_lifetime1 == 0 or latest.get($row_birth.address) != Ok($row_birth) {
								return Err(InvalidClaims("live alias has no final owning row birth"))
							}
							parent_row = props.dom.nodes.get(parent_lifetime1 - 1) ? |_| InvalidClaims("alias row lifetime missing")
							parent_template = props.dom.tpls.get($row_birth.slot.to_u64()) ? |_| InvalidClaims("alias template missing")
							hole = parent_template.holes.get(frame.slot.to_u64()) ? |_| InvalidClaims("alias hole missing")
							if hole.kind != frame.kind or parent_row.ht.get(frame.slot.to_u64()) != Ok(model) or $template_owners.get(model) != Ok({ birth: $row_birth.at, row: $row_birth.address }) {
								return Err(InvalidClaims("alias differs from final resolved row hole"))
							}
						}
						role = if frame.opcode == 0 {
							Alias
						} else if frame.opcode == 1 {
							Row
						} else {
							Static
						}
						kind = if frame.opcode == 0 {
							binding_kind(frame.kind)?
						} else {
							Unused
						}
						$bindings = append_binding($bindings, { maximum: props.limits.codec.max_bytes // 18, binding: { birth_offset: frame.at, role, address: frame.address, slot: if (role == Static) 0 else frame.slot, kind, logical } })?
						if frame.opcode == 1 {
							site1 = packed.shr_zf_wrap(40)
							if site1 == 0 or site1 - 1 != frame.slot.to_u64() {
								return Err(InvalidClaims("final row site differs from its birth"))
							}
							row = props.dom.nodes.get(model) ? |_| InvalidClaims("missing row lifetime")
							template = props.dom.tpls.get(site1 - 1) ? |_| InvalidClaims("missing final row template")
							if captured.hole_counts.get({ birth: frame.at, row: frame.address }) != Ok(template.holes.len()) or row.ht.len() != template.holes.len() {
								return Err(InvalidClaims("row hole cache differs from template"))
							}
							cloned = match row.template_nodes {
								Cloned(nodes) => nodes
								NotARow | TooMany => return Err(InvalidClaims("final row has no bounded clone-node cache"))
							}
							if captured.node_counts.get({ birth: frame.at, row: frame.address }) != Ok(cloned.len()) {
								return Err(InvalidClaims("captured template-node count differs from clone"))
							}
							var $node_index = 0.U32
							for node_model in cloned {
								node = props.dom.nodes.get(node_model) ? |_| InvalidClaims("cached template lifetime missing")
								if captured.nodes.get({ birth: frame.at, row: frame.address, slot: $node_index }) != Ok(node.kind) {
									return Err(InvalidClaims("captured template-node index or kind differs"))
								}
								if $template_owners.contains(node_model) {
									return Err(InvalidClaims("template lifetime has two row owners"))
								}
								$template_owners = $template_owners.insert(node_model, { birth: frame.at, row: frame.address })
								target = $models.get(node_model) ? |_| InvalidClaims("original template node has no final logical target")
								$bindings = append_binding($bindings, { maximum: props.limits.codec.max_bytes // 18, binding: { birth_offset: frame.at, role: TemplateNode, address: frame.address, slot: $node_index, kind: Unused, logical: target } })?
								$node_index = $node_index + 1
							}
							var $hole = 0.U32
							for hole in template.holes {
								if captured.holes.get({ birth: frame.at, row: frame.address, slot: $hole }) != Ok(hole.kind) {
									return Err(InvalidClaims("captured row hole index or kind differs from oracle template"))
								}
								target_model = row.ht.get($hole.to_u64()) ?? crash "PictureClaims.assemble: checked hole cache"
								target = $models.get(target_model) ? |_| InvalidClaims("live row hole has no final logical target")
								if $template_owners.get(target_model) != Ok({ birth: frame.at, row: frame.address }) {
									return Err(InvalidClaims("row hole is not owned by its template"))
								}
								$bindings = append_binding($bindings, { maximum: props.limits.codec.max_bytes // 18, binding: { birth_offset: frame.at, role: Hole, address: frame.address, slot: $hole, kind: binding_kind(hole.kind)?, logical: target } })?
								$hole = $hole + 1
							}
						}
					}
				}
			}
		}
	}
	var $owners = Dict.empty()
	for binding in $bindings {
		if binding.role == Static or binding.role == TemplateNode {
			if $owners.contains(binding.logical) {
				return Err(InvalidClaims("logical node has two construction owners"))
			}
			$owners = $owners.insert(binding.logical, {})
		}
	}
	if $owners.len() != $logical.len() {
		return Err(InvalidClaims("logical node has no construction owner"))
	}
	Ok(PictureCodec.make({ root_name, batch_bytes, fingerprint: props.fingerprint, expected: props.expected, physical_count: narrow(props.rendered.physical.len())?, containers: $containers, logical: $logical, runs: $runs, bindings: $bindings, scaffolds: $scaffolds }, props.limits.codec) ? Codec)
}

## Binding tables are bounded separately: a row can have several holes per
## physical node. Its envelope-byte budget bounds storage before each append.
append_binding : List(PictureCodec.Binding), { binding : PictureCodec.Binding, maximum : U64 } -> Try(List(PictureCodec.Binding), PictureClaims.Error)
append_binding = |bindings, props| if bindings.len() >= props.maximum {
	Err(InvalidClaims("picture binding limit"))
} else {
	Ok(bindings.append(props.binding))
}

## Optional physical nodes stay distinct from omitted zero-width text runs.
physical_ref : [Omitted, Node(U64)] -> Try(PictureCodec.Physical, PictureClaims.Error)
physical_ref = |value| match value {
	Omitted => Ok(Omitted)
	Node(index) => Ok(Physical(narrow(index)?))
}

## Template kinds are independently read from the oracle's decoded plan.
binding_kind : U8 -> Try(PictureCodec.BindingKind, PictureClaims.Error)
binding_kind = |kind| match kind {
	1 => Ok(Text)
	2 => Ok(Attribute)
	3 => Ok(Event)
	4 => Ok(Bind)
	5 => Ok(Reference)
	6 => Ok(Property)
	_ => Err(InvalidClaims("unknown template binding kind"))
}

## Effects and mutations have no birth, even when their first operand is an ID.
is_birth : PictureCapture.Frame -> Bool
is_birth = |frame| frame.opcode == 0 or frame.opcode == 1 or frame.opcode == 8 or frame.opcode == 10 or frame.opcode == 26

## Capture must describe every ordinary command boundary in order. Secondary
## aliases follow the one INST with that exact extent, and carry no bytes.
HoleKey : { birth : U32, row : U32, slot : U32 }

RowBirth : { birth : U32, row : U32 }

Captured : { latest : Dict(U32, PictureCapture.Frame), holes : Dict(HoleKey, U8), hole_counts : Dict(RowBirth, U64), nodes : Dict(HoleKey, U8), node_counts : Dict(RowBirth, U64) }

final_births : List(PictureCapture.Frame), List(U8) -> Try(Captured, PictureClaims.Error)
final_births = |frames, batch| {
	var $next = if (batch.is_empty()) 0.U32 else 1.U32
	var $row = { at: 0.U32, end: 0.U32, opcode: 0.U8, address: 0.U32, slot: 0.U32, kind: 0.U8 }
	var $latest = Dict.empty()
	var $holes = Dict.empty()
	var $hole_counts = Dict.empty()
	var $nodes = Dict.empty()
	var $node_counts = Dict.empty()
	var $aliases = []
	for frame in frames {
		if frame.opcode == 0 or frame.opcode == 254 or frame.opcode == 255 {
			if $row.opcode != 1 or frame.at != $row.at or frame.end != $row.end {
				return Err(InvalidClaims("row metadata outside its INST boundary"))
			}
			if frame.opcode == 254 {
				row_key = { birth: frame.at, row: frame.address }
				index = $node_counts.get(row_key) ?? 0
				if frame.address != $row.address or frame.kind < 1 or frame.kind > 3 or frame.slot.to_u64() != index {
					return Err(InvalidClaims("compiled template nodes are not complete preorder facts"))
				}
				$nodes = $nodes.insert({ birth: frame.at, row: frame.address, slot: frame.slot }, frame.kind)
				$node_counts = $node_counts.insert(row_key, index + 1)
			} else if frame.opcode == 255 {
				if frame.address != $row.address or frame.kind < 1 or frame.kind > 6 {
					return Err(InvalidClaims("invalid captured row hole"))
				}
				key = { birth: frame.at, row: frame.address, slot: frame.slot }
				if $holes.contains(key) {
					return Err(InvalidClaims("duplicate captured row hole"))
				}
				$holes = $holes.insert(key, frame.kind)
				row_key = { birth: frame.at, row: frame.address }
				$hole_counts = $hole_counts.insert(row_key, ($hole_counts.get(row_key) ?? 0) + 1)
			} else {
				if frame.kind != 4 and frame.kind != 5 {
					return Err(InvalidClaims("invalid captured alias kind"))
				}
				$aliases = $aliases.append({ key: { birth: frame.at, row: $row.address, slot: frame.slot }, kind: frame.kind })
			}
		} else {
			if frame.at != $next or frame.end <= frame.at or frame.end.to_u64() > batch.len() or batch.get(frame.at.to_u64()) != Ok(frame.opcode) {
				return Err(InvalidClaims("capture differs from ordinary command boundaries"))
			}
			$next = frame.end
			$row = frame
			if frame.opcode == 1 {
				$hole_counts = $hole_counts.insert({ birth: frame.at, row: frame.address }, 0)
				$node_counts = $node_counts.insert({ birth: frame.at, row: frame.address }, 0)
			}
		}
		if is_birth(frame) {
			if frame.address == 0 or frame.address == 0xffffffff {
				return Err(InvalidClaims("reserved birth address"))
			}
			match $latest.get(frame.address) {
				Ok(previous) if previous.at == frame.at => return Err(InvalidClaims("duplicate address at one birth"))
				_ => {}
			}
			$latest = $latest.insert(frame.address, frame)
		}
	}
	if $next.to_u64() != batch.len() {
		return Err(InvalidClaims("capture does not cover ordinary batch"))
	}
	for alias in $aliases {
		if $holes.get(alias.key) != Ok(alias.kind) {
			return Err(InvalidClaims("alias does not match a captured row hole"))
		}
	}
	Ok({ latest: $latest, holes: $holes, hole_counts: $hole_counts, nodes: $nodes, node_counts: $node_counts })
}

## u32 framing is explicitly little endian in both independent hash domains.
write_u32 : List(U8), U32 -> List(U8)
write_u32 = |bytes, value| bytes.append(value.to_u8_wrap()).append(value.shr_zf_wrap(8).to_u8_wrap()).append(value.shr_zf_wrap(16).to_u8_wrap()).append(value.shr_zf_wrap(24).to_u8_wrap())

## UTF-8 lengths are measured before a canonical buffer exists.
string_size : Str -> Try(U64, PictureClaims.Error)
string_size = |text| {
	count = text.count_utf8_bytes()
	if count > 4294967295 {
		Err(InvalidClaims("canonical string exceeds u32"))
	} else {
		Ok(4 + count)
	}
}

## Names are complete facts, including the explicit prefix and colon local data.
name_size : PictureCodec.Name -> Try(U64, PictureClaims.Error)
name_size = |name| {
	if name.local.is_empty() {
		return Err(InvalidClaims("empty canonical local name"))
	}
	Ok(string_size(name.namespace)? + string_size(name.prefix)? + string_size(name.local)?)
}

write_string : List(U8), Str -> List(U8)
write_string = |bytes, text| write_u32(bytes, text.count_utf8_bytes().to_u32_wrap()).concat(text.to_utf8())

write_name : List(U8), PictureCodec.Name -> List(U8)
write_name = |bytes, name| write_string(write_string(write_string(bytes, name.namespace), name.prefix), name.local)

## Preflight physical semantics independently of the codec's data-only graph.
## The renderer already certified parse-back
## This checks the joined identity
## and exact text partitions rather than treating a digest as certification.
measure_picture : PictureCodec.Envelope, PictureClaims.MeasurementProps -> Try(List(U8), PictureClaims.Error)
measure_picture = |envelope, props| {
	check_measurement_limit(props.max_bytes)?
	value = PictureCodec.parts(envelope)
	rendered = props.rendered
	if rendered.physical.len() != value.physical_count.to_u64() {
		return Err(InvalidClaims("physical count differs from envelope"))
	}
	match rendered.root_name {
		ElementRoot(name) if name == value.root_name => {}
		_ => return Err(InvalidClaims("measurement root identity differs"))
	}
	check_physical(value, rendered)?
	encoded = PictureCodec.encode(envelope)
	digest_at = 12 + name_size(value.root_name)? + 4
	if digest_at + 64 > encoded.len() {
		return Err(InvalidClaims("digest span outside checked envelope"))
	}
	domain = "roc-signals/picture/19/1".to_utf8()
	var $required = domain.len() + 1 + 4 + encoded.len() - 64 + 4
	for node in rendered.physical {
		$required = $required + 1
		match node {
			Element(element) => {
				$required = $required + name_size(element.name)? + 4
				if element.attributes.len() > 4294967295 {
					return Err(InvalidClaims("attribute count exceeds u32"))
				}
				for (name, text) in element.attributes {
					$required = $required + name_size(name)? + string_size(text)?
				}
			}
			Text(text) | Comment(text) => {
				$required = $required + string_size(text)?
			}
		}
	}
	check_measurement_size({ required: $required, maximum: props.max_bytes })?
	var $bytes = write_u32(List.with_capacity($required).concat(domain).append(0), (encoded.len() - 64).to_u32_wrap())
	$bytes = $bytes.concat(encoded.sublist({ start: 0, len: digest_at })).concat(encoded.sublist({ start: digest_at + 64, len: encoded.len() - digest_at - 64 }))
	$bytes = write_u32($bytes, value.physical_count)
	for node in rendered.physical {
		match node {
			Element(element) => {
				$bytes = write_u32(write_name($bytes.append(1), element.name), element.attributes.len().to_u32_wrap())
				for (name, text) in element.attributes {
					$bytes = write_string(write_name($bytes, name), text)
				}
			}
			Text(text) => {
				$bytes = write_string($bytes.append(2), text)
			}
			Comment(text) => {
				$bytes = write_string($bytes.append(3), text)
			}
		}
	}
	if $bytes.len() != $required {
		crash "PictureClaims.measurement_bytes: checked size differs from encoding"
	}
	Ok($bytes)
}

## Physical element records point to their exact ordinary and intrinsic
## containers. Expanded identity is never reconstructed from a qualified name.
check_physical : PictureCodec.Parts, Dom.Rendered -> Try({}, PictureClaims.Error)
check_physical = |value, rendered| {
	if rendered.containers.len() != value.containers.len() {
		return Err(InvalidClaims("measurement container count differs"))
	}
	var $container_index = 0.U64
	for actual in rendered.containers {
		declared = value.containers.get($container_index) ?? crash "PictureClaims.check_physical: checked container count"
		owner = match actual.owner {
			Mount => Mount
			Element(index) => Element(narrow(index)?)
		}
		if owner != declared.owner or actual.role != declared.role or actual.children.len() != declared.children.len() {
			return Err(InvalidClaims("measurement container identity differs"))
		}
		var $child = 0.U64
		for index in actual.children {
			if declared.children.get($child) != Ok(narrow(index)?) {
				return Err(InvalidClaims("measurement physical child order differs"))
			}
			$child = $child + 1
		}
		$container_index = $container_index + 1
	}
	var $ordinal = 0.U32
	for node in rendered.physical {
		match node {
			Element(element) => {
				ordinary = value.containers.get(element.children) ? |_| InvalidClaims("physical Children container missing")
				if ordinary.owner != Element($ordinal) or ordinary.role != Children {
					return Err(InvalidClaims("physical Children container owner differs"))
				}
				is_template = element.name.namespace == Dom.html_namespace and element.name.local == "template"
				match element.content {
					NoContent if is_template => return Err(InvalidClaims("HTML template lacks intrinsic Content"))
					NoContent => {}
					Content(index) => {
						content = value.containers.get(index) ? |_| InvalidClaims("physical Content container missing")
						if !is_template or content.owner != Element($ordinal) or content.role != Content {
							return Err(InvalidClaims("physical Content target differs"))
						}
					}
				}
			}
			Text(_) | Comment(_) => {}
		}
		$ordinal = $ordinal + 1
	}
	for logical in value.logical {
		match logical {
			ExistingElement(index) => match rendered.physical.get(index.to_u64()) {
				Ok(Element(_)) => {}
				_ => return Err(InvalidClaims("element claim names another physical kind"))
			}
			ExistingComment(index) => match rendered.physical.get(index.to_u64()) {
				Ok(Comment(_)) => {}
				_ => return Err(InvalidClaims("comment claim names another physical kind"))
			}
			_ => {}
		}
	}
	for run in value.runs {
		text = match run.physical {
			Omitted => ""
			Physical(index) => match rendered.physical.get(index.to_u64()) {
				Ok(Text(data)) => data
				_ => return Err(InvalidClaims("text run names another physical kind"))
			}
		}
		check_text_parts(text, run.parts)?
	}
	for scaffold in value.scaffolds {
		match scaffold {
			ControlText(item) => {
				owner = physical_element(rendered, item.owner)?
				if owner.name.namespace != Dom.html_namespace or owner.name.local != "textarea" or owner.children != item.container.to_u64() {
					return Err(InvalidClaims("ControlText target is not a textarea Children container"))
				}
				match item.physical {
					Omitted => {}
					Physical(index) => match rendered.physical.get(index.to_u64()) {
						Ok(Text(_)) => {}
						_ => return Err(InvalidClaims("ControlText scaffold is not Text"))
					}
				}
			}
			AttributeOverride(item) => {
				owner = physical_element(rendered, item.owner)?
				if owner.name.namespace != Dom.html_namespace or owner.name.local != "option" or !item.name.namespace.is_empty() or !item.name.prefix.is_empty() or item.name.local != "selected" {
					return Err(InvalidClaims("attribute restoration target differs from selected option"))
				}
				match item.original {
					Absent => if item.logical_index != 0 {
						return Err(InvalidClaims("absent original attribute has a nonzero unused index"))
					}
					Present(_) => {
						logical_count = owner.attributes.len() + if (item.physical == Absent) 1 else 0
						if item.logical_index.to_u64() >= logical_count {
							return Err(InvalidClaims("original attribute index exceeds restored attribute count"))
						}
					}
				}
				observed = owner.attributes.find_first(|(name, _)| name.namespace == item.name.namespace and name.local == item.name.local)
				physical = match observed {
					Ok((name, text)) => {
						if name != item.name {
							return Err(InvalidClaims("attribute restoration prefix differs"))
						}
						Present(text)
					}
					Err(_) => Absent
				}
				if physical != item.physical {
					return Err(InvalidClaims("attribute restoration physical presence differs"))
				}
			}
			NoSelectionOption(item) => {
				owner = physical_element(rendered, item.owner)?
				option = physical_element(rendered, item.physical_option)?
				if owner.name.namespace != Dom.html_namespace or owner.name.local != "select" or option.name != { namespace: Dom.html_namespace, prefix: "", local: "option" } {
					return Err(InvalidClaims("no-selection scaffold owner or option name differs"))
				}
				if option.attributes != [({ namespace: "", prefix: "", local: "hidden" }, ""), ({ namespace: "", prefix: "", local: "selected" }, ""), ({ namespace: "", prefix: "", local: "value" }, "")] {
					return Err(InvalidClaims("no-selection option attributes differ"))
				}
				children = value.containers.get(option.children) ? |_| InvalidClaims("no-selection option Children missing")
				if !children.children.is_empty() or option.content != NoContent {
					return Err(InvalidClaims("no-selection option is not empty"))
				}
			}
		}
	}
	Ok({})
}

## Semantic role guards consult the declared physical node once by ordinal.
physical_element : Dom.Rendered, U32 -> Try(Dom.PictureElement, PictureClaims.Error)
physical_element = |rendered, index| match rendered.physical.get(index.to_u64()) {
	Ok(Element(element)) => Ok(element)
	_ => Err(InvalidClaims("scaffold owner is not an element"))
}

## Walk UTF-8 once through ordered UTF-16 boundaries. No scalar can be split
## between parts, and zero-length parts remain real logical positions.
check_text_parts : Str, List(PictureCodec.Part) -> Try({}, PictureClaims.Error)
check_text_parts = |text, parts| {
	bytes = text.to_utf8()
	var $at = 0.U64
	var $units = 0.U64
	var $wanted = 0.U64
	for part in parts {
		$wanted = $wanted + part.utf16_units.to_u64()
		while $units < $wanted and $at < bytes.len() {
			lead = bytes.get($at) ?? crash "PictureClaims.check_text_parts: guarded UTF-8 lead"
			width = if (lead < 128) 1 else if (lead < 224) 2 else if (lead < 240) 3 else 4
			$at = $at + width
			$units = $units + if (width == 4) 2 else 1
		}
		if $units != $wanted {
			return Err(InvalidClaims("text part crosses a surrogate boundary or exceeds physical text"))
		}
	}
	if $at != bytes.len() {
		return Err(InvalidClaims("text parts do not cover physical text"))
	}
	Ok({})
}

## Hash domains and little-endian lengths are fixed bytes, including an empty
## mount's zero length rather than an invented flags byte.
expect PictureClaims.fingerprint_bytes([0, 17, 255], {})? == "roc-signals/mount/19/1".to_utf8().concat([0, 3, 0, 0, 0, 0, 17, 255])

## Canonical allocation refuses before growing a buffer, at its inclusive cap.
expect {
	bytes = PictureClaims.fingerprint_bytes([], {})?
	actual = {
		exact: PictureClaims.fingerprint_bytes([], { max_measurement_bytes: bytes.len() })?,
		short: PictureClaims.fingerprint_bytes([], { max_measurement_bytes: bytes.len() - 1 }).is_err(),
		raised: PictureClaims.fingerprint_bytes([], { max_measurement_bytes: 67108865 }).is_err(),
	}
	actual == { exact: bytes, short: True, raised: True }
}

## Empty text parts are retained, while splitting an astral scalar is refused.
expect {
	good = check_text_parts("a😀é", [{ logical: 0, utf16_units: 0 }, { logical: 1, utf16_units: 1 }, { logical: 2, utf16_units: 2 }, { logical: 3, utf16_units: 1 }])?
	actual = {
		good,
		split: check_text_parts("😀", [{ logical: 0, utf16_units: 1 }, { logical: 1, utf16_units: 1 }]).is_err(),
		short: check_text_parts("ab", [{ logical: 0, utf16_units: 1 }]).is_err(),
		long: check_text_parts("a", [{ logical: 0, utf16_units: 2 }]).is_err(),
	}
	actual == { good: {}, split: True, short: True, long: True }
}

## A final text lifetime keeps the latest birth when its numeric address was
## removed and reused. Detached oracle lifetimes contribute no picture claim.
expect {
	first = [0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 97]
	batch = first.concat([5, 1, 0, 0, 0, 10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 98])
	dom = Dom.apply(Dom.new({}), batch)
	rendered = Dom.render(dom, { root: dom.root, scope: Contents, limits: { max_bytes: 1024, max_nodes: 32, max_depth: 8 } })?
	frames = [
		{ at: 1, end: 19, opcode: 10, address: 1, slot: 0, kind: 0 },
		{ at: 19, end: 24, opcode: 5, address: 1, slot: 0, kind: 0 },
		{ at: 24, end: 42, opcode: 10, address: 1, slot: 0, kind: 0 },
	]
	envelope = PictureClaims.assemble({ dom, rendered, frames, batch, fingerprint: List.repeat(0, 32), expected: List.repeat(0, 32), limits: {} })?
	PictureCodec.parts(envelope).bindings == [{ birth_offset: 24, role: Static, address: 1, slot: 0, kind: Unused, logical: 0 }]
}

## Missing commands, mismatched extents and orphan secondary aliases cannot
## produce a partial binding table which looks like an empty successful mount.
expect {
	frame = { at: 1.U32, end: 3.U32, opcode: 25.U8, address: 0.U32, slot: 0.U32, kind: 0.U8 }
	actual = {
		missing: final_births([], [0, 25, 0]).is_err(),
		opcode: final_births([frame], [0, 17, 0]).is_err(),
		extent: final_births([{ ..frame, end: 4 }], [0, 25, 0]).is_err(),
		alias: final_births([{ ..frame, opcode: 0, kind: 4, address: 1 }], [0, 25, 0]).is_err(),
	}
	actual == { missing: True, opcode: True, extent: True, alias: True }
}

## An independently authored empty SPC1 fixture pins the entire canonical
## picture input, including domain, hash omission and external-root identity.
expect {
	dom = Dom.modify(Dom.new({}), 0, |node| { ..node, namespace: "", tag: "div" })
	rendered = Dom.render(dom, { root: 0, scope: Contents, limits: { max_bytes: 1024, max_nodes: 32, max_depth: 8 } })?
	envelope = PictureClaims.assemble({ dom, rendered, frames: [], batch: [], fingerprint: List.repeat(17, 32), expected: List.repeat(34, 32), limits: {} })?
	PictureClaims.measurement_bytes(
		envelope,
		{ rendered: rendered },
	)? == [114, 111, 99, 45, 115, 105, 103, 110, 97, 108, 115, 47, 112, 105, 99, 116, 117, 114, 101, 47, 49, 57, 47, 49, 0, 64, 0, 0, 0, 83, 80, 67, 49, 1, 0, 19, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 100, 105, 118, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}

## Internal hole facts consume no command bytes or address birth. All six
## kinds retain their own index, while a secondary alias requires its exact
## matching Bind/Reference hole; metadata ordering does not affect identity.
expect {
	batch = [0, 1, 0]
	row = { at: 1.U32, end: 3.U32, opcode: 1.U8, address: 7.U32, slot: 2.U32, kind: 0.U8 }
	var $frames = [row]
	for kind in 1.U8..=6 {
		$frames = $frames.append({ ..row, opcode: 255, slot: (kind - 1).to_u32(), kind })
	}
	frames = $frames.append({ ..row, opcode: 0, address: 8, slot: 4, kind: 5 })
	captured = final_births(frames, batch)?
	actual = {
		row_birth: captured.latest.get(7)?,
		alias_birth: captured.latest.get(8)?.opcode,
		holes: captured.hole_counts.get({ birth: 1, row: 7 })?,
		property: captured.holes.get({ birth: 1, row: 7, slot: 5 })?,
	}
	actual == { row_birth: row, alias_birth: 0, holes: 6, property: 6 }
}

## Orphan, duplicate, wrong-row and wrong-kind facts fail without becoming
## commands; an alias cannot be certified by a hole of another kind.
expect {
	batch = [0, 1, 0]
	row = { at: 1.U32, end: 3.U32, opcode: 1.U8, address: 7.U32, slot: 2.U32, kind: 0.U8 }
	hole = { ..row, opcode: 255, slot: 0, kind: 4 }
	actual = {
		orphan: final_births([hole], batch).is_err(),
		duplicate: final_births([row, hole, hole], batch).is_err(),
		wrong_row: final_births([row, { ..hole, address: 8 }], batch).is_err(),
		wrong_kind: final_births([row, { ..hole, kind: 7 }], batch).is_err(),
		alias: final_births([row, hole, { ..row, opcode: 0, address: 8, slot: 0, kind: 5 }], batch).is_err(),
	}
	actual == { orphan: True, duplicate: True, wrong_row: True, wrong_kind: True, alias: True }
}
