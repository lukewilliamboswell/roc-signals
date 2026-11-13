## Names and closed lists shared by consumers of the page protocol. The engine
## keeps its own numbers and semantics; this module never imports Core or reads
## commands. Transport encoding of these facts belongs to the platform root.
Protocol := [].{

	## A consumer's supported framing version, checked independently of Core.
	version : U32
	version = 17

	## One named byte value; the name carries no executable protocol behavior.
	Code : { code : U8, name : Str }

	## One payload vocabulary and its closed event list. Text's empty list means
	## the generic bare-event vocabulary; key events remain explicitly forbidden.
	Kind : { code : U8, name : Str, events : List(Str) }

	## Each policy occupies one bit. Consumers enforce combinations themselves.
	Policy : { bit : U32, name : Str }

	## An element-property row. Empty elements means any element, subject to the
	## row's independently implemented guards, such as the popover declaration.
	Property : { index : U8, name : Str, elements : List(Str) }

	## Command names in wire order. Work counters 1–18 use only that prefix;
	## later opcodes have the separate counter positions defined in Appendix B.
	ops : List(Code)
	ops = [
		{ code: 1, name: "INST" },
		{ code: 2, name: "TEXT" },
		{ code: 3, name: "HATTR" },
		{ code: 4, name: "MOVE" },
		{ code: 5, name: "REMOVE" },
		{ code: 6, name: "CLEAR" },
		{ code: 7, name: "TEMPLATE" },
		{ code: 8, name: "ELEM" },
		{ code: 9, name: "ATTR" },
		{ code: 10, name: "TEXTNODE" },
		{ code: 11, name: "LISTEN" },
		{ code: 12, name: "SETTEXT" },
		{ code: 13, name: "FX" },
		{ code: 14, name: "CANCEL" },
		{ code: 15, name: "NAV" },
		{ code: 16, name: "STORAGE" },
		{ code: 17, name: "TITLE" },
		{ code: 18, name: "REF" },
		{ code: 19, name: "PORT" },
		{ code: 20, name: "SAVE" },
		{ code: 21, name: "PROP" },
		{ code: 22, name: "HPROP" },
		{ code: 23, name: "RELEASE" },
		{ code: 24, name: "TRANSITION" },
		{ code: 25, name: "GUARD" },
	]

	## Trace labels do not validate commands. A decoder rejects unknown bytes at
	## its own boundary before anything can be treated as performed work.
	op_name : U8 -> Str
	op_name = |code| Protocol.ops.find_first(|row| row.code == code).map_ok(|row| row.name) ?? "?"

	## Payload kinds retain their event restrictions without sharing a decoder
	## or policy implementation with the producer.
	kinds : List(Kind)
	kinds = [
		{ code: 1, name: "TEXT", events: [] },
		{ code: 2, name: "FILES", events: ["change", "drop", "paste"] },
		{ code: 3, name: "POINTER", events: ["pointerdown", "pointermove", "pointerup", "pointercancel"] },
		{ code: 4, name: "KEY", events: ["keydown", "keyup"] },
		{ code: 5, name: "OPEN_STATE", events: ["close", "toggle", "change"] },
		{ code: 6, name: "SCROLL", events: ["scroll"] },
		{ code: 7, name: "SIZE", events: ["size"] },
		{ code: 8, name: "SEEN", events: ["seen"] },
		{ code: 9, name: "PASTE", events: ["paste"] },
	]

	## Look up metadata only; the caller decides how an unknown kind fails.
	kind : U8 -> Try(Kind, [UnknownKind(U8)])
	kind = |code| Protocol.kinds.find_first(|row| row.code == code).map_err(|_| UnknownKind(code))

	## The known policy-bit vocabulary; allowed combinations remain consumer code.
	policies : List(Policy)
	policies = [
		{ bit: 1, name: "PREVENT" },
		{ bit: 2, name: "STOP" },
		{ bit: 4, name: "CAPTURE" },
		{ bit: 8, name: "PACED" },
		{ bit: 16, name: "DOCUMENT" },
		{ bit: 32, name: "AHEAD" },
	]

	## The mask rejects unknown bits without spelling the vocabulary again.
	policy_mask : U32
	policy_mask = Protocol.policies.fold(0, |mask, row| mask.bitwise_or(row.bit))

	## Property names and allowed element names, independent of application and
	## namespace data. Each consumer still implements every row's actual behavior.
	properties : List(Property)
	properties = [
		{ index: 1, name: "value", elements: ["input", "textarea", "select", "option"] },
		{ index: 2, name: "checked", elements: ["input"] },
		{ index: 3, name: "pointer_zone", elements: [] },
		{ index: 4, name: "keymap_down", elements: [] },
		{ index: 5, name: "keymap_up", elements: [] },
		{ index: 6, name: "shown", elements: ["dialog"] },
		{ index: 7, name: "popover_shown", elements: [] },
	]

	## A missing row is a protocol mismatch, classified by the consuming boundary.
	property : U8 -> Try(Property, [UnknownProperty(U8)])
	property = |index| Protocol.properties.find_first(|row| row.index == index).map_err(|_| UnknownProperty(index))

	## Browser cache spellings. Upload's required default remains an independent
	## semantic guard, rather than another entry in this metadata table.
	http_cache : List(Code)
	http_cache = [
		{ code: 1, name: "default" },
		{ code: 2, name: "no-store" },
		{ code: 3, name: "reload" },
		{ code: 4, name: "no-cache" },
		{ code: 5, name: "force-cache" },
	]

	## The two credential modes expressible by the wire, in byte order.
	http_credentials : List(Code)
	http_credentials = [{ code: 1, name: "same-origin" }, { code: 2, name: "include" }]

	## This seven-name absence rule is the platform's current convention, not
	## HTML's complete boolean vocabulary. Parser facts independently check it.
	bool_attrs : List(Str)
	bool_attrs = ["disabled", "selected", "readonly", "required", "hidden", "multiple", "open"]

	## OutsideText excludes these input types; this is platform policy. The
	## parser's separate vocabulary checks that each is an HTML type keyword.
	text_entry_excluded : List(Str)
	text_entry_excluded = ["button", "submit", "reset", "checkbox", "radio", "file", "hidden", "range", "color", "image"]

	## Host faults 0–5 and worker-only unavailable/executor labels. The host keeps
	## its own classification code; sharing these names does not share verdicts.
	fault_classes : List(Str)
	fault_classes = ["none", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed", "unavailable", "executor"]

	## One bounded metadata item appended to the module's declarations. It holds
	## no app values and supplies no command layout or execution policy.
	Facts : { ops : List(Code), kinds : List(Kind), policies : List(Policy), properties : List(Property), http_cache : List(Code), http_credentials : List(Code), bool_attrs : List(Str), text_entry_excluded : List(Str), fault_classes : List(Str) }

	## Consumers build their lookup tables after receiving the complete item.
	facts : Facts
	facts = {
		ops: Protocol.ops,
		kinds: Protocol.kinds,
		policies: Protocol.policies,
		properties: Protocol.properties,
		http_cache: Protocol.http_cache,
		http_credentials: Protocol.http_credentials,
		bool_attrs: Protocol.bool_attrs,
		text_entry_excluded: Protocol.text_entry_excluded,
		fault_classes: Protocol.fault_classes,
	}
}

## Opcode codes are dense, unique and one-based, as the work-record prefix needs.
expect Protocol.ops.map(|row| row.code.to_u64()) == (1.U64..=Protocol.ops.len()).iter().fold([], |out, code| out.append(code))

## Property indices are dense, so a consumer can bind exactly one implementation per row.
expect Protocol.properties.map(|row| row.index.to_u64()) == (1.U64..=Protocol.properties.len()).iter().fold([], |out, index| out.append(index))

## Named lookups are unambiguous within each vocabulary, including element
## and event restrictions; repeated names cannot silently overwrite a binding.
expect [
	Protocol.ops.map(|row| row.name),
	Protocol.kinds.map(|row| row.name),
	Protocol.policies.map(|row| row.name),
	Protocol.properties.map(|row| row.name),
	Protocol.http_cache.map(|row| row.name),
	Protocol.http_credentials.map(|row| row.name),
	Protocol.bool_attrs,
	Protocol.text_entry_excluded,
	Protocol.fault_classes,
].concat(Protocol.kinds.map(|row| row.events)).concat(Protocol.properties.map(|row| row.elements)).all(is_unique_names)

## Kinds are one-based and dense while every policy names a distinct single bit.
expect {
	kinds = Protocol.kinds.map(|row| row.code.to_u64())
	bits = Protocol.policies.map(|row| row.bit)
	kinds == (1.U64..=Protocol.kinds.len()).iter().fold([], |out, code| out.append(code)) and bits.all(|bit| bit > 0 and bit.bitwise_and(bit - 1) == 0) and bits.fold(Dict.empty(), |seen, bit| seen.insert(bit, {})).len() == bits.len()
}

## Empty sets are valid for unrestricted rows; an actual name must be nonempty.
is_unique_names : List(Str) -> Bool
is_unique_names = |names| names.all(|name| !name.is_empty()) and names.fold(Dict.empty(), |seen, name| seen.insert(name, {})).len() == names.len()
