import Protocol
import parser.Html as MarkupHtml
import unicode.GeneralCategory
import unicode.Scalar

## An independent decoder of the engine's command stream into a small DOM
## model, used as the test and fuzz oracle. It shares no code with the
## engine. Nodes live in one list; engine ids map to node indices (+1).
Dom := [].{

	## The wire protocol version this oracle decodes (design.md, Appendix B).
	## It is spelled here independently of the engine; the spec runner
	## refuses a program that speaks another.
	protocol_version : U32
	protocol_version = Protocol.version

	## A model node has a lifetime index independent of its engine aliases.
	## Routing ids, rendered attributes, live properties and pending browser work
	## stay separate so id reuse or a user edit cannot overwrite another meaning.
	## Expanded attribute identity is namespace URI plus local name; prefix is
	## retained for exact serialization but never aliases another namespace.
	ExpandedName : { namespace : Str, prefix : Str, local : Str }

	DNode : { namespace : Str, prefix : Str, kind : U8, container : U8, content : [None, Some(U64)], svg : Bool, tag : Str, text : Str, attrs : List((ExpandedName, Str)), kids : List(U64), parent : U64, rn : U32, hs : List(Listener), ht : List(U64), ids : List(U32), props : List((Str, Str)), detach_count : U64, keymaps : Dict(Str, KeyIndex), shown : Shown, shown_intent : { dialog : U64, popover : U64 }, pending_toggle : Bool, toggle_slot : U64, scroll : { top : U32, left : U32 }, observing : U8, observed : List(U64) }

	## Browser top-layer state, separate from the value a property decided.
	Shown : [Hidden, Open, Modal, Popover]

	## Scroll operands remain command data; layout belongs to the browser.
	Edge : [Keep, Start, End, Px(U32)]

	## A decoded reference action retains its legacy focus mode or scroll
	## operands. Layout and execution belong to the runner; decoding preserves the
	## request without inventing geometry.
	RefAction : [Focus(U8), IntoView({ block : U8, inline : U8, behavior : U8 }), To({ top : Edge, left : Edge, behavior : U8 })]

	## Deferred work captures a model lifetime, never a recycled engine id.
	RefCmd : { node : U32, target : U64, action : RefAction }

	## A shown-property write captures the target lifetime and its byte position
	## in the batch. The runner can discard a superseded intent before changing
	## top-layer state, even when an engine id has since been rebound.
	ShownCmd : { target : U64, property : U8, value : Shown, intent : U64 }

	## The runner's ordered work after command decoding. Distinct entries keep
	## reference actions, shown changes and service effects recognizable while
	## leaving their scheduling outside this independent DOM decoder.
	AfterCmd : [Ref(RefCmd), Show(ShownCmd), Effect(FxCmd)]

	## Parsed keymaps index canonical labels separately from physical fallback.
	Chord : { key : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool }

	## An incoming key keeps its logical label separate from its physical code.
	## Composition suppresses explicit chords while still allowing an every-key
	## policy to observe the occurrence.
	Key : { key : Str, code : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool, composing : Bool }

	## One rendered chord keeps its own prevention and outside-text policy.
	## Lists retain declaration order, and a physical fallback still reports the
	## chord the author declared.
	KeyEntry : { chord : Chord, prevent : Bool, outside : Bool }

	## Lookup groups include the non-Shift modifiers; Shift is checked inside
	## the selected group using the punctuation rule. Exact labels, physical
	## fallbacks and the final every-key policy remain distinct.
	KeyIndex : { exact : Dict(Str, List(KeyEntry)), physical : Dict(Str, List(KeyEntry)), every : [None, Anywhere, OutsideText] }

	## A selected key declaration supplies both its route and the chord heard
	## by the handler. Its prevention decision is available before delivery, as
	## required for the browser's synchronous default-action boundary.
	KeyTarget : { target : Target, heard : Chord, prevent : Bool }

	## Only ASCII letters fold. Non-Latin labels retain their exact spelling.
	key_label : Str -> Str
	key_label = |key| {
		bs = key.to_utf8()
		if bs.len() == 1 {
			c = bs.first() ?? crash "Dom.key_label: one byte"
			if c >= 'A' and c <= 'Z' {
				return Str.from_utf8([c + 32]) ?? crash "Dom.key_label: ASCII"
			}
		}
		key
	}

	## Physical fallback is eligible only for a single ASCII letter or digit.
	key_alphanumeric : Str -> Bool
	key_alphanumeric = |key| {
		bs = Dom.key_label(key).to_utf8()
		bs.len() == 1 and bs.any(|c| (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))
	}

	## One lookup group carries exact non-Shift modifiers and a canonical label.
	key_group : Str, { ctrl : Bool, alt : Bool, meta : Bool } -> Str
	key_group = |key, mods| "${if (mods.ctrl) "C" else "-"}${if (mods.alt) "A" else "-"}${if (mods.meta) "M" else "-"}${Dom.key_label(key)}"

	## Only ASCII letters and digits have a platform-defined physical fallback.
	physical_key : Str -> Str
	physical_key = |key| {
		bs = Dom.key_label(key).to_utf8()
		if bs.len() != 1 {
			return ""
		}
		c = bs.first() ?? crash "Dom.physical_key: one byte"
		if c >= 'a' and c <= 'z' {
			return "Key${Str.from_utf8([c - 32]) ?? crash "Dom.physical_key: ASCII"}"
		}
		if c >= '0' and c <= '9' {
			return "Digit${key}"
		}
		""
	}

	## Decode the private property once. Malformed framing is executor failure.
	parse_keymap : Str -> KeyIndex
	parse_keymap = |text| {
		bs = text.to_utf8()
		var $at = 0.U64
		var $index = { exact: Dict.empty(), physical: Dict.empty(), every: None }
		while $at < bs.len() {
			policy = Dom.byte(bs, $at)
			if (policy == 'a' or policy == 'o') and bs.get($at + 1) == Ok('*') {
				if $at + 2 != bs.len() {
					crash "executor: keymap every must be last"
				}
				$index = { ..$index, every: if (policy == 'a') Anywhere else OutsideText }
				$at = $at + 2
			} else {
				if bs.len() - $at < 8 {
					crash "executor: truncated keymap entry"
				}
				if policy != 'p' and policy != 'k' {
					crash "executor: invalid keymap policy"
				}
				place = Dom.byte(bs, $at + 1)
				if place != 'a' and place != 'o' {
					crash "executor: invalid keymap place"
				}
				var $flags = []
				for (offset, expected) in [(2.U64, 'C'), (3, 'A'), (4, 'S'), (5, 'M')] {
					flag = Dom.byte(bs, $at + offset)
					if flag != '-' and flag != expected {
						crash "executor: invalid keymap modifier"
					}
					$flags = $flags.append(flag == expected)
				}
				$at = $at + 6
				start = $at
				var $length = 0.U64
				while $at < bs.len() and Dom.byte(bs, $at) >= '0' and Dom.byte(bs, $at) <= '9' {
					digit = (Dom.byte(bs, $at) - '0').to_u64()
					if $length > (bs.len() - digit.min(bs.len())) / 10 {
						crash "executor: keymap key length exceeds property"
					}
					$length = $length * 10 + digit
					$at = $at + 1
				}
				if $at - start > 1 and bs.get(start) == Ok('0') {
					crash "executor: keymap key length has a leading zero"
				}
				if $at == start or $at >= bs.len() or Dom.byte(bs, $at) != ':' or $length > bs.len() - $at - 1 {
					crash "executor: invalid keymap key length"
				}
				key = Str.from_utf8(bs.sublist({ start: $at + 1, len: $length })) ?? crash "executor: invalid keymap UTF-8"
				$at = $at + 1 + $length
				chord = { key, ctrl: $flags.get(0) ?? Bool.False, alt: $flags.get(1) ?? Bool.False, shift: $flags.get(2) ?? Bool.False, meta: $flags.get(3) ?? Bool.False }
				entry = { chord, prevent: policy == 'p', outside: place == 'o' }
				mods = { ctrl: chord.ctrl, alt: chord.alt, meta: chord.meta }
				group = Dom.key_group(key, mods)
				index = $index
				physical = Dom.physical_key(key)
				pg = Dom.key_group(physical, mods)
				$index = {
					..index,
					exact: index.exact.insert(group, (index.exact.get(group) ?? []).append(entry)),
					physical: if physical == "" {
						index.physical
					} else {
						index.physical.insert(pg, (index.physical.get(pg) ?? []).append(entry))
					},
				}
			}
		}
		$index
	}

	## HTML enumerated attributes use ASCII case-insensitive keywords. An
	## invalid contenteditable keyword inherits its nearest valid ancestor.
	enum_attr : DNode, Str -> Str
	enum_attr = |node, name| MarkupHtml.ascii_lower(Dom.attr_of(node, name))

	## The raw type keyword with HTML's ASCII case rule. Missing and invalid
	## values stay as written apart from case; this does not apply defaults.
	input_type : DNode -> Str
	# TODO(roc-parser#118): use its public HTML enumeration API when exposed.
	input_type = |node| Dom.enum_attr(node, "type")

	## OutsideText is about the event target, including inherited editability.
	text_entry : Model, U64 -> Bool
	text_entry = |dom, i| {
		n = Dom.node(dom, i)
		if ["textarea", "select"].contains(n.tag) {
			return Bool.True
		}
		if n.tag == "input" and !Protocol.text_entry_excluded.contains(Dom.input_type(n)) {
			return Bool.True
		}
		Dom.content_editable(dom, i)
	}

	## Browser editability inherits through invalid enumeration values and
	## stops at false; this does not make every editable descendant focusable.
	content_editable : Model, U64 -> Bool
	content_editable = |dom, i| {
		var $at = i
		while True {
			item = Dom.node(dom, $at)
			if Dom.has_attr(item, "contenteditable") {
				match MarkupHtml.attribute_keyword({ element: item.tag, attribute: "contenteditable", value: Dom.attr_of(item, "contenteditable") }) {
					Ok("false") => return Bool.False
					Ok(_) => return Bool.True
					Err(_) => {}
				}
			}
			if item.parent == 0 {
				return Bool.False
			}
			$at = item.parent - 1
		}
	}

	## Shift is ignored only for one Unicode punctuation or symbol scalar.
	key_symbol : Str -> Bool
	key_symbol = |key| {
		bs = key.to_utf8()
		first = bs.first() ?? return Bool.False
		width = if (first < 128) 1 else if (first < 224) 2 else if (first < 240) 3 else 4
		if bs.len() != width {
			return Bool.False
		}
		var $scalar = first.to_u32().bitwise_and(if (width == 1) 127 else if (width == 2) 31 else if (width == 3) 15 else 7)
		for byte in bs.drop_first(1) {
			$scalar = $scalar * 64 + byte.to_u32().bitwise_and(63)
		}
		scalar = Scalar.from_u32($scalar) ?? return Bool.False
		match GeneralCategory.of_scalar(scalar) {
			Pc | Pd | Ps | Pe | Pi | Pf | Po | Sm | Sc | Sk | So => Bool.True
			_ => Bool.False
		}
	}

	## Exact entries win over all physical fallbacks; every is tried last,
	## including while composition suppresses the explicit chord entries.
	key_match : KeyIndex, Key, Bool -> Try({ heard : Chord, prevent : Bool }, [Unheard])
	key_match = |index, key, in_text| {
		if key.key.is_empty() {
			return Err(Unheard)
		}
		mods = { ctrl: key.ctrl, alt: key.alt, meta: key.meta }
		fits = |e| (!e.outside or !in_text) and (e.chord.shift == key.shift or Dom.key_symbol(e.chord.key))
		if !key.composing {
			exact = index.exact.get(Dom.key_group(key.key, mods)) ?? []
			match exact.find_first(fits) {
				Ok(e) => return Ok({ heard: e.chord, prevent: e.prevent })
				Err(_) => {}
			}
			if !Dom.key_alphanumeric(key.key) {
				fallback = index.physical.get(Dom.key_group(key.code, mods)) ?? []
				match fallback.find_first(fits) {
					Ok(e) => return Ok({ heard: e.chord, prevent: e.prevent })
					Err(_) => {}
				}
			}
		}
		if index.every == Anywhere or (index.every == OutsideText and !in_text) {
			return Ok({ heard: { key: key.key, ctrl: key.ctrl, alt: key.alt, shift: key.shift, meta: key.meta }, prevent: Bool.False })
		}
		Err(Unheard)
	}

	## Resolve a matching element handler first, then the newest live document
	## handler. The latter list is populated by LISTEN and emptied by RELEASE.
	key_target : Model, U64, Str, Key -> Try(KeyTarget, [NoHandler])
	key_target = |dom, i, event, key| {
		if key.key.is_empty() {
			return Err(NoHandler)
		}
		in_text = Dom.text_entry(dom, i)
		var $at = i
		while True {
			n = Dom.node(dom, $at)
			for listener in n.hs {
				if listener.event == event and listener.kind == 4 and listener.policies.bitwise_and(16) == 0 {
					index = n.keymaps.get(event) ?? Dom.parse_keymap("")
					match Dom.key_match(index, key, in_text) {
						Ok(matched) => {
							var $route = $at
							while Dom.node(dom, $route).rn == 0 {
								$route = Dom.node(dom, $route).parent - 1
							}
							return Ok({ target: { node: Dom.node(dom, $route).rn, handler: listener.handler, event, kind: 4, policies: listener.policies, declaring: $at }, heard: matched.heard, prevent: matched.prevent })
						}
						Err(_) => {}
					}
				}
			}
			if n.parent == 0 {
				break
			}
			$at = n.parent - 1
		}
		var $n = dom.documents.len()
		while $n > 0 {
			$n = $n - 1
			doc = dom.documents.get($n) ?? crash "Dom.key_target: bounded index"
			if doc.event == event {
				n = Dom.node(dom, doc.index)
				listener = n.hs.find_first(|h| h.event == event and h.policies.bitwise_and(16) != 0) ?? crash "Dom.key_target: registered listener"
				match Dom.key_match(n.keymaps.get(event) ?? Dom.parse_keymap(""), key, in_text) {
					Ok(matched) => return Ok({ target: { node: n.rn, handler: listener.handler, event, kind: 4, policies: listener.policies, declaring: doc.index }, heard: matched.heard, prevent: matched.prevent })
					Err(_) => {}
				}
			}
		}
		Err(NoHandler)
	}

	## The selected rendered entry determines the synchronous default policy.
	key_prevents : Model, U64, Str, Key -> Bool
	key_prevents = |dom, i, event, key| Dom.key_target(dom, i, event, key).map_ok(|m| m.prevent) ?? Bool.False

	## Rendered handler metadata stores the payload kind and policy bits beside
	## the handler number. Stream decoding validates that closed vocabulary before
	## installing the declaration.
	Listener : { event : Str, handler : U32, kind : U8, policies : U32 }

	## The declaring model node and the engine routing node are different
	## addresses. A reference alias on a descendant must not replace the owning
	## row's routing id when an event bubbles.
	Target : { node : U32, handler : U32, event : Str, kind : U8, policies : U32, declaring : U64 }

	## A template hole describes its static child path and kind-specific wire
	## operands. Paths are resolved when a row is instantiated, before nested
	## sites can shift its child positions.
	THole : { kind : U8, path : List(U8), name : Str, attribute : ExpandedName, handler : U8, payload_kind : U8, policies : U32, property : U8 }

	## A stored template owns its wire bytes and ordered hole plan. Instances
	## reuse that immutable description, while resolved hole targets belong to
	## each row root's node record.
	Tpl : { bytes : List(U8), root_at : U64, holes : List(THole) }

	## Bounded passive observation of marked batches, independent of the engine.
	TransitionHistory : { count : U64, oldest : U64, bytes : U64, records : Dict(U64, { types : List(Str), bytes : U64 }), exhausted : Bool }

	## Record a performed transition without influencing DOM progress. Retain
	## the newest 4096 records within one MiB of encoded type data; an oversized
	## record clears retained detail, and ordinal exhaustion is remembered.
	transition : Model, List(Str) -> Model
	transition = |dom, types| {
		prior = dom.transitions
		if prior.count == 18446744073709551615 {
			return { ..dom, transitions: { ..prior, exhausted: True } }
		}
		ordinal = prior.count + 1
		bytes = types.fold(0.U64, |n, t| n + 4 + t.to_utf8().len())
		if bytes > 1048576 {
			return { ..dom, transitions: { ..prior, count: ordinal, oldest: ordinal, bytes: 0, records: Dict.empty() } }
		}
		var $history = prior
		while !$history.records.is_empty() and ($history.records.len() >= 4096 or $history.bytes + bytes > 1048576) {
			h = $history
			record = h.records.get(h.oldest) ?? crash "transition history ordinal"
			$history = { ..h, records: h.records.remove(h.oldest), oldest: h.oldest + 1, bytes: h.bytes - record.bytes }
		}
		h = $history
		{ ..dom, transitions: { ..h, count: ordinal, oldest: if (h.records.is_empty()) ordinal else h.oldest, bytes: h.bytes + bytes, records: h.records.insert(ordinal, { types, bytes }) } }
	}

	## The oracle keeps append-only node lifetimes, a packed engine-id index,
	## per-template row membership and passive service observations. Root child
	## links define the drawn tree; detached lifetimes remain available for stale
	## work checks without reusing their indices.
	Model : { nodes : List(DNode), statics : List(U64), rows : List(Dict(U64, {})), tpls : List(Tpl), root : U64, documents : List({ index : U64, event : Str }), observed_count : U64, transitions : TransitionHistory }

	## Start a fresh oracle document with a synthetic root at index zero.
	## No engine aliases, templates, document listeners or observations survive
	## from an earlier model.
	new : {} -> Model
	new = |_| { nodes: [{ namespace: Dom.html_namespace, prefix: "", kind: 1, container: 0, content: None, svg: False, tag: "root", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] }], statics: [], rows: [], tpls: [], root: 0, documents: [], observed_count: 0, transitions: { count: 0, oldest: 0, bytes: 0, records: Dict.empty(), exhausted: False } }

	## Read a little-endian command operand independently of the engine's
	## encoder. Every byte is bounds checked; a short operand is an executor
	## fault rather than a partially decoded value.
	u32 : List(U8), U64 -> U32
	u32 = |b, at| {
		b0 = (b.get(at) ?? crash "executor: short command").to_u32()
		b1 = (b.get(at + 1) ?? crash "executor: short command").to_u32()
		b2 = (b.get(at + 2) ?? crash "executor: short command").to_u32()
		b3 = (b.get(at + 3) ?? crash "executor: short command").to_u32()
		b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
	}

	## Decode a length-prefixed UTF-8 operand and return the following byte
	## offset. The length counts bytes, and either truncated data or invalid UTF-8
	## fails the command instead of changing its text.
	str : List(U8), U64 -> (Str, U64)
	str = |b, at| {
		n = Dom.u32(b, at).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "executor: short string"
		}
		(Str.from_utf8(bytes) ?? crash "executor: bad utf8", at + 4 + n)
	}

	## A `u32` length and that many raw bytes (not necessarily UTF-8).
	raw : List(U8), U64 -> (List(U8), U64)
	raw = |b, at| {
		n = Dom.u32(b, at).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "short byte string"
		}
		(bytes, at + 4 + n)
	}

	## Attribute operands distinguish an omitted attribute from present text,
	## including empty text. Only the two protocol flags are accepted.
	attr_presence : List(U8), U64 -> ([Absent, Present(Str)], U64)
	attr_presence = |bytes, at| match Dom.byte(bytes, at) {
		0 => (Absent, at + 1)
		1 => {
			(text, next) = Dom.str(bytes, at + 1)
			(Present(text), next)
		}
		_ => crash "executor: invalid attribute presence flag"
	}

	## Bounds-check a raw command byte with the decoder's short-command
	## failure. Callers use this for discriminants whose allowed values they
	## validate at their own narrow boundary.
	byte : List(U8), U64 -> U8
	byte = |b, at| b.get(at) ?? crash "executor: short command"

	## Engine id -> node index.
	lookup : Model, U32 -> U64
	lookup = |dom, id| {
		if id == 0 {
			return dom.root
		}
		# statics[id]: node index + 1 in the low 40 bits, row site + 1 above.
		r = (dom.statics.get(id.to_u64()) ?? 0).bitwise_and(1099511627775)
		if r == 0 {
			crash "command names an unknown node ${id.to_str()}"
		}
		r - 1
	}

	## Address a model lifetime directly, including detached nodes retained for
	## stale-work checks. An out-of-range index is an oracle invariant failure;
	## engine ids must first pass through lookup.
	node : Model, U64 -> DNode
	node = |dom, i| dom.nodes.get(i) ?? crash "node index"

	## Replace one lifetime record while preserving the model's secondary
	## indexes. Structural and registration changes use their dedicated helpers;
	## this operation does not infer changes from the replacement record.
	set_node : Model, U64, DNode -> Model
	set_node = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, i, n| { nodes: nodes.set(i, n) ?? crash "node index", statics, rows, tpls, root, documents, observed_count, transitions }

	## Record the append-only index before consuming the node list. No read
	## of the previous list may retain it across append in template decoding.
	add_node : Model, DNode -> (Model, U64)
	add_node = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, n| {
		index = nodes.len()
		({ nodes: nodes.append(n), statics, rows, tpls, root, documents, observed_count, transitions }, index)
	}

	## Bind an engine id to an index plus one, growing the alias array only as
	## needed. Zero remains the unbound sentinel; row ownership is packed by
	## set_row rather than inferred from a node's position.
	set_static : Model, U32, U64 -> Model
	set_static = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, id, idx| {
		var $s = statics
		while $s.len() <= id.to_u64() {
			$s = $s.append(0)
		}
		{ nodes, statics: $s.set(id.to_u64(), idx + 1) ?? crash "static", rows, tpls, root, documents, observed_count, transitions }
	}

	## Bind a row element: its node index, its site (recorded with the id and
	## in the site's row list, so CLEAR can forget the site's rows).
	set_row : Model, U32, U64, U64 -> Model
	set_row = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, id, idx, site| {
		var $s = statics
		while $s.len() <= id.to_u64() {
			$s = $s.append(0)
		}
		var $r = rows
		while $r.len() <= site {
			$r = $r.append(Dict.empty())
		}
		{ list, prev } = $r.replace(site, Dict.empty()) ?? crash "row"
		packed = (idx + 1).bitwise_or((site + 1).shl_wrap(40))
		dom = { nodes, statics: $s.set(id.to_u64(), packed) ?? crash "static", rows: list.set(site, prev.insert(id.to_u64(), {})) ?? crash "row", tpls, root, documents, observed_count, transitions }
		Dom.modify(dom, idx, |n| { ..n, ids: n.ids.append(id) })
	}

	## The site of a bound row element (Err for a static node).
	site_of : Model, U32 -> Try(U64, [Static])
	site_of = |dom, id| {
		v = (dom.statics.get(id.to_u64()) ?? 0).shr_zf_wrap(40)
		if (v == 0) Err(Static) else Ok(v - 1)
	}

	## A neutral record holds no children, aliases or registrations. Besides
	## serving fixtures, it lets modify move a record out of its list before
	## changing nested storage without retaining a second holder.
	empty_node : DNode
	empty_node = { namespace: Dom.html_namespace, prefix: "", kind: 1, container: 0, content: None, svg: False, tag: "", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] }

	## Update node i in place (the node is moved out of the list first, so
	## its kid list stays uniquely owned).
	modify : Model, U64, (DNode -> DNode) -> Model
	modify = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, i, f| {
		{ list, prev } = nodes.replace(i, Dom.empty_node) ?? crash "node index"
		{ nodes: list.set(i, f(prev)) ?? crash "node index", statics, rows, tpls, root, documents, observed_count, transitions }
	}

	## Register a static command alias and remember it on the target lifetime
	## for subtree teardown. This leaves the node's event-routing id unchanged,
	## so references inside a row retain the row's route.
	bind : Model, U32, U64 -> Model
	bind = |dom, id, idx| Dom.modify(Dom.set_static(dom, id, idx), idx, |n| { ..n, ids: n.ids.append(id) })

	## Clear an engine alias and its recorded row-site membership together.
	## The model node remains available for lifetime checks; forgetting a subtree
	## separately clears its reverse alias list.
	unbind : Model, U32 -> Model
	unbind = |{ nodes, statics, rows, tpls, root, documents, observed_count, transitions }, id| {
		packed = statics.get(id.to_u64()) ?? 0
		statics2 = statics.set(id.to_u64(), 0) ?? statics
		site1 = packed.shr_zf_wrap(40)
		if site1 == 0 {
			{ nodes, statics: statics2, rows, tpls, root, documents, observed_count, transitions }
		} else {
			site = site1 - 1
			{ list, prev } = rows.replace(site, Dict.empty()) ?? crash "row"
			{ nodes, statics: statics2, rows: list.set(site, prev.remove(id.to_u64())) ?? crash "row", tpls, root, documents, observed_count, transitions }
		}
	}

	## Register one observation under the command owner that must release it.
	## Template descendants share their row root; targets retain kind flags so
	## removal itself independently rejects a missing RELEASE.
	observe : Model, { owner : U64, target : U64, kind : U8 } -> Model
	observe = |dom, { owner, target, kind }| {
		if kind != 7 and kind != 8 {
			return dom
		}
		bit = if (kind == 7) 1.U8 else 2
		n = Dom.node(dom, target)
		if n.observing.bitwise_and(bit) != 0 {
			crash "executor: duplicate observation"
		}
		registered = Dom.modify(dom, target, |target_node| { ..target_node, observing: target_node.observing.bitwise_or(bit) })
		owned = if n.observing == 0 {
			Dom.modify(registered, owner, |owner_node| { ..owner_node, observed: owner_node.observed.append(target) })
		} else registered
		{ ..owned, observed_count: owned.observed_count + 1 }
	}

	## Release exactly the targets indexed under this owner, before any detach.
	release_observed : Model, U64 -> Model
	release_observed = |dom, owner| {
		var $dom = dom
		for target in Dom.node(dom, owner).observed {
			flags = Dom.node($dom, target).observing
			count = (if (flags.bitwise_and(1) != 0) 1.U64 else 0) + (if (flags.bitwise_and(2) != 0) 1 else 0)
			cleared = Dom.modify($dom, target, |target_node| { ..target_node, observing: 0 })
			$dom = { ..cleared, observed_count: cleared.observed_count - count }
		}
		Dom.modify($dom, owner, |owner_node| { ..owner_node, observed: [] })
	}

	## Forget command aliases and row membership owned by a removed subtree.
	## Walking only its nodes also removes references nested in static content;
	## an id since rebound elsewhere is left with its current owner.
	forget_subtree : Model, U64 -> Model
	forget_subtree = |dom, i| {
		owned = Dom.node(dom, i)
		if owned.observing != 0 or !owned.observed.is_empty() {
			crash "executor: observation detached without RELEASE"
		}
		if dom.documents.any(|d| d.index == i) {
			crash "executor: document key handler detached without RELEASE"
		}
		var $d = dom
		for child in owned.kids.concat(
			match owned.content {
				None => []
				Some(fragment) => [fragment]
			},
		) {
			$d = Dom.forget_subtree($d, child)
		}
		for id in owned.ids {
			if ($d.statics.get(id.to_u64()) ?? 0).bitwise_and(1099511627775) == i + 1 {
				$d = Dom.unbind($d, id)
			}
		}
		Dom.modify($d, i, |n| { ..n, ids: [] })
	}

	## Remove one node from its parent's ordered children and count the
	## detachment. Its subtree and aliases remain available for MOVE; lifetime
	## removal also calls forget_subtree. Searching the sibling list is linear.
	detach : Model, U64 -> Model
	detach = |dom, i| {
		n = Dom.node(dom, i)
		if n.parent == 0 {
			dom
		} else {
			d1 = Dom.modify(
				dom,
				n.parent - 1,
				|p| {
					{ namespace, prefix, kind, container, content, svg, tag, text, attrs, kids, parent, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed } = p
					kept = match kids.find_last_index(|k| k == i) {
						Ok(pos) => kids.drop_at(pos)
						Err(_) => kids
					}
					{ namespace, prefix, kind, container, content, svg, tag, text, attrs, kids: kept, parent, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed }
				},
			)
			Dom.modify(d1, i, |m| { ..m, parent: 0, detach_count: m.detach_count + 1 })
		}
	}

	## Insert node i into parent (before node `before`, or at the end).
	insert : Model, U64, U64, Try(U64, [End]) -> Model
	insert = |dom, parent, i, before| {
		d0 = Dom.detach(dom, i)
		d1 = Dom.modify(
			d0,
			parent,
			|p| {
				{ namespace, prefix, kind, container, content, svg, tag, text, attrs, kids, parent: pp, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed } = p
				kids2 = match before {
					Err(End) => kids.append(i)
					Ok(b) => {
						pos = kids.find_first_index(|k| k == b) ?? crash "insert before a non-child"
						kids.sublist({ start: 0, len: pos }).append(i).concat(kids.sublist({ start: pos, len: kids.len() - pos }))
					}
				}
				{ namespace, prefix, kind, container, content, svg, tag, text, attrs, kids: kids2, parent: pp, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed }
			},
		)
		Dom.modify(d1, i, |n| { ..n, parent: parent + 1 })
	}

	## Place a fresh node by (parent id, before id) as the engine encodes it.
	place : Model, U64, U32, U32 -> Model
	place = |dom, i, parent, before| {
		if before == 0 {
			Dom.insert(dom, if (parent == 0) dom.root else Dom.child_target(dom, Dom.lookup(dom, parent), Dom.node(dom, Dom.lookup(dom, parent)).container), i, Err(End))
		} else {
			b = Dom.lookup(dom, before)
			bp = Dom.node(dom, b).parent
			if bp == 0 {
				crash "insert before a detached node"
			}
			Dom.insert(dom, bp - 1, i, Ok(b))
		}
	}

	## Build a template from its explicit names. Insertion context has no role
	## in decoding and moving a row never reclassifies an element.
	build : Model, List(U8), U64 -> (Model, U64, U64)
	build = |dom, bytes, at| {
		kind = Dom.byte(bytes, at)
		if kind == 2 or kind == 3 {
			(value, next) = Dom.str(bytes, at + 1)
			(next_dom, index) = Dom.add_node(dom, { ..Dom.empty_node, namespace: "", kind, tag: "", text: value })
			return (next_dom, index, next)
		}
		if kind != 1 {
			crash "executor: unknown template node kind"
		}
		(name, name_end) = Dom.expanded_name(bytes, at + 1, True)
		container = Dom.container(bytes, name_end, name)
		count = Dom.byte(bytes, name_end + 1).to_u64()
		var $at = name_end + 2
		var $attrs = []
		var $attribute_index = 0.U64
		while $attribute_index < count {
			$attribute_index = $attribute_index + 1
			(attribute, value_at) = Dom.expanded_name(bytes, $at, False)
			(value, next) = Dom.str(bytes, value_at)
			$attrs = Dom.assign_attribute($attrs, attribute, value)
			$at = next
		}
		children = Dom.byte(bytes, $at).to_u64()
		$at = $at + 1
		(next_dom, index) = Dom.create_node(dom, { ..Dom.empty_node, namespace: name.namespace, prefix: name.prefix, tag: name.local, container, svg: name.namespace == Dom.svg_namespace, attrs: $attrs })
		var $dom = next_dom
		var $child_index = 0.U64
		while $child_index < children {
			$child_index = $child_index + 1
			(child_dom, child, next) = Dom.build($dom, bytes, $at)
			$dom = Dom.insert(child_dom, Dom.child_target(child_dom, index, container), child, Err(End))
			$at = next
		}
		($dom, index, $at)
	}

	## Validate and skip the exact same node framing before reading hole metadata.
	## No model tree or insertion namespace is needed for this bounded byte walk.
	skip : List(U8), U64 -> U64
	skip = |bytes, at| {
		kind = Dom.byte(bytes, at)
		if kind == 2 or kind == 3 {
			return Dom.str(bytes, at + 1).1
		}
		if kind != 1 {
			crash "executor: unknown template node kind"
		}
		(name, name_end) = Dom.expanded_name(bytes, at + 1, True)
		_ = Dom.container(bytes, name_end, name)
		count = Dom.byte(bytes, name_end + 1).to_u64()
		var $at = name_end + 2
		var $attribute_index = 0.U64
		while $attribute_index < count {
			$attribute_index = $attribute_index + 1
			(_, value_at) = Dom.expanded_name(bytes, $at, False)
			$at = Dom.str(bytes, value_at).1
		}
		children = Dom.byte(bytes, $at).to_u64()
		$at = $at + 1
		var $child_index = 0.U64
		while $child_index < children {
			$child_index = $child_index + 1
			$at = Dom.skip(bytes, $at)
		}
		$at
	}

	## Decode and validate a template's hole plan after walking its static
	## node bytes. Unknown hole kinds, invalid listener/property metadata and
	## trailing bytes fail before the template can instantiate rows.
	parse_tpl : List(U8) -> Tpl
	parse_tpl = |b| {
		var $at = Dom.skip(b, 0)
		n = Dom.byte(b, $at).to_u64()
		$at = $at + 1
		var $holes = []
		var $k = 0.U64
		while $k < n {
			kind = Dom.byte(b, $at)
			depth = Dom.byte(b, $at + 1).to_u64()
			path = b.sublist({ start: $at + 2, len: depth * 2 })
			$at = $at + 2 + depth * 2
			if kind == 2 {
				(attribute, next) = Dom.expanded_name(b, $at, False)
				$holes = $holes.append({ kind, path, name: "", attribute, handler: 0, payload_kind: 0, policies: 0, property: 0 })
				$at = next
			} else if kind == 3 {
				hb = Dom.byte(b, $at)
				(ev, next) = Dom.str(b, $at + 1)
				payload_kind = Dom.byte(b, next)
				policies = Dom.u32(b, next + 1)
				Dom.check_listener({ event: ev, kind: payload_kind, policies })
				$holes = $holes.append({ kind, path, name: ev, attribute: Dom.empty_name, handler: hb, payload_kind, policies, property: 0 })
				$at = next + 5
			} else if kind == 6 {
				property = Dom.byte(b, $at)
				_ = Dom.property_name(property)
				$holes = $holes.append({ kind, path, name: "", attribute: Dom.empty_name, handler: 0, payload_kind: 0, policies: 0, property })
				$at = $at + 1
			} else if kind == 1 or kind == 4 or kind == 5 {
				$holes = $holes.append({ kind, path, name: "", attribute: Dom.empty_name, handler: 0, payload_kind: 0, policies: 0, property: 0 })
			} else {
				crash "unknown template hole kind ${kind.to_str()}"
			}
			$k = $k + 1
		}
		if $at != b.len() {
			crash "template length mismatch"
		}
		{ bytes: b, root_at: 0, holes: $holes }
	}

	## Resolve a template's child-ordinal path against its freshly built
	## structure. Missing children fail the template contract; callers cache the
	## result before dynamic insertions can change sibling positions.
	walk : Model, U64, List(U8) -> U64
	walk = |dom, root, path| {
		var $n = root
		var $at = 0.U64
		while $at < path.len() {
			parent = Dom.child_target(dom, $n, Dom.byte(path, $at))
			$n = Dom.node(dom, parent).kids.get(Dom.byte(path, $at + 1).to_u64()) ?? crash "template path"
			$at = $at + 2
		}
		$n
	}

	## Remove an ordinary unnamespaced attribute without interpreting its text.
	remove_attr_on : Model, U64, Str -> Model
	remove_attr_on = |dom, index, local| Dom.remove_expanded_on(dom, index, Dom.unqualified(local))

	## Apply an ordinary unnamespaced attribute's explicit presence.
	set_presence_on : Model, U64, Str, [Absent, Present(Str)] -> Model
	set_presence_on = |dom, index, local, presence| Dom.set_expanded_presence(dom, index, Dom.unqualified(local), presence)

	## Preserve every present value verbatim, including empty and false text.
	set_attr_on : Model, U64, Str, Str -> Model
	set_attr_on = |dom, index, local, value| Dom.set_expanded_on(dom, index, Dom.unqualified(local), value)

	## Present empty/false text remains distinct from explicit removal, even for
	## boolean and enumerated HTML names.
	expect {
		(d1, i) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div" })
		d2 = Dom.set_attr_on(Dom.set_attr_on(d1, i, "disabled", ""), i, "hidden", "false")
		Dom.has_attr(Dom.node(d2, i), "disabled") and Dom.attr_of(Dom.node(d2, i), "hidden") == "false" and !Dom.has_attr(Dom.node(Dom.remove_attr_on(d2, i, "disabled"), i), "disabled")
	}

	## Browser input changes live properties independently of attributes.
	## Keeping both lets an ordinary attribute on a custom element remain an
	## attribute without manufacturing the element's `value` property.
	set_live_on : Model, U64, Str, Str -> Model
	set_live_on = |dom, i, name, value| Dom.modify(
		dom,
		i,
		|n| {
			props = if (n.props.any(|(key, _)| key == name)) n.props.map(|(key, prior)| if (key == name) (key, value) else (key, prior)) else n.props.append((name, value))
			{ ..n, props }
		},
	)

	## Whether an event target carries the Boolean checked property for kind 5.
	checked_input : DNode -> Bool
	checked_input = |n| Dom.html_tag(n, "input") and ["checkbox", "radio"].contains(Dom.input_type(n))

	## A control's property value, including defaults before its first write.
	live_value : DNode, Str -> Str
	live_value = |n, name| n.props.find_first(|(key, _)| key == name).map_ok(|(_, value)| value) ?? if (name == "checked") "false" else if (name == "value" and n.tag == "button") Dom.attr_of(n, "value") else ""

	## Only known payload kinds and policy bits can occur in a declaration.
	## Invalid numbers come from a protocol mismatch, never an app event.
	check_listener : { event : Str, kind : U8, policies : U32 } -> {}
	check_listener = |{ event, kind, policies }| {
		row = Protocol.kind(kind) ?? crash "executor: unknown payload kind ${kind.to_str()}"
		if kind == 2 and !row.events.contains(event) {
			crash "executor: files payload kind on unsupported event ${event}"
		}
		if kind == 3 and !row.events.contains(event) {
			crash "executor: pointer payload kind on unsupported event ${event}"
		}
		if policies.bitwise_and(4) != 0 and (kind != 3 or event != "pointerdown") {
			crash "executor: capture policy requires a pointerdown pointer handler"
		}
		if policies.bitwise_and(8) != 0 and !((kind == 3 and event == "pointermove") or (kind >= 6 and kind <= 8)) {
			crash "executor: paced policy requires a pointermove pointer handler"
		}
		if policies.bitwise_and(32) != 0 and kind != 8 {
			crash "executor: ahead policy requires a seen observation"
		}
		if kind >= 6 and kind <= 8 {
			allowed = if (kind == 8) 40.U32 else 8
			if !row.events.contains(event) or policies.bitwise_and(8) == 0 or policies.bitwise_and(allowed.bitwise_not()) != 0 {
				crash "executor: layout payload requires its matching paced declaration"
			}
		}
		if kind == 9 and (!row.events.contains(event) or policies != 1) {
			crash "executor: paste text requires paste and prevention"
		}
		if kind == 5 and !row.events.contains(event) {
			crash "executor: open-state payload requires close, toggle or change"
		}
		if kind == 4 and !row.events.contains(event) {
			crash "executor: key payload requires keydown or keyup"
		}
		if policies.bitwise_and(16) != 0 and kind != 4 {
			crash "executor: document policy requires a key handler"
		}
		if kind == 4 and policies.bitwise_and(1) != 0 {
			crash "executor: key prevention belongs to its keymap"
		}
		if policies.bitwise_and(Protocol.policy_mask.bitwise_not()) != 0 {
			crash "executor: unknown event policy bits ${policies.to_str()}"
		}
	}

	## Decode only the private property vocabulary; invalid values are wire faults.
	shown_value : U8, Str -> Shown
	shown_value = |property, value| match (property, value) {
		(6, "hidden") | (7, "false") => Hidden
		(6, "open") => Open
		(6, "modal") => Modal
		(7, "true") => Popover
		_ => crash "executor: invalid shown property value"
	}

	## Each scroll edge consumes exactly its discriminant and optional pixel value.
	read_edge : List(U8), U64 -> (Edge, U64)
	read_edge = |bytes, at| match Dom.byte(bytes, at) {
		0 => (Keep, at + 1)
		1 => (Start, at + 1)
		2 => (End, at + 1)
		3 => (Px(Dom.u32(bytes, at + 1)), at + 5)
		_ => crash "executor: unknown scroll edge"
	}

	## The independent property table fixes each wire index's claimed name.
	property_name : U8 -> Str
	property_name = |property| (Protocol.property(property) ?? crash "executor: unknown property index ${property.to_str()}").name

	## HTML interprets an input's type without ASCII case. Keep the raw
	## attribute for assertions while applying the browser's file-input rule.
	is_file_input : DNode -> Bool
	is_file_input = |n| Dom.html_tag(n, "input") and Dom.input_type(n) == "file"

	## The browser's file-input guard recognizes every ASCII spelling while
	## leaving other input types available for value properties.
	expect ["file", "FILE", "FiLe", "text", "filex"].map(|kind| Dom.is_file_input({ ..Dom.empty_node, tag: "input", attrs: Dom.attributes([("type", kind)]) })) == [Bool.True, Bool.True, Bool.True, Bool.False, Bool.False]

	## Apply one declared property in stream order, preserving the mirror
	## attribute used by browser update observations. A file input rejects a
	## value where it is applied because its type may change during a turn.
	set_property_on : Model, U64, U8, Str, U32 -> Model
	set_property_on = |dom, i, property, value, command_node| {
		row = Protocol.property(property) ?? crash "executor: unknown property index ${property.to_str()}"
		name = row.name
		if property == 6 or property == 7 {
			n = Dom.node(dom, i)
			_ = Dom.shown_value(property, value)
			if (property == 6 and !row.elements.contains(n.tag)) or (property == 7 and !(MarkupHtml.attribute_keyword({ element: n.tag, attribute: "popover", value: Dom.attr_of(n, "popover") }).map_ok(|keyword| ["auto", "manual"].contains(keyword)) ?? False)) {
				crash "executor: shown property on unsupported element at node ${command_node.to_str()}"
			}
			return Dom.set_live_on(dom, i, name, value)
		}
		if property >= 3 {
			if Dom.node(dom, i).tag.is_empty() {
				crash "executor: pointer zone property requires an element"
			}
			return if property == 3 {
				Dom.set_live_on(dom, i, name, value)
			} else {
				Dom.modify(dom, i, |n| { ..n, keymaps: n.keymaps.insert(if (property == 4) "keydown" else "keyup", Dom.parse_keymap(value)) })
			}
		}
		n = Dom.node(dom, i)
		if property == 1 and Dom.is_file_input(n) {
			crash "contract: value property on file input at node ${command_node.to_str()}"
		}
		if property == 2 and value != "true" and value != "false" {
			crash "executor: invalid checked property value"
		}
		allowed = row.elements.contains(n.tag)
		if !allowed {
			crash "executor: property ${name} on unsupported element ${n.tag}"
		}
		mirrored = if (property == 2 and value == "false") Dom.remove_attr_on(dom, i, name) else Dom.set_attr_on(dom, i, name, value)
		Dom.set_live_on(mirrored, i, name, value)
	}

	## Explicit value application uses the last rendered mirror, including when
	## no property changed this turn. A current file input is always forbidden.
	apply_value : Model, U64, U32 -> Model
	apply_value = |dom, i, command_node| {
		n = Dom.node(dom, i)
		if Dom.is_file_input(n) {
			crash "contract: value property on file input at node ${command_node.to_str()}"
		}
		Dom.set_live_on(dom, i, "value", Dom.attr_of(n, "value"))
	}

	## Replace the text carried by one lifetime without rebuilding its other
	## metadata. Children are changed by structural commands, independently of
	## this stored text operand.
	set_text_on : Model, U64, Str -> Model
	set_text_on = |dom, i, t| {
		n = Dom.node(dom, i)
		Dom.set_node(dom, i, { ..n, text: t })
	}

	## Apply one command batch.
	apply : Model, List(U8) -> Model
	apply = |dom0, b| Dom.apply_ops(dom0, b).0

	## Give command traces their diagnostic opcode labels. The fallback label
	## does not validate a command; decode_commands rejects unknown wire opcodes
	## before any caller can treat them as performed work.
	op_name : U8 -> Str
	op_name = |op| Protocol.op_name(op)

	## Opcode histogram of a batch, e.g. "SETTEXT=1 ATTR=1".
	describe : List(U8) -> Str
	describe = |ops| {
		var $parts = []
		for row in Protocol.ops {
			n = ops.count_if(|op| op == row.code)
			if n > 0 {
				$parts = $parts.append("${row.name}=${n.to_str()}")
			}
		}
		Str.join_with($parts, " ")
	}

	## Network policy decoded independently from the command stream.
	HttpOptions : { cache : Str, credentials : Str, progress_ms : U32 }

	## Validate the closed policy bytes, including upload’s fixed default cache.
	http_options : List(U8), U64, Bool -> HttpOptions
	http_options = |bytes, at, upload| {
		cache_code = Dom.byte(bytes, at)
		if upload and cache_code != 1 {
			crash "invalid HTTP cache policy"
		}
		cache = (Protocol.http_cache.find_first(|row| row.code == cache_code) ?? crash "invalid HTTP cache policy").name
		credentials_code = Dom.byte(bytes, at + 1)
		credentials = (Protocol.http_credentials.find_first(|row| row.code == credentials_code) ?? crash "invalid HTTP credentials policy").name
		progress_ms = Dom.u32(bytes, at + 2)
		if progress_ms > 0 and progress_ms < 16 {
			crash "invalid HTTP progress interval"
		}
		{ cache, credentials, progress_ms }
	}

	## An effect command, decoded independently of the engine.
	FxCmd : [
		Http(U32, Str, Str, List((Str, Str)), Str, U32, HttpOptions),
		Get(U32, Str),
		SessionGet(U32, Str),
		StorageSub(U32, Str),
		StorageFailures(U32),
		Clipboard(U32, { text : Str, html : [Plain, Html(Str)] }),
		Guard(Bool),
		SessionSet(Str, Str),
		SessionRemove(Str),
		Timer(U32, U32),
		Interval(U32, U32),
		Pop(U32),
		OnlineSub(U32),
		VisibilitySub(U32),
		MediaSub(U32, Str),

		## A worker job (`FX` kind 8): its id, then its task's name, input
		## bytes, the files it names (each a handle's token and a range of its
		## file), timeout (ms, 0 none), cancel policy (1 stop, 2 finish) and,
		## for a preparation's task, the preparation and where its input lies.
		Work(U32, WorkJob),
		Cancel(U32),
		Push(Str),
		Replace(Str),
		Set(Str, Str),
		Remove(Str),
		Title(Str),
		Ref(RefCmd),
		Shown(ShownCmd),

		## A read of a file into the page: id, mode (1 bytes, 2 text) and the
		## file's handle token and range.
		FileRead(U32, U8, { token : U64, start : U64, len : U64 }, U64),

		## An HTTP request whose body is a file's range: id, method, URL,
		## headers, the file and the timeout (ms, 0 none).
		Upload(U32, Str, Str, List((Str, Str)), { token : U64, start : U64, len : U64 }, U32, HttpOptions),

		## A digest of a file's range: id, algorithm (1 SHA-256) and the file.
		Digest(U32, U8, { token : U64, start : U64, len : U64 }),

		## A URL that shows a file's range: id and the file.
		FileUrl(U32, { token : U64, start : U64, len : U64 }),

		## A port command (`PORT`): the port and its message.
		PortSend(Str, PortMsg),

		## A port call (`FX` kind 9): id, port, message and timeout (ms, 0
		## none).
		PortCall(U32, Str, PortMsg, U32),

		## A port subscription (`FX` kind 10): id, port and message.
		PortListen(U32, Str, PortMsg),

		## An HTTP request whose body becomes a file (`FX` kind 15): id,
		## method, URL, headers and timeout (ms, 0 none).
		Fetch(U32, Str, Str, List((Str, Str)), U32, HttpOptions),

		## A file's range saved as a download (`SAVE`), and the name it is
		## saved under.
		Save({ token : U64, start : U64, len : U64 }, Str),
	]

	## A port message as the wire carries it: JSON text, the byte blocks its
	## bytes markers name, and the handles and ranges of the files its file
	## markers name.
	PortMsg : { json : Str, blobs : List(List(U8)), files : List({ token : U64, start : U64, len : U64 }) }

	## A worker job as `FX` kind 8 describes it (see [FxCmd]'s `Work`).
	WorkJob : { task : Str, input : List(U8), files : List({ token : U64, start : U64, len : U64 }), timeout_ms : U32, cancel : U8, prepared : [Unprepared, Prepared({ name : Str, input_len : U64, input_files : U64 })] }

	## A port message at `at`: `json:str nblobs:u32 (len:u32 bytes)* nfiles:u32
	## (token:u64 start:u64 len:u64)*`, and where it ends.
	port_msg : List(U8), U64 -> (PortMsg, U64)
	port_msg = |b, at| {
		(json, a1) = Dom.str(b, at)
		nblobs = Dom.u32(b, a1).to_u64()
		var $a = a1 + 4
		var $blobs = []
		while $blobs.len() < nblobs {
			(blob, next) = Dom.raw(b, $a)
			$blobs = $blobs.append(blob)
			$a = next
		}
		nfiles = Dom.u32(b, $a).to_u64()
		$a = $a + 4
		var $files = []
		while $files.len() < nfiles {
			$files = $files.append({ token: Dom.u64(b, $a), start: Dom.u64(b, $a + 8), len: Dom.u64(b, $a + 16) })
			$a = $a + 24
		}
		({ json, blobs: $blobs, files: $files }, $a)
	}

	## Apply one batch and also return its opcode sequence.
	apply_ops : Model, List(U8) -> (Model, List(U8))
	apply_ops = |dom0, b| {
		(d, ops, _) = Dom.apply_fx(dom0, b)
		(d, ops)
	}

	## Apply one batch; also return its opcodes and its effect commands in
	## stream order.
	apply_fx : Model, List(U8) -> (Model, List(U8), List(FxCmd))
	apply_fx = |dom0, b| {
		r = Dom.apply_full(dom0, b)
		(r.dom, r.ops, r.fx)
	}

	## Apply one batch; also return its opcodes, its effect commands in
	## stream order, the node indices each `ATTR`, `HATTR`, `PROP`, `HPROP`, `SETTEXT` or
	## `TEXT` wrote (one entry per command, in order), and the `value`
	## writes of `PROP` and `HPROP` (node index and value, in order: the
	## spec runner defers them on a focused control as the runtime does).
	## Node indices only grow, so a node created by this batch has an index
	## at or above the model's node count before it.
	apply_full : Model, List(U8) -> { dom : Model, ops : List(U8), fx : List(FxCmd), written : List(U64), values : List((U64, Str)) }
	apply_full = |dom0, b| {
		r = Dom.decode_commands(dom0, b, { start: 0, one: Bool.False })
		{ dom: r.dom, ops: r.ops, fx: r.fx, written: r.written, values: r.values }
	}

	## Decode one command at its byte position, allowing the browser model to
	## apply a hiding value before decoding the content removal that follows it.
	apply_next : Model, List(U8), U64 -> { dom : Model, ops : List(U8), fx : List(FxCmd), written : List(U64), values : List((U64, Str)), next : U64 }
	apply_next = |dom, bytes, at| Dom.decode_commands(dom, bytes, { start: at, one: Bool.True })

	## The shared resumable batch reader updates the model and ordered command,
	## write and effect traces. A zero start consumes the batch flag; one-command
	## mode returns the next byte boundary. Unsupported or malformed wire data
	## fails rather than being skipped, and no service effect is executed here.
	decode_commands : Model, List(U8), { start : U64, one : Bool } -> { dom : Model, ops : List(U8), fx : List(FxCmd), written : List(U64), values : List((U64, Str)), next : U64 }
	decode_commands = |dom0, b, { start, one }| {
		var $written = []
		var $values = []
		var $fx = []
		var $d = dom0
		flags = if (b.is_empty()) 0 else Dom.byte(b, 0)
		if flags > 1 {
			crash "executor: unknown command batch flags"
		}
		if b.len() == 1 and flags == 1 {
			crash "executor: marked batch is missing TRANSITION"
		}
		var $at = if (start == 0 and !b.is_empty()) 1 else start
		var $ops = []
		while $at < b.len() and (!one or $ops.is_empty()) {
			intent = $at
			op = Dom.byte(b, $at)
			$ops = $ops.append(op)
			$at = $at + 1
			if op == 1 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				site_id = Dom.u32(b, $at + 12).to_u64()
				tpl = $d.tpls.get(site_id) ?? crash "unknown template"
				$at = $at + 16
				(d1, root, _) = Dom.build($d, tpl.bytes, 0)
				r = Dom.node(d1, root)
				# Hole targets are resolved once, here: content a nested site
				# inserts into the row later shifts sibling indices.
				var $ht = []
				for hole0 in tpl.holes {
					$ht = $ht.append(Dom.walk(d1, root, hole0.path))
				}
				var $dd = Dom.set_node(d1, root, { ..r, rn: nid, ht: $ht })
				for hole in tpl.holes {
					target = Dom.walk($dd, root, hole.path)
					if hole.kind == 1 {
						(v, next) = Dom.str(b, $at)
						$at = next
						$dd = Dom.set_text_on($dd, target, v)
					} else if hole.kind == 2 {
						(presence, next) = Dom.attr_presence(b, $at)
						$at = next
						$dd = Dom.set_expanded_presence($dd, target, hole.attribute, presence)
					} else if hole.kind == 6 {
						(v, next) = Dom.str(b, $at)
						$at = next
						$dd = Dom.set_property_on($dd, target, hole.property, v, nid)
						if hole.property == 6 or hole.property == 7 {
							$dd = Dom.modify($dd, target, |n| { ..n, shown_intent: if (hole.property == 6) { ..n.shown_intent, dialog: intent } else { ..n.shown_intent, popover: intent } })
							$fx = $fx.append(Shown({ target: target, property: hole.property, value: Dom.shown_value(hole.property, v), intent }))
						}
					} else if hole.kind == 3 {
						t = Dom.node($dd, target)
						$dd = Dom.set_node($dd, target, { ..t, hs: t.hs.append({ event: hole.name, handler: hole.handler.to_u32(), kind: hole.payload_kind, policies: hole.policies }) })
						$dd = Dom.observe($dd, { owner: root, target, kind: hole.payload_kind })
					} else if hole.kind == 4 or hole.kind == 5 {
						# Site placeholders and references carry command ids; neither
						# replaces the row root's event routing id.
						id = Dom.u32(b, $at)
						$at = $at + 4
						$dd = Dom.bind($dd, id, target)
					} else {
						crash "unknown template hole kind ${hole.kind.to_str()}"
					}
				}
				$dd = Dom.place($dd, root, parent, before)
				$d = Dom.set_row($dd, nid, root, site_id)
			} else if op == 2 or op == 3 or op == 22 {
				nid = Dom.u32(b, $at)
				h = Dom.byte(b, $at + 4).to_u64()
				(presence, next) = if op == 3 {
					Dom.attr_presence(b, $at + 5)
				} else {
					(text, after) = Dom.str(b, $at + 5)
					(Present(text), after)
				}
				$at = next
				row = Dom.lookup($d, nid)
				tpl = $d.tpls.get(Dom.site_of($d, nid) ?? crash "TEXT/HATTR on a non-row node") ?? crash "unknown template"
				hole = tpl.holes.get(h) ?? crash "unknown hole"
				target = Dom.node($d, row).ht.get(h) ?? crash "hole target"
				if op != 22 or hole.property < 3 {
					$written = $written.append(target)
				}
				$d = if op == 3 {
					if hole.kind != 2 {
						crash "executor: HATTR names a non-attribute hole"
					}
					Dom.set_expanded_presence($d, target, hole.attribute, presence)
				} else {
					v = match presence {
						Present(text) => text
						Absent => crash "internal: a text or property operand is present"
					}
					if op == 22 and hole.property == 1 {
						$values = $values.append((target, v))
					}
					if op == 2 {
						Dom.set_text_on($d, target, v)
					} else {
						if hole.kind != 6 {
							crash "executor: HPROP names a non-property hole"
						}
						Dom.set_property_on($d, target, hole.property, v, nid)
					}
				}
				if op == 22 and (hole.property == 6 or hole.property == 7) {
					v = match presence {
						Present(text) => text
						Absent => crash "executor: missing shown value"
					}
					$d = Dom.modify($d, target, |n| { ..n, shown_intent: if (hole.property == 6) { ..n.shown_intent, dialog: intent } else { ..n.shown_intent, popover: intent } })
					$fx = $fx.append(Shown({ target, property: hole.property, value: Dom.shown_value(hole.property, v), intent }))
				}
			} else if op == 4 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				before = Dom.u32(b, $at + 4)
				$at = $at + 8
				parent = Dom.node($d, i).parent
				if parent == 0 {
					crash "move of a detached node"
				}
				$d = if (before == 0) Dom.insert($d, parent - 1, i, Err(End)) else Dom.insert($d, parent - 1, i, Ok(Dom.lookup($d, before)))
			} else if op == 5 {
				id = Dom.u32(b, $at)
				$at = $at + 4
				i = Dom.lookup($d, id)
				$d = Dom.detach(Dom.forget_subtree($d, i), i)
			} else if op == 6 {
				parent_id = Dom.u32(b, $at)
				owner = Dom.lookup($d, parent_id)
				p = if (parent_id == 0) owner else Dom.child_target($d, owner, Dom.node($d, owner).container)
				site = Dom.u32(b, $at + 4).to_u64()
				$at = $at + 8
				old_kids = Dom.node($d, p).kids
				var $dd = Dom.modify($d, p, |pn| { ..pn, kids: [] })
				for k in old_kids {
					$dd = Dom.modify(Dom.forget_subtree($dd, k), k, |kn| { ..kn, parent: 0, detach_count: kn.detach_count + 1 })
				}
				# Teardown removed this site's rows, including rows nested below
				# them; membership is maintained per id, never by scanning nodes.
				$d = $dd
				_ = site
			} else if op == 7 {
				tpl = Dom.u32(b, $at).to_u64()
				n = Dom.u32(b, $at + 4).to_u64()
				bytes = b.sublist({ start: $at + 8, len: n })
				$at = $at + 8 + n
				t = Dom.parse_tpl(bytes)
				{ nodes, statics, rows, tpls, root, documents, observed_count, transitions } = $d
				var $t = tpls
				while $t.len() <= tpl {
					$t = $t.append({ bytes: [], root_at: 0, holes: [] })
				}
				var $r = rows
				while $r.len() <= tpl {
					$r = $r.append(Dict.empty())
				}
				# A TEMPLATE starts a new lifetime of this site id (ids are
				# recycled): rows of an earlier site that was disposed with an
				# ancestor are forgotten, as the runtime does, or its next CLEAR
				# would unbind node ids reused since.
				$d = { nodes, statics, rows: $r.set(tpl, Dict.empty()) ?? $r, tpls: $t.set(tpl, t) ?? $t, root, documents, observed_count, transitions }
			} else if op == 8 or op == 10 or op == 26 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				(fresh, next) = if op == 8 {
					(name, end) = Dom.expanded_name(b, $at + 12, True)
					({ ..Dom.empty_node, namespace: name.namespace, prefix: name.prefix, tag: name.local, container: Dom.container(b, end, name), svg: name.namespace == Dom.svg_namespace }, end + 1)
				} else {
					(value, end) = Dom.str(b, $at + 12)
					({ ..Dom.empty_node, namespace: "", kind: if (op == 10) 2 else 3, tag: "", text: value }, end)
				}
				$at = next
				(d1, i) = Dom.create_node($d, fresh)
				$d = Dom.bind(Dom.place(d1, i, parent, before), nid, i)
			} else if op == 9 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(name, n1) = Dom.expanded_name(b, $at + 4, False)
				(presence, n2) = Dom.attr_presence(b, n1)
				$at = n2
				$written = $written.append(i)
				$d = Dom.set_expanded_presence($d, i, name, presence)
			} else if op == 23 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				$at = $at + 4
				$d = Dom.release_observed({ ..$d, documents: $d.documents.keep_if(|d| d.index != i) }, i)
			} else if op == 21 {
				id = Dom.u32(b, $at)
				property = Dom.byte(b, $at + 4)
				(value, next) = Dom.str(b, $at + 5)
				$at = next
				i = Dom.lookup($d, id)
				if property < 3 {
					$written = $written.append(i)
				}
				if property == 1 {
					$values = $values.append((i, value))
				}
				$d = Dom.set_property_on($d, i, property, value, id)
				if property == 6 or property == 7 {
					$d = Dom.modify($d, i, |n| { ..n, shown_intent: if (property == 6) { ..n.shown_intent, dialog: intent } else { ..n.shown_intent, popover: intent } })
					$fx = $fx.append(Shown({ target: i, property: property, value: Dom.shown_value(property, value), intent }))
				}
			} else if op == 11 {
				id = Dom.u32(b, $at)
				h = Dom.u32(b, $at + 4)
				(ev, next) = Dom.str(b, $at + 8)
				kind = Dom.byte(b, next)
				policies = Dom.u32(b, next + 1)
				Dom.check_listener({ event: ev, kind, policies })
				$at = next + 5
				i = Dom.lookup($d, id)
				n = Dom.node($d, i)
				$d = Dom.set_node($d, i, { ..n, rn: id, hs: n.hs.append({ event: ev, handler: h, kind, policies }) })
				$d = Dom.observe($d, { owner: i, target: i, kind })
				if policies.bitwise_and(16) != 0 {
					$d = { ..$d, documents: $d.documents.append({ index: i, event: ev }) }
				}
			} else if op == 12 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(t, next) = Dom.str(b, $at + 4)
				$at = next
				$written = $written.append(i)
				$d = Dom.set_text_on($d, i, t)
			} else if op == 13 {
				id = Dom.u32(b, $at)
				kind = Dom.byte(b, $at + 4)
				$at = $at + 5
				if kind == 1 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					var $k = 0.U64
					while $k < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
						$k = $k + 1
					}
					(body, a3) = Dom.str(b, $a)
					timeout = Dom.u32(b, a3)
					$at = a3 + 10
					$fx = $fx.append(Http(id, method, url, $hs, body, timeout, Dom.http_options(b, a3 + 4, False)))
				} else if kind == 2 {
					(key, a1) = Dom.str(b, $at)
					$at = a1
					$fx = $fx.append(Get(id, key))
				} else if kind == 3 {
					$fx = $fx.append(Timer(id, Dom.u32(b, $at)))
					$at = $at + 4
				} else if kind == 4 {
					$fx = $fx.append(Interval(id, Dom.u32(b, $at)))
					$at = $at + 4
				} else if kind == 5 {
					$fx = $fx.append(Pop(id))
				} else if kind == 6 {
					$fx = $fx.append(OnlineSub(id))
				} else if kind == 7 {
					$fx = $fx.append(VisibilitySub(id))
				} else if kind == 8 {
					(task, a1) = Dom.str(b, $at)
					(input, a2) = Dom.raw(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $refs = []
					var $r = a2 + 4
					while $refs.len() < n {
						$refs = $refs.append({ token: Dom.u64(b, $r), start: Dom.u64(b, $r + 8), len: Dom.u64(b, $r + 16) })
						$r = $r + 24
					}
					timeout_ms = Dom.u32(b, $r)
					cancel = b.get($r + 4) ?? crash "truncated work request"
					flag = b.get($r + 5) ?? crash "truncated work request"
					if cancel < 1 or cancel > 2 {
						crash "work request cancel policy ${cancel.to_str()} is not 1 or 2"
					}
					$at = $r + 6
					# A preparation's task names its preparation and where the
					# preparation's input lies at the start of `input`.
					prepared = if flag == 1 {
						(name, a3) = Dom.str(b, $at)
						input_len = Dom.u32(b, a3).to_u64()
						input_files = Dom.u32(b, a3 + 4).to_u64()
						if input_len > input.len() or input_files > n {
							crash "malformed preparation operands for worker task \"${task}\""
						}
						$at = a3 + 8
						Prepared({ name, input_len, input_files })
					} else if flag == 0 {
						Unprepared
					} else {
						crash "work request flag ${flag.to_str()} is not 0 or 1"
					}
					$fx = $fx.append(Work(id, { task, input, files: $refs, timeout_ms, cancel, prepared }))
				} else if kind == 11 {
					mode = Dom.byte(b, $at)
					if mode != 1 and mode != 2 {
						crash "unknown file read mode ${mode.to_str()}"
					}
					$fx = $fx.append(FileRead(id, mode, Dom.file_ref(b, $at + 1), Dom.u64(b, $at + 25)))
					$at = $at + 33
				} else if kind == 12 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					while $hs.len() < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
					}
					$fx = $fx.append(Upload(id, method, url, $hs, Dom.file_ref(b, $a), Dom.u32(b, $a + 24), Dom.http_options(b, $a + 28, True)))
					$at = $a + 34
				} else if kind == 13 {
					algorithm = Dom.byte(b, $at)
					if algorithm != 1 {
						crash "unknown digest algorithm ${algorithm.to_str()}"
					}
					$fx = $fx.append(Digest(id, algorithm, Dom.file_ref(b, $at + 1)))
					$at = $at + 25
				} else if kind == 14 {
					$fx = $fx.append(FileUrl(id, Dom.file_ref(b, $at)))
					$at = $at + 24
				} else if kind == 9 {
					(port, a1) = Dom.str(b, $at)
					(msg, a2) = Dom.port_msg(b, a1)
					$fx = $fx.append(PortCall(id, port, msg, Dom.u32(b, a2)))
					$at = a2 + 4
				} else if kind == 10 {
					(port, a1) = Dom.str(b, $at)
					(msg, a2) = Dom.port_msg(b, a1)
					$fx = $fx.append(PortListen(id, port, msg))
					$at = a2
				} else if kind == 17 or kind == 18 {
					(key, next) = Dom.str(b, $at)
					$at = next
					$fx = $fx.append(if (kind == 17) SessionGet(id, key) else StorageSub(id, key))
				} else if kind == 20 {
					$fx = $fx.append(StorageFailures(id))
				} else if kind == 19 {
					(text, next) = Dom.str(b, $at)
					flag = Dom.byte(b, next)
					$at = next + 1
					html = if (flag == 0) Plain else if flag == 1 {
						(markup, end) = Dom.str(b, $at)
						$at = end
						Html(markup)
					} else crash "executor: invalid ClipboardWrite representation flag"
					$fx = $fx.append(Clipboard(id, { text, html }))
				} else if kind == 16 {
					(query, next) = Dom.str(b, $at)
					$at = next
					$fx = $fx.append(MediaSub(id, query))
				} else if kind == 15 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					while $hs.len() < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
					}
					$fx = $fx.append(Fetch(id, method, url, $hs, Dom.u32(b, $a), Dom.http_options(b, $a + 4, False)))
					$at = $a + 10
				} else {
					crash "unknown effect kind ${kind.to_str()}"
				}
			} else if op == 14 {
				$fx = $fx.append(Cancel(Dom.u32(b, $at)))
				$at = $at + 4
			} else if op == 15 {
				mode = Dom.byte(b, $at)
				(url, a1) = Dom.str(b, $at + 1)
				$at = a1
				$fx = $fx.append(if (mode == 1) Push(url) else if (mode == 2) Replace(url) else crash "unknown nav mode")
			} else if op == 16 {
				mode = Dom.byte(b, $at)
				(key, a1) = Dom.str(b, $at + 1)
				if mode == 1 or mode == 3 {
					(v, a2) = Dom.str(b, a1)
					$at = a2
					$fx = $fx.append(if (mode == 1) Set(key, v) else SessionSet(key, v))
				} else if mode == 2 or mode == 4 {
					$at = a1
					$fx = $fx.append(if (mode == 2) Remove(key) else SessionRemove(key))
				} else {
					crash "unknown store op"
				}
			} else if op == 18 {
				mode = Dom.byte(b, $at)
				ref_node = Dom.u32(b, $at + 1)
				target = Dom.lookup($d, ref_node)
				$at = $at + 5
				action = if mode >= 1 and mode <= 5 {
					Focus(mode)
				} else if mode == 6 {
					block = Dom.byte(b, $at)
					inline = Dom.byte(b, $at + 1)
					behavior = Dom.byte(b, $at + 2)
					if block > 3 or inline > 3 or behavior > 2 {
						crash "executor: invalid scroll-into-view operands"
					}
					$at = $at + 3
					IntoView({ block, inline, behavior })
				} else if mode == 7 {
					(top, next) = Dom.read_edge(b, $at)
					(left, end) = Dom.read_edge(b, next)
					behavior = Dom.byte(b, end)
					if behavior > 2 {
						crash "executor: invalid scroll behavior"
					}
					$at = end + 1
					To({ top, left, behavior })
				} else {
					crash "executor: unknown REF mode ${mode.to_str()}"
				}
				$fx = $fx.append(Ref({ node: ref_node, target, action }))
			} else if op == 17 {
				(t, a1) = Dom.str(b, $at)
				$at = a1
				$fx = $fx.append(Title(t))
			} else if op == 19 {
				(port, a1) = Dom.str(b, $at)
				(msg, a2) = Dom.port_msg(b, a1)
				$at = a2
				$fx = $fx.append(PortSend(port, msg))
			} else if op == 20 {
				file = Dom.file_ref(b, $at)
				(name, a1) = Dom.str(b, $at + 24)
				$at = a1
				$fx = $fx.append(Save(file, name))
			} else if op == 25 {
				on = Dom.byte(b, $at)
				if on > 1 {
					crash "executor: GUARD needs a flag 0 or 1"
				}
				$at = $at + 1
				$fx = $fx.append(Guard(on == 1))
			} else if op == 24 {
				if flags != 1 {
					crash "executor: TRANSITION requires marked batch"
				}
				n = Dom.u32(b, $at).to_u64()
				$at = $at + 4
				var $types = []
				var $i = 0.U64
				while $i < n {
					(t, next) = Dom.str(b, $at)
					$types = $types.append(t)
					$at = next
					$i = $i + 1
				}
				if $at != b.len() {
					crash "executor: TRANSITION must be last"
				}
				$d = Dom.transition($d, $types)
			} else {
				crash "executor: unknown command ${op.to_str()}"
			}
			if $at == b.len() and flags == 1 and op != 24 {
				crash "executor: marked batch is missing TRANSITION"
			}
		}
		{ dom: $d, ops: $ops, fx: $fx, written: $written, values: $values, next: $at }
	}

	## A file's handle token and range on the wire, `token:u64 start:u64
	## len:u64`, at `at`.
	file_ref : List(U8), U64 -> { token : U64, start : U64, len : U64 }
	file_ref = |b, at| { token: Dom.u64(b, at), start: Dom.u64(b, at + 8), len: Dom.u64(b, at + 16) }

	## The engine's work record (design.md, Appendix B): `count:u32
	## (counter:u64)*count`, then `n:u32 (name:str runs:u64)*`. Decoded here,
	## independently of the engine that wrote it.
	Work : { counters : List(U64), cleanups : List((Str, U64)) }

	## Preserve counter order and cleanup names from one complete work record.
	## The primitive readers reject short operands, and the final length check
	## rejects trailing bytes that would otherwise hide a framing mismatch.
	decode_work : List(U8) -> Work
	decode_work = |b| {
		n = Dom.u32(b, 0).to_u64()
		var $at = 4.U64
		var $cs = []
		var $i = 0.U64
		while $i < n {
			$cs = $cs.append(Dom.u64(b, $at))
			$at = $at + 8
			$i = $i + 1
		}
		m = Dom.u32(b, $at).to_u64()
		$at = $at + 4
		var $runs = []
		$i = 0
		while $i < m {
			(name, a1) = Dom.str(b, $at)
			$runs = $runs.append((name, Dom.u64(b, a1)))
			$at = a1 + 8
			$i = $i + 1
		}
		if $at != b.len() {
			crash "work record length mismatch"
		}
		{ counters: $cs, cleanups: $runs }
	}

	## Combine two little-endian words without a floating-point conversion.
	## Handle tokens, ranges and work counters therefore retain all 64 bits in
	## the oracle's decoded values.
	u64 : List(U8), U64 -> U64
	u64 = |b, at| Dom.u32(b, at).to_u64() + Dom.u32(b, at + 4).to_u64().shl_wrap(32)

	## Resolve the nearest declared handler and its payload kind and policy
	## bits. Non-bubbling events inspect only the target; a reference's command
	## id never replaces the owning row's routing id.
	target : Model, U64, Str, Bool -> Try(Target, [NoHandler])
	target = |dom, i, ev, bubbles| {
		var $at = i
		var $found = NoListener
		while True {
			n = Dom.node(dom, $at)
			if $found == NoListener and ($at == i or bubbles) {
				match n.hs.find_first(|listener| listener.event == ev) {
					Ok(listener) => {
						$found = Found(listener, $at)
					}
					Err(_) => {}
				}
			}
			match $found {
				Found(listener, declaring) if n.rn != 0 => return Ok({ node: n.rn, handler: listener.handler, event: listener.event, kind: listener.kind, policies: listener.policies, declaring })
				_ => {}
			}
			if n.parent == 0 {
				return Err(NoHandler)
			}
			$at = n.parent - 1
		}
	}

	## The nearest nonempty pointer zone at or above a node. The key is only
	## returned to the app that authored it, never resolved as engine identity.
	zone_of : Model, U64 -> Try({ index : U64, key : Str }, [Outside])
	zone_of = |dom, i| {
		var $at = i
		while $at != dom.root {
			n = Dom.node(dom, $at)
			key = Dom.live_value(n, "pointer_zone")
			if !key.is_empty() {
				return Ok({ index: $at, key })
			}
			if n.parent == 0 {
				return Err(Outside)
			}
			$at = n.parent - 1
		}
		Err(Outside)
	}

	## Render the modeled subtree as diagnostic HTML-like text in child order.
	## Attribute and text values remain literal, without HTML escaping; this is
	## an inspection of the oracle rather than the browser command executor.
	render : Model, U64 -> Str
	render = |dom, i| {
		n = Dom.node(dom, i)
		if n.kind == 3 {
			"<!--${n.text}-->"
		} else if n.kind == 2 {
			n.text
		} else {
			attrs = n.attrs.map(|(k, v)| " ${Dom.written_name(k)}=\"${v}\"")
			inner = n.kids.map(|k| Dom.render(dom, k))
			"<${n.tag}${Str.join_with(attrs, "")}>${Str.join_with(inner, "")}</${n.tag}>"
		}
	}

	## Collect text-leaf contents through the subtree's ordered children.
	## This models textContent for assertions, independently of layout,
	## attributes and live control properties.
	text_of : Model, U64 -> Str
	text_of = |dom, i| {
		n = Dom.node(dom, i)
		if (n.kind == 3) "" else if (n.kind == 2) n.text else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
	}

	## Attribute presence is independent of its text: an empty value is present.
	has_attr : DNode, Str -> Bool
	has_attr = |element, name| element.attrs.any(|(key, _)| key.namespace.is_empty() and key.local == name)

	## Read the first stored value for an attribute, using empty text when
	## absent. A caller testing presence must also use has_attr, because present
	## empty text is a valid ordinary attribute value.
	attr_of : DNode, Str -> Str
	attr_of = |n, name| n.attrs.find_first(|(key, _)| key.namespace.is_empty() and key.local == name).map_ok(|(_, v)| v) ?? ""

	## First node (depth-first) satisfying `pred`.
	find : Model, U64, (DNode -> Bool) -> Try(U64, [NotFound])
	find = |dom, i, pred| {
		n = Dom.node(dom, i)
		if pred(n) {
			return Ok(i)
		}
		for k in n.kids {
			match Dom.find(dom, k, pred) {
				Ok(r) => {
					return Ok(r)
				}
				Err(_) => {}
			}
		}
		Err(NotFound)
	}

	## Walk the attached tree for the first node with a present matching
	## attribute. Checking presence separately prevents an empty expected value
	## from matching a node that never had the attribute.
	by_attr : Model, Str, Str -> Try(U64, [NotFound])
	by_attr = |dom, name, value| Dom.find(dom, dom.root, |n| Dom.has_attr(n, name) and Dom.attr_of(n, name) == value)

	## Resolve a click for an already located node through the ordinary
	## bubbling listener route, retaining the owning row's engine address.
	click_target : Model, U64 -> Try(Target, [NoHandler])
	click_target = |dom, i| Dom.target(dom, i, "click", Bool.True)

	## Find the first attached button with one child carrying the given stored
	## text. This narrow fixture helper does not resolve nested text or accessible
	## names; the spec runner's semantic locators handle those cases.
	button_with_text : Model, Str -> Try(U64, [NotFound])
	button_with_text = |dom, t| Dom.find(dom, dom.root, |n| n.tag == "button" and n.kids.len() == 1 and (Dom.node(dom, n.kids.get(0) ?? 0)).text == t)

	## A recycled `each` site id starts empty: rows of the site disposed with
	## an ancestor are not unbound by the next site's CLEAR, even when their
	## node ids were reused for static nodes meanwhile.
	expect {
		le32 = |n| [n.bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), 0, 0]
		lstr = |t| le32(t.to_utf8().len().to_u32_wrap()).concat(t.to_utf8())
		elem = |id, tag| [8.U8].concat(le32(id)).concat(le32(0.U32)).concat(le32(0.U32)).concat([0]).concat(lstr("")).concat(lstr(tag)).append(0)
		tpl_bytes = [1.U8, 0].concat(lstr("")).concat(lstr("li")).concat([0, 0, 0, 0])
		template = [7.U8].concat(le32(0.U32)).concat(le32(tpl_bytes.len().to_u32_wrap())).concat(tpl_bytes)
		cmds =
			elem(1.U32, "ul")
				.concat(template)
				.concat([1.U8].concat(le32(2.U32)).concat(le32(1.U32)).concat(le32(0.U32)).concat(le32(0.U32)))
				.concat([5.U8].concat(le32(1.U32)))
				.concat(elem(2.U32, "p"))
				.concat(elem(3.U32, "ul"))
				.concat(template)
				.concat([6.U8].concat(le32(3.U32)).concat(le32(0.U32)))
		dom = Dom.apply(Dom.new({}), [0].concat(cmds))
		(dom.statics.get(2) ?? 0) != 0
	}

	## A non-bubbling event reaches only its target's handler. A bubbling
	## occurrence of the same type can reach the ancestor instead.
	expect {
		base = Dom.new({})
		(d1, parent) = Dom.add_node(base, { ..Dom.empty_node, tag: "div", rn: 10, hs: [{ event: "cancel", handler: 1, kind: 1, policies: 0 }, { event: "scroll", handler: 2, kind: 1, policies: 0 }] })
		(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "input", parent: parent + 1, hs: [{ event: "close", handler: 3, kind: 1, policies: 0 }] })
		actual = {
			target: Dom.target(d2, child, "close", Bool.False),
			ancestor: Dom.target(d2, child, "scroll", Bool.False),
			bubbling: Dom.target(d2, child, "cancel", Bool.True),
		}
		actual == { target: Ok({ node: 10, handler: 3, event: "close", kind: 1, policies: 0, declaring: child }), ancestor: Err(NoHandler), bubbling: Ok({ node: 10, handler: 1, event: "cancel", kind: 1, policies: 0, declaring: parent }) }
	}

	## Removing an ancestor drops both a row's routing id and the command
	## aliases of its references; rebinding an id starts an independent owner.
	expect {
		(d1, parent) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div" })
		(d2, row) = Dom.add_node(d1, { ..Dom.empty_node, tag: "li", rn: 2 })
		(d3, ref_node) = Dom.add_node(d2, { ..Dom.empty_node, tag: "input" })
		d4 = Dom.insert(Dom.insert(Dom.insert(d3, d3.root, parent, Err(End)), parent, row, Err(End)), row, ref_node, Err(End))
		d5 = Dom.bind(Dom.set_row(Dom.bind(d4, 1, parent), 2, row, 0), 3, ref_node)
		d6 = Dom.forget_subtree(d5, parent)
		actual = { parent: d6.statics.get(1)?, row: d6.statics.get(2)?, ref: d6.statics.get(3)?, members: (d6.rows.get(0)?).len() }
		actual == { parent: 0, row: 0, ref: 0, members: 0 }
	}

	## Namespace URIs are identity data, independent from the engine's namespace
	## choices and from the parser's current element vocabulary.
	html_namespace : Str
	html_namespace = "http://www.w3.org/1999/xhtml"
	svg_namespace : Str
	svg_namespace = "http://www.w3.org/2000/svg"

	## Unused hole metadata has no name; this sentinel never reaches a DOM write.
	empty_name : ExpandedName
	empty_name = { namespace: "", prefix: "", local: "" }

	## Ordinary model services address unnamespaced attributes by exact local text.
	unqualified : Str -> ExpandedName
	unqualified = |local| { namespace: "", prefix: "", local }

	## Test fixtures and browser-model services use the same expanded attribute
	## representation as decoded commands, without inventing namespaces.
	attributes : List((Str, Str)) -> List((ExpandedName, Str))
	attributes = |pairs| pairs.map(|(local, value)| (Dom.unqualified(local), value))

	## Qualified spelling is only serialization; it is never an attribute key.
	written_name : ExpandedName -> Str
	written_name = |name| if (name.prefix.is_empty()) name.local else "${name.prefix}:${name.local}"

	## HTML interface behavior requires both its namespace and exact local name.
	## Resolved raw HTML case has already been supplied by the command stream.
	html_tag : DNode, Str -> Bool
	html_tag = |element, local| element.kind == 1 and element.namespace == Dom.html_namespace and element.tag == local

	## Read one explicit namespace and expanded name. Framing and DOM grammar
	## are checked independently from Core; unlisted names remain accepted.
	expanded_name : List(U8), U64, Bool -> (ExpandedName, U64)
	expanded_name = |bytes, at, element| {
		code = Dom.byte(bytes, at)
		(namespace, prefix_at) = match code {
			0 => (Dom.html_namespace, at + 1)
			1 => (Dom.svg_namespace, at + 1)
			2 => ("http://www.w3.org/1998/Math/MathML", at + 1)
			3 => ("", at + 1)
			4 => {
				(uri, next) = Dom.str(bytes, at + 1)
				if uri.is_empty() {
					crash "executor: explicit namespace URI is empty"
				}
				(uri, next)
			}
			_ => crash "executor: unknown namespace kind"
		}
		(prefix, local_at) = Dom.str(bytes, prefix_at)
		(local, next) = Dom.str(bytes, local_at)
		name = { namespace, prefix, local }
		Dom.validate_name(name, element)
		(name, next)
	}

	## Modern DOM local/prefix rules are broader than XML NCNames. Explicit
	## expanded parts must also be representable without a different first-colon
	## split. Ordinary raw HTML and unnamespaced attributes retain local colons.
	validate_name : ExpandedName, Bool -> {}
	validate_name = |name, element| {
		if !dom_local_valid(name.local, element) {
			crash "executor: invalid namespace-dependent local name"
		}
		prefix = name.prefix
		if !prefix.is_empty() {
			if prefix.to_utf8().any(|unit| [0.U8, 9, 10, 12, 13, 32, 47, 58, 62].contains(unit)) {
				crash "executor: invalid namespace prefix"
			}
			if name.namespace.is_empty() {
				crash "executor: namespace prefix without namespace"
			}
			if prefix == "xml" and name.namespace != "http://www.w3.org/XML/1998/namespace" {
				crash "executor: xml prefix requires XML namespace"
			}
		} else if name.local.contains(":") and !((element and (name.namespace == Dom.html_namespace or name.namespace.is_empty())) or (!element and name.namespace.is_empty())) {
			crash "executor: unrepresentable unprefixed local name"
		}
		ordinary = prefix.is_empty() and ((element and (name.namespace == Dom.html_namespace or name.namespace.is_empty())) or (!element and name.namespace.is_empty()))
		declares = prefix == "xmlns" or Dom.written_name(name) == "xmlns"
		if !ordinary and (name.namespace == "http://www.w3.org/2000/xmlns/") != declares {
			crash "executor: invalid xmlns namespace pairing"
		}
	}

	## DOM updates identify an attribute by URI/local and preserve its existing
	## prefix when only its value changes, as setAttributeNS does in Chrome.
	assign_attribute : List((ExpandedName, Str)), ExpandedName, Str -> List((ExpandedName, Str))
	assign_attribute = |entries, name, value| {
		found = entries.any(|(key, _)| key.namespace == name.namespace and key.local == name.local)
		if found {
			entries.map(|(key, prior)| if (key.namespace == name.namespace and key.local == name.local) (key, value) else (key, prior))
		} else entries.append((name, value))
	}

	## Removal ignores prefixes and never removes another namespace's namesake.
	remove_expanded_on : Model, U64, ExpandedName -> Model
	remove_expanded_on = |dom, index, name| Dom.modify(
		dom,
		index,
		|element| {
			attrs = element.attrs.keep_if(|(key, _)| key.namespace != name.namespace or key.local != name.local)
			{ ..element, attrs, shown: if (Dom.html_tag(element, "dialog") and name.namespace.is_empty() and name.local == "open") Hidden else element.shown }
		},
	)

	## Present text is literal data; only the presence tag removes an attribute.
	set_expanded_presence : Model, U64, ExpandedName, [Absent, Present(Str)] -> Model
	set_expanded_presence = |dom, index, name, presence| match presence {
		Absent => Dom.remove_expanded_on(dom, index, name)
		Present(value) => Dom.set_expanded_on(dom, index, name, value)
	}

	## Keep attribute text and the dialog's browser state consistent by presence.
	set_expanded_on : Model, U64, ExpandedName, Str -> Model
	set_expanded_on = |dom, index, name, value| Dom.modify(
		dom,
		index,
		|element| {
			attrs = Dom.assign_attribute(element.attrs, name, value)
			{ ..element, attrs, shown: if (Dom.html_tag(element, "dialog") and name.namespace.is_empty() and name.local == "open" and element.shown == Hidden) Open else element.shown }
		},
	)

	## An intrinsic template fragment is a DOM node, not an emitted engine node.
	## Its parent chain ends here, so inert descendants never bubble through the
	## template owner. The owner still visits it when disposing owned addresses.
	create_node : Model, DNode -> (Model, U64)
	create_node = |dom, element| {
		(d1, index) = Dom.add_node(dom, element)
		if !Dom.html_tag(element, "template") {
			return (d1, index)
		}
		(d2, fragment) = Dom.add_node(d1, { ..Dom.empty_node, namespace: "", kind: 4, tag: "" })
		(Dom.modify(d2, index, |owner| { ..owner, content: Some(fragment) }), index)
	}

	## Decode child ownership independently of namespace construction. Both
	## choices are legal on HTML templates; Content is illegal on other nodes.
	container : List(U8), U64, ExpandedName -> U8
	container = |bytes, at, name| {
		mode = Dom.byte(bytes, at)
		if mode == 0 {
			return 0
		}
		if mode == 1 and name.namespace == Dom.html_namespace and name.local == "template" {
			return 1
		}
		crash "executor: invalid child container"
	}

	## Follow only the explicit container step. No namespace inheritance or
	## literal provenance is reconstructed while applying a command or hole path.
	child_target : Model, U64, U8 -> U64
	child_target = |dom, index, mode| {
		if mode == 0 {
			return index
		}
		if mode == 1 {
			return match Dom.node(dom, index).content {
				Some(fragment) => fragment
				None => crash "executor: content path requires an HTML template"
			}
		}
		crash "executor: unknown child container"
	}

}

