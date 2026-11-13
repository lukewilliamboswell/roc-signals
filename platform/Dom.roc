## An independent decoder of the engine's command stream into a small DOM
## model, used as the test and fuzz oracle. It shares no code with the
## engine. Nodes live in one list; engine ids map to node indices (+1).
Dom := [].{

	## The wire protocol version this oracle decodes (design.md, Appendix B).
	## It is spelled here independently of the engine; the spec runner
	## refuses a program that speaks another.
	protocol_version : U32
	protocol_version = 12

	DNode : { tag : Str, text : Str, attrs : List((Str, Str)), kids : List(U64), parent : U64, rn : U32, hs : List(Listener), ht : List(U64), ids : List(U32), props : List((Str, Str)), detach_count : U64, keymaps : Dict(Str, KeyIndex), shown : Shown, shown_intent : { dialog : U64, popover : U64 }, pending_toggle : Bool, toggle_slot : U64, scroll : { top : U32, left : U32 }, observing : U8, observed : List(U64) }

	## Browser top-layer state, separate from the value a property decided.
	Shown : [Hidden, Open, Modal, Popover]

	## Scroll operands remain command data; layout belongs to the browser.
	Edge : [Keep, Start, End, Px(U32)]
	RefAction : [Focus(U8), IntoView({ block : U8, inline : U8, behavior : U8 }), To({ top : Edge, left : Edge, behavior : U8 })]

	## Deferred work captures a model lifetime, never a recycled engine id.
	RefCmd : { node : U32, target : U64, action : RefAction }
	ShownCmd : { target : U64, property : U8, value : Shown, intent : U64 }
	AfterCmd : [Ref(RefCmd), Show(ShownCmd), Effect(FxCmd)]

	## Parsed keymaps index canonical labels separately from physical fallback.
	Chord : { key : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool }
	Key : { key : Str, code : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool, composing : Bool }
	KeyEntry : { chord : Chord, prevent : Bool, outside : Bool }
	KeyIndex : { exact : Dict(Str, List(KeyEntry)), physical : Dict(Str, List(KeyEntry)), every : [None, Anywhere, OutsideText] }
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
	enum_attr = |node, name| Str.from_utf8(Dom.attr_of(node, name).to_utf8().map(|c| if (c >= 'A' and c <= 'Z') c + 32 else c)) ?? crash "Dom.enum_attr: ASCII folding preserves UTF-8"

	## OutsideText is about the event target, including inherited editability.
	text_entry : Model, U64 -> Bool
	text_entry = |dom, i| {
		n = Dom.node(dom, i)
		if ["textarea", "select"].contains(n.tag) {
			return Bool.True
		}
		if n.tag == "input" and !["button", "submit", "reset", "checkbox", "radio", "file", "hidden", "range", "color", "image"].contains(Dom.enum_attr(n, "type")) {
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
				value = Dom.enum_attr(item, "contenteditable")
				if value == "false" {
					return Bool.False
				}
				if ["", "true", "plaintext-only"].contains(value) {
					return Bool.True
				}
			}
			if item.parent == 0 {
				return Bool.False
			}
			$at = item.parent - 1
		}
	}

	# UNICODE LICENSE V3
	#
	# COPYRIGHT AND PERMISSION NOTICE
	#
	# Copyright © 1991-2026 Unicode, Inc.
	#
	# NOTICE TO USER: Carefully read the following legal agreement. BY
	# DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
	# SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
	# TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
	# DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.
	#
	# Permission is hereby granted, free of charge, to any person obtaining a
	# copy of data files and any associated documentation (the "Data Files") or
	# software and any associated documentation (the "Software") to deal in the
	# Data Files or Software without restriction, including without limitation
	# the rights to use, copy, modify, merge, publish, distribute, and/or sell
	# copies of the Data Files or Software, and to permit persons to whom the
	# Data Files or Software are furnished to do so, provided that either (a)
	# this copyright and permission notice appear with all copies of the Data
	# Files or Software, or (b) this copyright and permission notice appear in
	# associated Documentation.
	#
	# THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
	# KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
	# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
	# THIRD PARTY RIGHTS.
	#
	# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
	# BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
	# OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
	# WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
	# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
	# FILES OR SOFTWARE.
	#
	# Except as contained in this notice, the name of a copyright holder shall
	# not be used in advertising or otherwise to promote the sale, use or other
	# dealings in these Data Files or Software without prior written
	# authorization of the copyright holder.
	## Frozen Unicode 18.0.0 punctuation and symbols, independently decoded
	## from UnicodeData.txt (Unicode license: https://www.unicode.org/license.txt).
	## SHA-256: 0736451de439ae7baf1425136617da495e09ee5afbe6e394374db7009ea08950.
	key_symbol_ranges : List((U32, U32))
	key_symbol_ranges = [
		(33, 47),
		(58, 64),
		(91, 96),
		(123, 126),
		(161, 169),
		(171, 172),
		(174, 177),
		(180, 180),
		(182, 184),
		(187, 187),
		(191, 191),
		(215, 215),
		(247, 247),
		(706, 709),
		(722, 735),
		(741, 747),
		(749, 749),
		(751, 767),
		(885, 885),
		(894, 894),
		(900, 901),
		(903, 903),
		(1014, 1014),
		(1154, 1154),
		(1370, 1375),
		(1417, 1418),
		(1421, 1423),
		(1470, 1470),
		(1472, 1472),
		(1475, 1475),
		(1478, 1478),
		(1523, 1524),
		(1542, 1551),
		(1563, 1563),
		(1565, 1567),
		(1642, 1645),
		(1748, 1748),
		(1758, 1758),
		(1769, 1769),
		(1789, 1790),
		(1792, 1805),
		(2038, 2041),
		(2046, 2047),
		(2096, 2110),
		(2142, 2142),
		(2184, 2184),
		(2404, 2405),
		(2416, 2416),
		(2546, 2547),
		(2554, 2555),
		(2557, 2557),
		(2678, 2678),
		(2800, 2801),
		(2928, 2928),
		(3059, 3066),
		(3191, 3191),
		(3199, 3199),
		(3204, 3204),
		(3407, 3407),
		(3449, 3449),
		(3572, 3572),
		(3647, 3647),
		(3663, 3663),
		(3674, 3675),
		(3841, 3863),
		(3866, 3871),
		(3892, 3892),
		(3894, 3894),
		(3896, 3896),
		(3898, 3901),
		(3973, 3973),
		(4030, 4037),
		(4039, 4044),
		(4046, 4058),
		(4170, 4175),
		(4254, 4255),
		(4347, 4347),
		(4960, 4968),
		(5008, 5017),
		(5120, 5120),
		(5741, 5742),
		(5787, 5788),
		(5867, 5869),
		(5941, 5942),
		(6100, 6102),
		(6104, 6107),
		(6144, 6154),
		(6464, 6464),
		(6468, 6469),
		(6622, 6655),
		(6686, 6687),
		(6816, 6822),
		(6824, 6829),
		(6990, 6991),
		(7002, 7018),
		(7028, 7039),
		(7164, 7167),
		(7227, 7231),
		(7294, 7295),
		(7360, 7367),
		(7379, 7379),
		(8125, 8125),
		(8127, 8129),
		(8141, 8143),
		(8157, 8159),
		(8173, 8175),
		(8189, 8190),
		(8208, 8231),
		(8240, 8286),
		(8314, 8318),
		(8330, 8334),
		(8352, 8388),
		(8448, 8449),
		(8451, 8454),
		(8456, 8457),
		(8468, 8468),
		(8470, 8472),
		(8478, 8483),
		(8485, 8485),
		(8487, 8487),
		(8489, 8489),
		(8494, 8494),
		(8506, 8507),
		(8512, 8516),
		(8522, 8525),
		(8527, 8527),
		(8586, 8587),
		(8592, 9257),
		(9280, 9290),
		(9372, 9449),
		(9472, 10101),
		(10132, 11123),
		(11126, 11263),
		(11493, 11498),
		(11513, 11516),
		(11518, 11519),
		(11632, 11632),
		(11776, 11822),
		(11824, 11869),
		(11872, 11875),
		(11904, 11929),
		(11931, 12019),
		(12032, 12245),
		(12272, 12287),
		(12289, 12292),
		(12296, 12320),
		(12336, 12336),
		(12342, 12343),
		(12349, 12351),
		(12443, 12444),
		(12448, 12448),
		(12539, 12539),
		(12688, 12689),
		(12694, 12703),
		(12736, 12773),
		(12783, 12783),
		(12800, 12830),
		(12842, 12871),
		(12880, 12880),
		(12896, 12927),
		(12938, 12976),
		(12992, 13311),
		(19904, 19967),
		(42128, 42182),
		(42238, 42239),
		(42509, 42511),
		(42611, 42611),
		(42622, 42622),
		(42738, 42743),
		(42752, 42774),
		(42784, 42785),
		(42889, 42890),
		(43048, 43051),
		(43062, 43065),
		(43124, 43127),
		(43214, 43215),
		(43256, 43258),
		(43260, 43260),
		(43310, 43311),
		(43359, 43359),
		(43457, 43469),
		(43486, 43487),
		(43612, 43615),
		(43639, 43641),
		(43742, 43743),
		(43760, 43761),
		(43867, 43867),
		(43882, 43883),
		(44011, 44011),
		(64297, 64297),
		(64434, 64466),
		(64830, 64847),
		(64912, 64913),
		(64968, 64975),
		(65020, 65023),
		(65040, 65049),
		(65072, 65106),
		(65108, 65126),
		(65128, 65131),
		(65281, 65295),
		(65306, 65312),
		(65339, 65344),
		(65371, 65381),
		(65504, 65510),
		(65512, 65518),
		(65532, 65533),
		(65792, 65794),
		(65847, 65855),
		(65913, 65929),
		(65932, 65934),
		(65936, 65948),
		(65952, 65952),
		(66000, 66044),
		(66463, 66463),
		(66512, 66512),
		(66927, 66927),
		(67671, 67671),
		(67703, 67704),
		(67871, 67871),
		(67903, 67903),
		(68176, 68184),
		(68223, 68223),
		(68296, 68296),
		(68336, 68342),
		(68409, 68415),
		(68505, 68508),
		(68974, 68974),
		(69006, 69007),
		(69293, 69293),
		(69321, 69322),
		(69328, 69336),
		(69461, 69465),
		(69510, 69513),
		(69703, 69709),
		(69819, 69820),
		(69822, 69825),
		(69952, 69955),
		(70004, 70005),
		(70085, 70088),
		(70093, 70093),
		(70107, 70107),
		(70109, 70111),
		(70200, 70205),
		(70313, 70313),
		(70612, 70613),
		(70615, 70616),
		(70731, 70735),
		(70746, 70747),
		(70749, 70749),
		(70854, 70854),
		(71105, 71127),
		(71233, 71235),
		(71264, 71276),
		(71353, 71353),
		(71484, 71487),
		(71739, 71739),
		(72004, 72006),
		(72162, 72162),
		(72255, 72262),
		(72346, 72348),
		(72350, 72354),
		(72448, 72457),
		(72673, 72673),
		(72769, 72773),
		(72816, 72817),
		(73463, 73464),
		(73539, 73551),
		(73685, 73713),
		(73727, 73727),
		(74864, 74868),
		(77809, 77810),
		(92782, 92783),
		(92917, 92917),
		(92983, 92991),
		(92996, 92997),
		(93549, 93551),
		(93847, 93850),
		(94178, 94178),
		(113820, 113820),
		(113823, 113823),
		(117760, 117999),
		(118010, 118012),
		(118016, 118451),
		(118458, 118480),
		(118482, 118484),
		(118493, 118525),
		(118608, 118723),
		(118784, 119029),
		(119040, 119078),
		(119081, 119140),
		(119146, 119148),
		(119171, 119172),
		(119180, 119209),
		(119214, 119361),
		(119365, 119365),
		(119379, 119386),
		(119389, 119390),
		(119392, 119423),
		(119552, 119638),
		(120513, 120513),
		(120539, 120539),
		(120571, 120571),
		(120597, 120597),
		(120629, 120629),
		(120655, 120655),
		(120687, 120687),
		(120713, 120713),
		(120745, 120745),
		(120771, 120771),
		(120832, 121343),
		(121399, 121402),
		(121453, 121460),
		(121462, 121475),
		(121477, 121483),
		(121600, 121628),
		(123215, 123215),
		(123647, 123647),
		(124415, 124415),
		(125278, 125279),
		(126124, 126124),
		(126128, 126128),
		(126254, 126254),
		(126704, 126705),
		(126976, 127019),
		(127024, 127123),
		(127136, 127150),
		(127153, 127167),
		(127169, 127183),
		(127185, 127221),
		(127245, 127406),
		(127462, 127490),
		(127504, 127547),
		(127552, 127560),
		(127568, 127569),
		(127584, 127589),
		(127744, 128729),
		(128732, 128748),
		(128752, 128764),
		(128768, 128987),
		(128992, 129003),
		(129008, 129035),
		(129040, 129095),
		(129104, 129113),
		(129120, 129159),
		(129168, 129197),
		(129200, 129211),
		(129216, 129217),
		(129232, 129240),
		(129280, 129623),
		(129632, 129645),
		(129648, 129660),
		(129664, 129734),
		(129736, 129736),
		(129740, 129757),
		(129759, 129771),
		(129775, 129786),
		(129792, 129938),
		(129940, 130031),
		(130042, 130042),
	]

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
		var $lo = 0.U64
		var $hi = Dom.key_symbol_ranges.len()
		while $lo < $hi {
			mid = $lo + ($hi - $lo) / 2
			(start, end) = Dom.key_symbol_ranges.get(mid) ?? crash "Dom.key_symbol: bounded index"
			if $scalar < start {
				$hi = mid
			} else if $scalar > end {
				$lo = mid + 1
			} else {
				return Bool.True
			}
		}
		Bool.False
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

	Listener : { event : Str, handler : U32, kind : U8, policies : U32 }

	Target : { node : U32, handler : U32, event : Str, kind : U8, policies : U32, declaring : U64 }

	THole : { kind : U8, path : List(U8), name : Str, handler : U8, payload_kind : U8, policies : U32, property : U8 }

	Tpl : { bytes : List(U8), root_at : U64, holes : List(THole) }

	Model : { nodes : List(DNode), statics : List(U64), rows : List(Dict(U64, {})), tpls : List(Tpl), root : U64, documents : List({ index : U64, event : Str }), observed_count : U64 }

	new : {} -> Model
	new = |_| { nodes: [{ tag: "root", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] }], statics: [], rows: [], tpls: [], root: 0, documents: [], observed_count: 0 }

	u32 : List(U8), U64 -> U32
	u32 = |b, at| {
		b0 = (b.get(at) ?? crash "short command").to_u32()
		b1 = (b.get(at + 1) ?? crash "short command").to_u32()
		b2 = (b.get(at + 2) ?? crash "short command").to_u32()
		b3 = (b.get(at + 3) ?? crash "short command").to_u32()
		b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
	}

	str : List(U8), U64 -> (Str, U64)
	str = |b, at| {
		n = Dom.u32(b, at).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "short string"
		}
		(Str.from_utf8(bytes) ?? crash "bad utf8", at + 4 + n)
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

	byte : List(U8), U64 -> U8
	byte = |b, at| b.get(at) ?? crash "short command"

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

	node : Model, U64 -> DNode
	node = |dom, i| dom.nodes.get(i) ?? crash "node index"

	set_node : Model, U64, DNode -> Model
	set_node = |{ nodes, statics, rows, tpls, root, documents, observed_count }, i, n| { nodes: nodes.set(i, n) ?? crash "node index", statics, rows, tpls, root, documents, observed_count }

	add_node : Model, DNode -> (Model, U64)
	add_node = |{ nodes, statics, rows, tpls, root, documents, observed_count }, n| ({ nodes: nodes.append(n), statics, rows, tpls, root, documents, observed_count }, nodes.len())

	set_static : Model, U32, U64 -> Model
	set_static = |{ nodes, statics, rows, tpls, root, documents, observed_count }, id, idx| {
		var $s = statics
		while $s.len() <= id.to_u64() {
			$s = $s.append(0)
		}
		{ nodes, statics: $s.set(id.to_u64(), idx + 1) ?? crash "static", rows, tpls, root, documents, observed_count }
	}

	## Bind a row element: its node index, its site (recorded with the id and
	## in the site's row list, so CLEAR can forget the site's rows).
	set_row : Model, U32, U64, U64 -> Model
	set_row = |{ nodes, statics, rows, tpls, root, documents, observed_count }, id, idx, site| {
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
		dom = { nodes, statics: $s.set(id.to_u64(), packed) ?? crash "static", rows: list.set(site, prev.insert(id.to_u64(), {})) ?? crash "row", tpls, root, documents, observed_count }
		Dom.modify(dom, idx, |n| { ..n, ids: n.ids.append(id) })
	}

	## The site of a bound row element (Err for a static node).
	site_of : Model, U32 -> Try(U64, [Static])
	site_of = |dom, id| {
		v = (dom.statics.get(id.to_u64()) ?? 0).shr_zf_wrap(40)
		if (v == 0) Err(Static) else Ok(v - 1)
	}

	empty_node : DNode
	empty_node = { tag: "", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] }

	## Update node i in place (the node is moved out of the list first, so
	## its kid list stays uniquely owned).
	modify : Model, U64, (DNode -> DNode) -> Model
	modify = |{ nodes, statics, rows, tpls, root, documents, observed_count }, i, f| {
		{ list, prev } = nodes.replace(i, Dom.empty_node) ?? crash "node index"
		{ nodes: list.set(i, f(prev)) ?? crash "node index", statics, rows, tpls, root, documents, observed_count }
	}

	bind : Model, U32, U64 -> Model
	bind = |dom, id, idx| Dom.modify(Dom.set_static(dom, id, idx), idx, |n| { ..n, ids: n.ids.append(id) })

	unbind : Model, U32 -> Model
	unbind = |{ nodes, statics, rows, tpls, root, documents, observed_count }, id| {
		packed = statics.get(id.to_u64()) ?? 0
		statics2 = statics.set(id.to_u64(), 0) ?? statics
		site1 = packed.shr_zf_wrap(40)
		if site1 == 0 {
			{ nodes, statics: statics2, rows, tpls, root, documents, observed_count }
		} else {
			site = site1 - 1
			{ list, prev } = rows.replace(site, Dict.empty()) ?? crash "row"
			{ nodes, statics: statics2, rows: list.set(site, prev.remove(id.to_u64())) ?? crash "row", tpls, root, documents, observed_count }
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
		for child in owned.kids {
			$d = Dom.forget_subtree($d, child)
		}
		for id in owned.ids {
			if ($d.statics.get(id.to_u64()) ?? 0).bitwise_and(1099511627775) == i + 1 {
				$d = Dom.unbind($d, id)
			}
		}
		Dom.modify($d, i, |n| { ..n, ids: [] })
	}

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
					{ tag, text, attrs, kids, parent, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed } = p
					kept = match kids.find_last_index(|k| k == i) {
						Ok(pos) => kids.drop_at(pos)
						Err(_) => kids
					}
					{ tag, text, attrs, kids: kept, parent, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed }
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
				{ tag, text, attrs, kids, parent: pp, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed } = p
				kids2 = match before {
					Err(End) => kids.append(i)
					Ok(b) => {
						pos = kids.find_first_index(|k| k == b) ?? crash "insert before a non-child"
						kids.sublist({ start: 0, len: pos }).append(i).concat(kids.sublist({ start: pos, len: kids.len() - pos }))
					}
				}
				{ tag, text, attrs, kids: kids2, parent: pp, rn, hs, ht, ids, props, detach_count, keymaps, shown, shown_intent, pending_toggle, toggle_slot, scroll, observing, observed }
			},
		)
		Dom.modify(d1, i, |n| { ..n, parent: parent + 1 })
	}

	## Place a fresh node by (parent id, before id) as the engine encodes it.
	place : Model, U64, U32, U32 -> Model
	place = |dom, i, parent, before| {
		if before == 0 {
			Dom.insert(dom, Dom.lookup(dom, parent), i, Err(End))
		} else {
			b = Dom.lookup(dom, before)
			bp = Dom.node(dom, b).parent
			if bp == 0 {
				crash "insert before a detached node"
			}
			Dom.insert(dom, bp - 1, i, Ok(b))
		}
	}

	## Parse one template node, creating nodes; returns the index.
	build : Model, List(U8), U64 -> (Model, U64, U64)
	build = |dom, b, at| {
		kind = Dom.byte(b, at)
		if kind == 2 {
			(t, next) = Dom.str(b, at + 1)
			(d1, i) = Dom.add_node(dom, { tag: "", text: t, attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] })
			(d1, i, next)
		} else {
			(tag, a1) = Dom.str(b, at + 1)
			na = Dom.byte(b, a1).to_u64()
			var $at = a1 + 1
			var $attrs = []
			var $k = 0.U64
			while $k < na {
				(name, n1) = Dom.str(b, $at)
				(value, n2) = Dom.str(b, n1)
				if !Dom.bool_attrs.contains(name) or (value != "" and value != "false") {
					$attrs = $attrs.append((name, value))
				}
				$at = n2
				$k = $k + 1
			}
			nk = Dom.byte(b, $at).to_u64()
			$at = $at + 1
			(d1, i) = Dom.add_node(dom, { tag, text: "", attrs: $attrs, kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] })
			var $d = d1
			$k = 0
			while $k < nk {
				(d2, c, next) = Dom.build($d, b, $at)
				$d = Dom.insert(d2, i, c, Err(End))
				$at = next
				$k = $k + 1
			}
			($d, i, $at)
		}
	}

	## Skip one template node.
	skip : List(U8), U64 -> U64
	skip = |b, at| {
		kind = Dom.byte(b, at)
		if kind == 2 {
			Dom.str(b, at + 1).1
		} else {
			(_, a1) = Dom.str(b, at + 1)
			na = Dom.byte(b, a1).to_u64()
			var $at = a1 + 1
			var $k = 0.U64
			while $k < na {
				$at = Dom.str(b, Dom.str(b, $at).1).1
				$k = $k + 1
			}
			nk = Dom.byte(b, $at).to_u64()
			$at = $at + 1
			$k = 0
			while $k < nk {
				$at = Dom.skip(b, $at)
				$k = $k + 1
			}
			$at
		}
	}

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
			path = b.sublist({ start: $at + 2, len: depth })
			$at = $at + 2 + depth
			if kind == 2 {
				(name, next) = Dom.str(b, $at)
				$holes = $holes.append({ kind, path, name, handler: 0, payload_kind: 0, policies: 0, property: 0 })
				$at = next
			} else if kind == 3 {
				hb = Dom.byte(b, $at)
				(ev, next) = Dom.str(b, $at + 1)
				payload_kind = Dom.byte(b, next)
				policies = Dom.u32(b, next + 1)
				Dom.check_listener({ event: ev, kind: payload_kind, policies })
				$holes = $holes.append({ kind, path, name: ev, handler: hb, payload_kind, policies, property: 0 })
				$at = next + 5
			} else if kind == 6 {
				property = Dom.byte(b, $at)
				_ = Dom.property_name(property)
				$holes = $holes.append({ kind, path, name: "", handler: 0, payload_kind: 0, policies: 0, property })
				$at = $at + 1
			} else if kind == 1 or kind == 4 or kind == 5 {
				$holes = $holes.append({ kind, path, name: "", handler: 0, payload_kind: 0, policies: 0, property: 0 })
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

	walk : Model, U64, List(U8) -> U64
	walk = |dom, root, path| {
		var $n = root
		for k in path {
			$n = Dom.node(dom, $n).kids.get(k.to_u64()) ?? crash "template path"
		}
		$n
	}

	## The boolean names have HTML presence semantics; ordinary names retain
	## all text, including the empty string.
	bool_attrs : List(Str)
	bool_attrs = ["disabled", "selected", "readonly", "required", "hidden", "multiple", "open"]

	## Remove an attribute explicitly, without interpreting any text as absence.
	remove_attr_on : Model, U64, Str -> Model
	remove_attr_on = |dom, i, name| Dom.modify(dom, i, |n| { ..n, attrs: n.attrs.keep_if(|(key, _)| key != name), shown: if (n.tag == "dialog" and name == "open") Hidden else n.shown })

	## Apply the presence carried by an attribute command or row operand.
	set_presence_on : Model, U64, Str, [Absent, Present(Str)] -> Model
	set_presence_on = |dom, i, name, presence| match presence {
		Absent => Dom.remove_attr_on(dom, i, name)
		Present(text) => Dom.set_attr_on(dom, i, name, text)
	}

	set_attr_on : Model, U64, Str, Str -> Model
	set_attr_on = |dom, i, name, value| {
		if Dom.bool_attrs.contains(name) and (value == "" or value == "false") {
			return Dom.remove_attr_on(dom, i, name)
		}
		n = Dom.node(dom, i)
		attrs = if (n.attrs.any(|(k, _)| k == name)) n.attrs.map(|(k, v)| if (k == name) (k, value) else (k, v)) else n.attrs.append((name, value))
		Dom.set_node(dom, i, { ..n, attrs, shown: if (n.tag == "dialog" and name == "open" and n.shown == Hidden) Open else n.shown })
	}

	## Only the closed boolean names interpret empty or false text as absence.
	## Ordinary attributes keep both values and explicit removal is separate.
	expect {
		(d1, i) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div" })
		d2 = Dom.set_attr_on(Dom.set_attr_on(d1, i, "alt", ""), i, "checked", "false")
		d3 = Dom.set_attr_on(Dom.set_attr_on(d2, i, "hidden", "true"), i, "hidden", "")
		d4 = Dom.set_attr_on(Dom.set_attr_on(d3, i, "open", "true"), i, "open", "false")
		Dom.node(d4, i).attrs == [("alt", ""), ("checked", "false")]
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

	## A control's property value, including defaults before its first write.
	live_value : DNode, Str -> Str
	live_value = |n, name| n.props.find_first(|(key, _)| key == name).map_ok(|(_, value)| value) ?? if (name == "checked") "false" else if (name == "value" and n.tag == "button") Dom.attr_of(n, "value") else ""

	## Only known payload kinds and policy bits can occur in a declaration.
	## Invalid numbers come from a protocol mismatch, never an app event.
	check_listener : { event : Str, kind : U8, policies : U32 } -> {}
	check_listener = |{ event, kind, policies }| {
		if kind < 1 or kind > 8 {
			crash "executor: unknown payload kind ${kind.to_str()}"
		}
		if kind == 2 and !["change", "drop", "paste"].contains(event) {
			crash "executor: files payload kind on unsupported event ${event}"
		}
		if kind == 3 and !["pointerdown", "pointermove", "pointerup", "pointercancel"].contains(event) {
			crash "executor: pointer payload kind on unsupported event ${event}"
		}
		if policies.bitwise_and(4) != 0 and (kind != 3 or event != "pointerdown") {
			crash "executor: capture policy requires a pointerdown pointer handler"
		}
		if policies.bitwise_and(8) != 0 and !((kind == 3 and event == "pointermove") or kind >= 6) {
			crash "executor: paced policy requires a pointermove pointer handler"
		}
		if policies.bitwise_and(32) != 0 and kind != 8 {
			crash "executor: ahead policy requires a seen observation"
		}
		if kind >= 6 {
			expected = match kind {
				6 => "scroll"
				7 => "size"
				8 => "seen"
				_ => crash "executor: invalid layout kind"
			}
			allowed = if (kind == 8) 40.U32 else 8
			if event != expected or policies.bitwise_and(8) == 0 or policies.bitwise_and(allowed.bitwise_not()) != 0 {
				crash "executor: layout payload requires its matching paced declaration"
			}
		}
		if kind == 5 and !["close", "toggle"].contains(event) {
			crash "executor: open-state payload requires close or toggle"
		}
		if kind == 4 and !["keydown", "keyup"].contains(event) {
			crash "executor: key payload requires keydown or keyup"
		}
		if policies.bitwise_and(16) != 0 and kind != 4 {
			crash "executor: document policy requires a key handler"
		}
		if kind == 4 and policies.bitwise_and(1) != 0 {
			crash "executor: key prevention belongs to its keymap"
		}
		if policies.bitwise_and(0xFFFFFFC0) != 0 {
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
	property_name = |property| match property {
		1 => "value"
		2 => "checked"
		3 => "pointer_zone"
		4 => "keymap_down"
		5 => "keymap_up"
		6 => "shown"
		7 => "popover_shown"
		_ => crash "executor: unknown property index ${property.to_str()}"
	}

	## HTML interprets an input's type without ASCII case. Keep the raw
	## attribute for assertions while applying the browser's file-input rule.
	is_file_input : DNode -> Bool
	is_file_input = |n| n.tag == "input" and Dom.enum_attr(n, "type") == "file"

	## The browser's file-input guard recognizes every ASCII spelling while
	## leaving other input types available for value properties.
	expect ["file", "FILE", "FiLe", "text", "filex"].map(|kind| Dom.is_file_input({ ..Dom.empty_node, tag: "input", attrs: [("type", kind)] })) == [Bool.True, Bool.True, Bool.True, Bool.False, Bool.False]

	## Apply one declared property in stream order, preserving the mirror
	## attribute used by browser update observations. A file input rejects a
	## value where it is applied because its type may change during a turn.
	set_property_on : Model, U64, U8, Str, U32 -> Model
	set_property_on = |dom, i, property, value, command_node| {
		name = Dom.property_name(property)
		if property == 6 or property == 7 {
			n = Dom.node(dom, i)
			_ = Dom.shown_value(property, value)
			if (property == 6 and n.tag != "dialog") or (property == 7 and !["auto", "manual"].contains(Dom.enum_attr(n, "popover"))) {
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
		allowed = if (property == 1) ["input", "textarea", "select", "option"].contains(n.tag) else n.tag == "input"
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

	set_text_on : Model, U64, Str -> Model
	set_text_on = |dom, i, t| {
		n = Dom.node(dom, i)
		Dom.set_node(dom, i, { ..n, text: t })
	}

	## Apply one command batch.
	apply : Model, List(U8) -> Model
	apply = |dom0, b| Dom.apply_ops(dom0, b).0

	op_name : U8 -> Str
	op_name = |op| ["?", "INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORAGE", "TITLE", "REF", "PORT", "SAVE", "PROP", "HPROP", "RELEASE"].get(op.to_u64()) ?? "?"

	## Opcode histogram of a batch, e.g. "SETTEXT=1 ATTR=1".
	describe : List(U8) -> Str
	describe = |ops| {
		var $parts = []
		var $op = 1.U8
		while $op <= 23 {
			n = ops.count_if(|o| o == $op)
			if n > 0 {
				$parts = $parts.append("${Dom.op_name($op)}=${n.to_str()}")
			}
			$op = $op + 1
		}
		Str.join_with($parts, " ")
	}

	## An effect command, decoded independently of the engine.
	FxCmd : [
		Http(U32, Str, Str, List((Str, Str)), Str, U32),
		Get(U32, Str),
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
		Upload(U32, Str, Str, List((Str, Str)), { token : U64, start : U64, len : U64 }, U32),

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
		Fetch(U32, Str, Str, List((Str, Str)), U32),

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

	decode_commands : Model, List(U8), { start : U64, one : Bool } -> { dom : Model, ops : List(U8), fx : List(FxCmd), written : List(U64), values : List((U64, Str)), next : U64 }
	decode_commands = |dom0, b, { start, one }| {
		var $written = []
		var $values = []
		var $fx = []
		var $d = dom0
		var $at = start
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
						$dd = Dom.set_presence_on($dd, target, hole.name, presence)
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
					Dom.set_presence_on($d, target, hole.name, presence)
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
				p = Dom.lookup($d, Dom.u32(b, $at))
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
				{ nodes, statics, rows, tpls, root, documents, observed_count } = $d
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
				$d = { nodes, statics, rows: $r.set(tpl, Dict.empty()) ?? $r, tpls: $t.set(tpl, t) ?? $t, root, documents, observed_count }
			} else if op == 8 or op == 10 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				(s, next) = Dom.str(b, $at + 12)
				$at = next
				fresh = if (op == 8) { tag: s, text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] } else { tag: "", text: s, attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [], ids: [], props: [], detach_count: 0, keymaps: Dict.empty(), shown: Hidden, shown_intent: { dialog: 0, popover: 0 }, pending_toggle: False, toggle_slot: 0, scroll: { top: 0, left: 0 }, observing: 0, observed: [] }
				(d1, i) = Dom.add_node($d, fresh)
				$d = Dom.bind(Dom.place(d1, i, parent, before), nid, i)
			} else if op == 9 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(name, n1) = Dom.str(b, $at + 4)
				(presence, n2) = Dom.attr_presence(b, n1)
				$at = n2
				$written = $written.append(i)
				$d = Dom.set_presence_on($d, i, name, presence)
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
					$at = a3 + 4
					$fx = $fx.append(Http(id, method, url, $hs, body, timeout))
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
					$fx = $fx.append(Upload(id, method, url, $hs, Dom.file_ref(b, $a), Dom.u32(b, $a + 24)))
					$at = $a + 28
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
					$fx = $fx.append(Fetch(id, method, url, $hs, Dom.u32(b, $a)))
					$at = $a + 4
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
				if mode == 1 {
					(v, a2) = Dom.str(b, a1)
					$at = a2
					$fx = $fx.append(Set(key, v))
				} else if mode == 2 {
					$at = a1
					$fx = $fx.append(Remove(key))
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
			} else {
				crash "unknown command ${op.to_str()}"
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

	render : Model, U64 -> Str
	render = |dom, i| {
		n = Dom.node(dom, i)
		if n.tag == "" {
			n.text
		} else {
			attrs = n.attrs.map(|(k, v)| " ${k}=\"${v}\"")
			inner = n.kids.map(|k| Dom.render(dom, k))
			"<${n.tag}${Str.join_with(attrs, "")}>${Str.join_with(inner, "")}</${n.tag}>"
		}
	}

	text_of : Model, U64 -> Str
	text_of = |dom, i| {
		n = Dom.node(dom, i)
		if (n.tag == "") n.text else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
	}

	## Attribute presence is independent of its text: an empty value is present.
	has_attr : DNode, Str -> Bool
	has_attr = |element, name| element.attrs.any(|(key, _)| key == name)

	attr_of : DNode, Str -> Str
	attr_of = |n, name| n.attrs.find_first(|(k, _)| k == name).map_ok(|(_, v)| v) ?? ""

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

	by_attr : Model, Str, Str -> Try(U64, [NotFound])
	by_attr = |dom, name, value| Dom.find(dom, dom.root, |n| Dom.has_attr(n, name) and Dom.attr_of(n, name) == value)

	## Every node (depth-first) whose text content equals `t` and has a handler.
	click_target : Model, U64 -> Try(Target, [NoHandler])
	click_target = |dom, i| Dom.target(dom, i, "click", Bool.True)

	button_with_text : Model, Str -> Try(U64, [NotFound])
	button_with_text = |dom, t| Dom.find(dom, dom.root, |n| n.tag == "button" and n.kids.len() == 1 and (Dom.node(dom, n.kids.get(0) ?? 0)).text == t)

	## A recycled `each` site id starts empty: rows of the site disposed with
	## an ancestor are not unbound by the next site's CLEAR, even when their
	## node ids were reused for static nodes meanwhile.
	expect {
		le32 = |n| [n.bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), 0, 0]
		lstr = |t| le32(t.to_utf8().len().to_u32_wrap()).concat(t.to_utf8())
		elem = |id, tag| [8.U8].concat(le32(id)).concat(le32(0.U32)).concat(le32(0.U32)).concat(lstr(tag))
		tpl_bytes = [1.U8].concat(lstr("li")).concat([0, 0, 0])
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
		dom = Dom.apply(Dom.new({}), cmds)
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
	(d1, parent) = Dom.add_node(Dom.new({}), { ..Dom.empty_node, tag: "div", attrs: [("contenteditable", "TRUE")] })
	(d2, child) = Dom.add_node(d1, { ..Dom.empty_node, tag: "span", attrs: [("contenteditable", "invalid")] })
	dom = Dom.insert(Dom.insert(d2, d2.root, parent, Err(End)), parent, child, Err(End))
	stopped = Dom.set_attr_on(dom, child, "contenteditable", "FALSE")
	false_parent = Dom.set_attr_on(dom, parent, "contenteditable", "FALSE")
	(d3, checkbox) = Dom.add_node(dom, { ..Dom.empty_node, tag: "input", attrs: [("type", "CHECKBOX")] })
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
	actual = Dom.apply_full(dom, bytes)
	actual.fx == [1.U8, 2, 3, 4, 5].map(|mode| Ref({ node: 1, target, action: Focus(mode) })).concat([
		Ref({ node: 1, target, action: IntoView({ block: 0, inline: 1, behavior: 2 }) }),
		Ref({ node: 1, target, action: To({ top: Px(255), left: End, behavior: 1 }) }),
	])
}