## A keymap gives exact labels priority over an earlier physical fallback;
## duplicate places are considered only inside the selected chord group.
expect {
	key = { key: "л", code: "KeyK", ctrl: True, alt: False, shift: False, meta: False, composing: False }
	map = Dom.parse_keymap("paC---1:kkaC---2:л")
	matched = Dom.key_match(map, key, False)?
	{ heard: matched.heard.key, prevent: matched.prevent } == { heard: "л", prevent: Bool.False }
}

## Dvorak labels suppress physical fallback, and composing keys bypass every
## explicit entry while an every declaration preserves their own spelling.
expect {
	base = { key: "k", code: "KeyK", ctrl: True, alt: False, shift: False, meta: False, composing: False }
	map = Dom.parse_keymap("paC---1:k")
	{ dvorak: Dom.key_match(map, { ..base, key: "t" }, False).is_err(), cyrillic: Dom.key_match(map, { ..base, key: "л" }, False).map_ok(|m| m.heard.key), composing: Dom.key_match(map, { ..base, composing: True }, False).is_err(), every: Dom.key_match(Dom.parse_keymap("a*"), { ..base, composing: True }, False).map_ok(|m| m.heard.key) } == { dvorak: Bool.True, cyrillic: Ok("k"), composing: Bool.True, every: Ok("k") }
}

## OutsideText duplicates fall through without changing their listed order.
expect {
	key = { key: "/", code: "Slash", ctrl: False, alt: False, shift: False, meta: False, composing: False }
	map = Dom.parse_keymap("po----1:/ka----1:/o*")
	{ outside: Dom.key_match(map, key, False).map_ok(|m| m.prevent), inside: Dom.key_match(map, key, True).map_ok(|m| m.prevent), every: Dom.key_match(map, { ..key, key: "Escape" }, True).is_err() } == { outside: Ok(Bool.True), inside: Ok(Bool.False), every: Bool.True }
}

## Shift-insensitive Unicode categories exclude letters and Space, and require
## exactly one scalar rather than a combining sequence or a named key.
expect ["?", "`", "€", "💡", "л", "é", " ", "á", "ArrowDown"].map(Dom.key_symbol) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False, Bool.False, Bool.False, Bool.False]

## OutsideText follows HTML enumeration and inheritance rather than treating
## an arbitrary contenteditable attribute as true or a raw input type as text.
expect {
	(d1, parent) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div", attrs: Dom.attributes([("contenteditable", "TRUE")]) })
	(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "span", attrs: Dom.attributes([("contenteditable", "invalid")]) })
	dom = Dom.insert(Dom.insert(d2, d2.root, parent, Err(End)), parent, child, Err(End))
	stopped = Dom.set_attr_on(dom, child, "contenteditable", "FALSE")
	false_parent = Dom.set_attr_on(dom, parent, "contenteditable", "FALSE")
	(d3, checkbox) = Dom.add_node(dom, { ..Dom.empty_node, tag: "input", attrs: Dom.attributes([("type", "CHECKBOX")]) })
	{ inherited: Dom.text_entry(dom, child), stopped: Dom.text_entry(stopped, child), inherited_false: Dom.text_entry(false_parent, child), checkbox: Dom.text_entry(d3, checkbox) } == { inherited: Bool.True, stopped: Bool.False, inherited_false: Bool.False, checkbox: Bool.False }
}

## An empty declared chord is a valid inert entry, while an empty browser
## key dispatches nothing even when every is declared.
expect {
	key = { key: "", code: "", ctrl: False, alt: False, shift: False, meta: False, composing: False }
	map = Dom.parse_keymap("pa----0:a*")
	{ empty: Dom.key_match(map, key, False).is_err(), every: Dom.key_match(map, { ..key, key: "F2" }, False).map_ok(|m| m.heard.key) } == { empty: Bool.True, every: Ok("F2") }
}

## REF decoding captures lifetimes and keeps all legacy modes byte-for-byte.
expect {
	(d1, target) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "button" })
	dom = Dom.bind(d1, 1, target)
	legacy = [1.U8, 2, 3, 4, 5].fold([], |bytes, mode| bytes.concat([18, mode, 1, 0, 0, 0]))
	bytes = legacy.concat([18, 6, 1, 0, 0, 0, 0, 1, 2, 18, 7, 1, 0, 0, 0, 3, 255, 0, 0, 0, 2, 1])
	actual = Dom.apply_full(dom, [0].concat(bytes))
	actual.fx == [1.U8, 2, 3, 4, 5].map(|mode| Ref({ node: 1, target, action: Focus(mode) })).concat([
		Ref({ node: 1, target, action: IntoView({ block: 0, inline: 1, behavior: 2 }) }),
		Ref({ node: 1, target, action: To({ top: Px(255), left: End, behavior: 1 }) }),
	])
}

## Marked batches retain their exact ordered types without interpreting CSS.
expect {
	marked = [1.U8, 24, 2, 0, 0, 0, 5, 0, 0, 0].concat("shelf".to_utf8()).concat([3, 0, 0, 0]).concat("x y".to_utf8())
	first = Dom.apply_full(Dom.new({}), marked)
	second = Dom.apply(first.dom, [1, 24, 0, 0, 0, 0])
	{ ops: first.ops, count: second.transitions.count, types: first.dom.transitions.records.get(1).map_ok(|r| r.types), empty: second.transitions.records.get(2).map_ok(|r| r.types) } == { ops: [24], count: 2, types: Ok(["shelf", "x y"]), empty: Ok([]) }
}

## Observation evicts at both retention limits and never stops DOM progress.
expect {
	var $dom = Dom.new({})
	var $i = 0.U64
	while $i < 4097 {
		$dom = Dom.transition($dom, [])
		$i = $i + 1
	}
	counted = $dom
	large = Str.from_utf8(List.repeat(97.U8, 524289)) ?? crash "ASCII"
	a = Dom.transition(counted, [large])
	b = Dom.transition(a, [large])
	oversize = Dom.transition(b, [large, large])
	maxed = { ..oversize, transitions: { ..oversize.transitions, count: 18446744073709551615 } }
	exhausted = Dom.transition(maxed, [])
	{ count: counted.transitions.count, old: counted.transitions.records.contains(1), len: counted.transitions.records.len(), byte_len: b.transitions.records.len(), bytes: b.transitions.bytes, oversize: oversize.transitions.records.len(), total: oversize.transitions.count, exhausted: exhausted.transitions.exhausted } == { count: 4097, old: False, len: 4096, byte_len: 1, bytes: 524293, oversize: 0, total: 4100, exhausted: True }
}

## Input classification folds only ASCII and leaves raw attributes intact.
expect {
	kinds = ["CHECKBOX", "Text", "FILE", "Radio", "txet", "", "TÉXT"]
	nodes = kinds.map(|kind| { ..Dom.empty_node, tag: "input", attrs: Dom.attributes([("type", kind)]) })
	nodes.map(Dom.input_type) == ["checkbox", "text", "file", "radio", "txet", "", "tÉxt"] and nodes.map(|node| Dom.attr_of(node, "type")) == kinds and Dom.input_type(Dom.empty_node) == ""
}

## The transport's six ordinary boolean names belong to the parser's HTML
## vocabulary. Hidden has a different grammar and is checked separately.
expect ["disabled", "selected", "readonly", "required", "multiple", "open"].all(|attribute| MarkupHtml.boolean_attributes.contains(attribute)) and !MarkupHtml.boolean_attributes.contains("hidden")

## Preserve the legacy wire convention without describing hidden as a boolean
## attribute or applying a browser default to its explicit enumeration.
expect MarkupHtml.attribute_keywords({ element: "div", attribute: "hidden" }) == Ok(["", "hidden", "until-found"])

## OutsideText is platform policy over real HTML input keywords; the parser
## does not choose the policy or repair an unknown type into a known one.
expect MarkupHtml.attribute_keywords({ element: "input", attribute: "type" }).map_ok(|keywords| Protocol.text_entry_excluded.all(|keyword| keywords.contains(keyword))) == Ok(True)

## The controlled popover policy deliberately supports auto/manual, while
## the parser's complete grammar also describes empty and hint spellings.
expect MarkupHtml.attribute_keywords({ element: "div", attribute: "popover" }) == Ok(["", "auto", "manual", "hint"])

## Independent DOM local-name grammar. UTF-8 validity is established by str;
## no XML Unicode-name ranges or engine construction helpers are shared.
dom_local_valid : Str, Bool -> Bool
dom_local_valid = |text, element| {
	bytes = text.to_utf8()
	first = bytes.first() ?? return False
	space = [0.U8, 9, 10, 12, 13, 32, 47, 62]
	if !element {
		return !bytes.any(|byte| space.contains(byte) or byte == '=')
	}
	letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".to_utf8()
	if letters.contains(first) {
		return !bytes.any(|byte| space.contains(byte))
	}
	if first < 128 and first != ':' and first != '_' {
		return False
	}
	allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.:_".to_utf8()
	bytes.all(|byte| byte >= 128 or allowed.contains(byte))
}

## Comment nodes retain their data and child position while remaining absent
## from textContent, independently of any engine constructor or byte encoder.
expect {
	word = |n| [n.to_u8_wrap(), 0.U8, 0, 0]
	text = |value| word(value.count_utf8_bytes()).concat(value.to_utf8())
	parent = [8.U8].concat(word(1.U64)).concat(word(0.U64)).concat(word(0.U64)).concat([0]).concat(text("")).concat(text("div")).append(0)
	leaf = |op, id, value| [op].concat(word(id)).concat(word(1.U64)).concat(word(0.U64)).concat(text(value))
	commands = [0].concat(parent).concat(leaf(10.U8, 2.U64, "before")).concat(leaf(26.U8, 3.U64, "identity:row:7")).concat(leaf(10.U8, 4.U64, "after"))
	dom = Dom.apply(Dom.new({}), commands)
	root = Dom.node(dom, Dom.lookup(dom, 1))
	root.kids.map(|index| Dom.node(dom, index).kind) == [2, 3, 2] and Dom.node(dom, Dom.lookup(dom, 3)).text == "identity:row:7" and Dom.text_of(dom, Dom.lookup(dom, 1)) == "beforeafter"
}

## A template owns an intrinsic disconnected fragment even when ordinary raw
## construction selects childNodes. Content placement never changes that mode.
expect {
	(d1, ordinary) = Dom.create_node(Dom.new({}), { ..Dom.empty_node, tag: "template" })
	(d2, inert) = Dom.create_node(d1, { ..Dom.empty_node, tag: "template", container: 1 })
	(d3, text) = Dom.add_node(d2, { ..Dom.empty_node, namespace: "", kind: 2, text: "inert" })
	fragment = Dom.child_target(d3, inert, 1)
	dom = Dom.insert(d3, fragment, text, Err(End))
	Dom.node(dom, ordinary).kids == [] and Dom.node(dom, inert).kids == [] and Dom.text_of(dom, inert) == "" and Dom.text_of(dom, fragment) == "inert" and Dom.node(dom, text).parent == fragment + 1 and Dom.node(dom, fragment).parent == 0 and Dom.node(dom, fragment).kind == 4 and Dom.node(dom, fragment).ids == []
}

## Disposing the template removes addresses in its disconnected content through
## ownership, while ordinary DOM traversal and text observations remain inert.
expect {
	(d1, owner) = Dom.create_node(Dom.new({}), { ..Dom.empty_node, tag: "template", container: 1 })
	(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "span" })
	fragment = Dom.child_target(d2, owner, 1)
	d3 = Dom.bind(Dom.insert(d2, fragment, child, Err(End)), 5, child)
	dom = Dom.forget_subtree(d3, owner)
	Dom.node(dom, child).ids == [] and (dom.statics.get(5) ?? 0) == 0 and Dom.node(dom, owner).kids == []
}
