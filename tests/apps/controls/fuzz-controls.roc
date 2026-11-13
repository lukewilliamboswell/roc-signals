app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.Engine
import pf.Dom
import pf.Scm
import pf.SpecRunner
import ControlsApp
import ManyApp
import TopLayerApp

## The engine and the oracle's DOM, driven through the engine directly.
S : { eng : Core.App, dom : Dom.Model, steps : U64 }

start : Engine.Elem(Engine.Root) -> S
start = |view| {
	(a, c) = Core.take_cmds(Core.mount(view), [])
	dom = Dom.apply(Dom.new({}), c)
	settled(a, dom, { eng: a, dom, steps: 0 })
}

## The settle check: a pass over every layer of the engine (on a discarded
## copy) must emit nothing, or the last call left a reader stale.
settled : Core.App, Dom.Model, a -> a
settled = |eng, dom, value|
	match Core.settled(eng) {
		Ok(_) => value
		Err({ cmds, note }) => crash "a reader was left stale: a settle pass over every layer emitted ${Dom.describe(Dom.apply_ops(dom, cmds).1)} ${note}"
	}

## Native tests of focus references and focus/blur events (apps/controls):
## Focus/SelectText/Blur effects resolve their reference at the end of the
## turn into one FOCUS command naming the referenced element; a missing
## reference emits nothing and is counted stale; focus/blur handlers receive
## the control's value as payload. Every call must leave the engine settled:
## a pass over every layer emits nothing (`Core.settled`).

fire! : S, Scm.Loc, Str, Str => (S, List(Dom.FxCmd))
fire! = |s, loc, ev, payload| {
	i = SpecRunner.find(s.dom, loc) ?? crash "no ${Scm.show_loc(loc)}"
	target = Dom.target(s.dom, i, ev, Bool.True) ?? crash "no ${ev} handler on ${Scm.show_loc(loc)}"
	(a, c) = Core.take_cmds(Core.event(s.eng, target.node, target.handler, payload), [])
	(d2, _, fx) = Dom.apply_fx(s.dom, c)
	settled(a, d2, ({ eng: a, dom: d2, steps: s.steps + 1 }, fx))
}

node_of : S, Scm.Loc -> U32
node_of = |s, loc| {
	i = SpecRunner.find(s.dom, loc) ?? crash "no ${Scm.show_loc(loc)}"
	n = Dom.node(s.dom, i)
	n.rn
}

expect_fx! : Str, List(Dom.FxCmd), List(Dom.FxCmd) => {}
expect_fx! = |what, got, want| if (got != want) crash "${what}: ${Str.inspect(got)}, expected ${Str.inspect(want)}" else {}

focus! : {} => Fuzz.Outcome
focus! = |_| {
	s0 = start(ControlsApp.main({}))
	plain = node_of(s0, Label("Plain"))
	upper = node_of(s0, Label("Upper"))
	(s1, f1) = fire!(s0, Role({ role: "button", name: "Focus upper" }), "click", "")
	expect_fx!("focus upper", f1, [Ref({ node: upper, target: Dom.lookup(s0.dom, upper), action: Focus(1) })])
	(s2, f2) = fire!(s1, Role({ role: "button", name: "Select plain" }), "click", "")
	expect_fx!("select plain", f2, [Ref({ node: plain, target: Dom.lookup(s1.dom, plain), action: Focus(3) })])
	(s3, f3) = fire!(s2, Role({ role: "button", name: "Blur plain" }), "click", "")
	expect_fx!("blur plain", f3, [Ref({ node: plain, target: Dom.lookup(s2.dom, plain), action: Focus(2) })])
	stale0 = Core.fx_stats(s3.eng).stale
	(s4, f4) = fire!(s3, Role({ role: "button", name: "Focus missing" }), "click", "")
	expect_fx!("missing ref", f4, [])
	if Core.fx_stats(s4.eng).stale != stale0 + 1 {
		crash "missing ref not counted stale"
	}
	(s5, _) = fire!(s4, Label("Plain"), "focus", "hello world")
	(s6, _) = fire!(s5, Label("Plain"), "blur", "hello there")
	log = Dom.text_of(s6.dom, SpecRunner.find(s6.dom, TestId("log")) ?? crash "no log")
	if log != "focus:hello world|blur:hello there" {
		crash "focus/blur payloads: ${log}"
	}
	Fuzz.keep
}

## More than 4,095 each sites (5,001 at mount; 5,000 rows each with a
## nested each), shrunk and regrown with new keys so site and node ids are
## recycled; clicks deep in the newest rows must route to the right row.
many! : U64 => Fuzz.Outcome
many! = |n| {
	s0 = start(ManyApp.main(n))
	click! = |s, loc| fire!(s, loc, "click", "").0
	log = |s| Dom.text_of(s.dom, SpecRunner.find(s.dom, TestId("log")) ?? crash "no log")
	s1 = click!(s0, Label("g0r4999-b"))
	if log(s1) != "g0r4999-b" {
		crash "first click: ${log(s1)}"
	}
	s2 = click!(click!(s1, Role({ role: "button", name: "Shrink" })), Role({ role: "button", name: "Grow" }))
	match SpecRunner.find(s2.dom, Label("g0r0-a")) {
		Ok(_) => crash "old rows still present"
		Err(_) => {}
	}
	s3 = click!(click!(s2, Label("g1r4999-a")), Label("g1r0-b"))
	if log(s3) != "g0r4999-b|g1r4999-a|g1r0-b" {
		crash "after regrow: ${log(s3)}"
	}
	Fuzz.keep
}

## Generated reorder, disposal, recreation and rename histories are checked
## against a reference model of which row owns each address. The runner
## applies FOCUS commands, so each step checks the focused element, as well
## as propagation and command counters, rather than only an emitted command.
reference_focus! : List(U8) => Fuzz.Outcome
reference_focus! = |events| {
	program = Core.driver(ControlsApp.program)
	var $s = SpecRunner.start(program, { name: "reference history", setup: [], steps: [] }) ?? crash "reference history did not mount"
	var $has_a = True
	var $names = PerRow
	var $selected = "a"
	for event in events {
		button = |name| Role({ role: "button", name })
		operation = event % 11
		action = match operation {
			0 => "Focus row a"
			1 => "Focus row b"
			2 => "Reverse reference rows"
			3 => "Remove row a"
			4 => "Restore reference rows"
			5 => "Use selected reference"
			6 => "Select row b"
			7 => "Clear reference names"
			8 => "Focus current row"
			9 => "Focus empty name"
			_ => ""
		}
		expected = match operation {
			0 if $has_a and $names == PerRow => Label("Row a")
			1 if $names == PerRow => Label("Row b")
			8 if $names == Selected and ($selected == "b" or $has_a) => Label("Row ${$selected}")
			10 => Label("Row b")
			_ => button(action)
		}
		loc = if (operation == 10) Label("Row b") else button(action)
		$s = SpecRunner.one(program, $s, Click(loc)) ?? crash "reference history: click failed on ${Scm.show_loc(loc)}"
		focused = SpecRunner.find($s.dom, expected) ?? crash "reference history: expected target missing"
		if $s.focused != focused + 1 {
			crash "reference history: ${Scm.show_loc(loc)} should focus ${Scm.show_loc(expected)}"
		}
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => crash "reference history: ${message}"
		}
		match SpecRunner.check_counters($s) {
			Ok(_) => {}
			Err(message) => crash "reference history: ${message}"
		}
		match operation {
			3 => {
				$has_a = False
			}
			4 => {
				$has_a = True
			}
			5 => {
				$names = Selected
			}
			6 => {
				$selected = "b"
			}
			7 => {
				$names = Unnamed
			}
			_ => {}
		}
	}
	Fuzz.keep
}

## Generated presence, reorder, removal and recreation histories must retain
## exactly the model's attributes, including present empty text. Every turn
## also checks propagation and the command work counters.
attribute_presence! : List(U8) => Fuzz.Outcome
attribute_presence! = |events| {
	program = Core.driver(ControlsApp.program)
	var $s = SpecRunner.start(program, { name: "attribute history", setup: [], steps: [] }) ?? crash "attribute history did not mount"
	var $presence = Absent
	var $has_a = True
	for event in events {
		operation = event % 6
		action = match operation {
			0 => "Empty attribute"
			1 => "Text attribute"
			2 => "Absent attribute"
			3 => "Reverse attribute rows"
			4 => "Remove attribute row"
			_ => "Restore attribute rows"
		}
		match operation {
			0 => {
				$presence = Present("")
			}
			1 => {
				$presence = Present("named")
			}
			2 => {
				$presence = Absent
			}
			4 => {
				$has_a = False
			}
			5 => {
				$has_a = True
			}
			_ => {}
		}
		$s = SpecRunner.one(program, $s, Click(Role({ role: "button", name: action }))) ?? crash "attribute history: click failed"
		for id in ["attribute-plain", "attribute-row-b"].concat(if ($has_a) ["attribute-row-a"] else []) {
			i = SpecRunner.find($s.dom, TestId(id)) ?? crash "attribute history: missing ${id}"
			got = match SpecRunner.attr_value($s.dom, i, "title") {
				Ok(value) => Present(value)
				Err(Absent) => Absent
			}
			if got != $presence {
				crash "attribute history: ${id} has ${Str.inspect(got)}, expected ${Str.inspect($presence)}"
			}
		}
		if !$has_a and SpecRunner.find($s.dom, TestId("attribute-row-a")).is_ok() {
			crash "attribute history: removed row remains"
		}
		match SpecRunner.check_settled(program, $s) {
			Ok(_) => {}
			Err(message) => crash "attribute history: ${message}"
		}
		match SpecRunner.check_counters($s) {
			Ok(_) => {}
			Err(message) => crash "attribute history: ${message}"
		}
	}
	Fuzz.keep
}

## A pointer session is checked against a small input-side model: only one
## newest move waits during a hold, an up delivers it before itself, and an
## unchanged or released frame creates no extra move. Every accepted turn
## also passes the engine's settle check and command-counter oracle.
PointerCounts : { downs : U64, moves : U64, ups : U64, last : Str }

pointer_counts : PointerCounts
pointer_counts = { downs: 0, moves: 0, ups: 0, last: "" }

pointer_view : {} -> Engine.Elem(Engine.Root)
pointer_view = |{}| Engine.state(
	pointer_counts,
	|state| Engine.element(
		"div",
		[],
		[
			Engine.element(
				"div",
				[
					Engine.test_id("grip"),
					Engine.prop(Engine.Prop.pointer_zone, "grip"),
					Engine.on_pointer_capture(state.set_value(|held, pointer| { ..held, downs: held.downs + 1, last: pointer_place(pointer) })),
					Engine.on_pointer_paced(state.set_value(|held, pointer| { ..held, moves: held.moves + 1, last: pointer_place(pointer) })),
					Engine.on_pointer(Up, state.set_value(|held, pointer| { ..held, ups: held.ups + 1, last: pointer_place(pointer) })),
				],
				[],
			),
			Engine.element("div", [Engine.test_id("a"), Engine.prop(Engine.Prop.pointer_zone, "a")], []),
			Engine.element("div", [Engine.test_id("b"), Engine.prop(Engine.Prop.pointer_zone, "b")], []),
			Engine.element("p", [Engine.test_id("counts")], [Engine.text_s(state.signal().map(Str.inspect))]),
			Engine.element("button", [Engine.on_click(state.update(|_| pointer_counts))], [Engine.text("Reset")]),
		],
	),
)

pointer_place : Engine.Pointer -> Str
pointer_place = |pointer| match pointer.at {
	Outside => "outside"
	In({ zone, x, y }) => "${zone}:${x.to_str()}:${y.to_str()}"
}

pointer_history! : List(U8) => Fuzz.Outcome
pointer_history! = |events| {
	program = Core.driver(Engine.program(|| pointer_view({})))
	var $state = SpecRunner.start(program, { name: "pointer history", setup: [], steps: [] }) ?? crash "pointer history: mount failed"
	var $expected = pointer_counts
	var $down = False
	var $held = False
	var $pending = Quiet
	var $replaced = 0.U64
	for event in events {
		x = (event % 101).to_u16()
		y = 100 - x
		zone = if (event.bitwise_and(8) == 0) "a" else "b"
		point : Scm.PointerPlace
		point = { target: TestId(zone), at: Percent({ x, y }), id: 1 }
		last = "${zone}:${(x * 100).to_str()}:${(y * 100).to_str()}"
		op = match event % 5 {
			0 if !$down => {
				$down = True
				$expected = { ..$expected, downs: $expected.downs + 1, last: "grip:5000:5000" }
				PointerDown({ target: TestId("grip"), at: Centre, id: 1, kind: Mouse, button: Main, modifiers: 0 })
			}
			1 | 4 if $down => {
				if $held {
					match $pending {
						MoveAt(_) => {
							$replaced = $replaced + 1
						}
						Quiet => {}
					}
					$pending = MoveAt(last)
				} else {
					$expected = { ..$expected, moves: $expected.moves + 1, last }
				}
				PointerMove(point)
			}
			2 => {
				$held = !$held
				if $held {
					HoldReports
				} else {
					match $pending {
						MoveAt(place) => {
							$expected = { ..$expected, moves: $expected.moves + 1, last: place }
						}
						Quiet => {}
					}
					$pending = Quiet
					ReleaseReports
				}
			}
			3 if $down => {
				match $pending {
					MoveAt(_) => {
						$expected = { ..$expected, moves: $expected.moves + 1 }
					}
					Quiet => {}
				}
				$pending = Quiet
				$down = False
				$expected = { ..$expected, ups: $expected.ups + 1, last }
				PointerUp(point)
			}
			4 if !$down => {
				$expected = pointer_counts
				Click(Role({ role: "button", name: "Reset" }))
			}
			_ => ExpectReportsReplaced($replaced)
		}
		$state = SpecRunner.one(program, $state, op) ?? crash "pointer history: ${Str.inspect(op)} failed"
		$state = SpecRunner.one(program, $state, ExpectText(TestId("counts"), Str.inspect($expected))) ?? crash "pointer history: counters differ from the input model"
		$state = SpecRunner.one(program, $state, ExpectReportsReplaced($replaced)) ?? crash "pointer history: replacement count differs"
		match SpecRunner.check_settled(program, $state) {
			Ok(_) => {}
			Err(message) => crash "pointer history: ${message}"
		}
		match SpecRunner.check_counters($state) {
			Ok(_) => {}
			Err(message) => crash "pointer history: ${message}"
		}
	}
	if $down {
		match $pending {
			MoveAt(_) => {
				$expected = { ..$expected, moves: $expected.moves + 1 }
			}
			Quiet => {}
		}
		$pending = Quiet
		$expected = { ..$expected, ups: $expected.ups + 1, last: "grip:5000:5000" }
		$state = SpecRunner.one(program, $state, PointerUp({ target: TestId("grip"), at: Centre, id: 1 })) ?? crash "pointer history: final release failed"
	}
	if $held {
		$state = SpecRunner.one(program, $state, ReleaseReports) ?? crash "pointer history: final frame failed"
	}
	$state = SpecRunner.one(program, $state, ExpectText(TestId("counts"), Str.inspect($expected))) ?? crash "pointer history: final counters differ"
	match SpecRunner.check_settled(program, $state) {
		Ok(_) => {}
		Err(message) => crash "pointer history: final ${message}"
	}
	Fuzz.keep
}

## A reorder may re-show only the live shown controls below the rows it moved.
## The input-side model supplies those controls; the independent decoder supplies
## actual command targets. Hidden controls and retired/reused ids are never eligible.
check_moved_shown : Dom.Model, { commands : List(U8), live : List(U64) } -> {}
check_moved_shown = |before, { commands, live }| {
	var $dom = before
	var $at = 0.U64
	var $moved = []
	var $shown = []
	while $at < commands.len() {
		offset = $at
		decoded = Dom.apply_next($dom, commands, offset)
		if decoded.ops == [4] {
			$moved = $moved.append(
				Dom.lookup(
					$dom,
					Dom.u32(
						commands,
						offset + if offset == 0 {
							2
						} else {
							1
						},
					),
				),
			)
		}
		for effect in decoded.fx {
			match effect {
				Shown(show) => {
					if !live.contains(show.target) or $shown.contains(show.target) {
						crash "top layer: MOVE re-show names a hidden, retired or repeated control"
					}
					$shown = $shown.append(show.target)
				}
				_ => {}
			}
		}
		$dom = decoded.dom
		$at = decoded.next
	}
	wanted = live.keep_if(|target| $moved.any(|root| has_ancestor(before, { target, root })))
	if $shown.len() != wanted.len() or !$shown.all(|target| wanted.contains(target)) {
		crash "top layer: MOVE did not re-show exactly its live shown descendants"
	}
	{}
}

## Command addresses are resolved once; ancestry here is only the test oracle's tree.
has_ancestor : Dom.Model, { target : U64, root : U64 } -> Bool
has_ancestor = |dom, { target, root }| {
	var $at = target
	while $at != root {
		parent = Dom.node(dom, $at).parent
		if parent == 0 {
			return False
		}
		$at = parent - 1
	}
	True
}

## Generated top-layer sessions use only actionable fixture controls. Expected
## focus comes from browser contracts: showing a dialog focuses its first control
## (or the dialog); closing restores a surviving visible opener, disposal does not.
## Sibling/modal showing hides an auto popover without restoring its opener;
## focus in that hidden content falls back to body (real Chrome contract). Clicking an already
## open popover's outside opener light-dismisses it before its queued echo.
## Non-modal row dialogs
## stay open through insertion; moved modals are re-shown and refocus their first
## control. A moved modal loses its old opener; close and dismissal then leave
## focus on body. Unmoved closes restore the still-visible opener.
## The finite fixture has fewer than sixteen native callbacks per generated action.
top_layer_history : List(U8) -> {}
top_layer_history = |events| {
	base = Core.driver(Engine.program(|| TopLayerApp.view({})))
	button = |name| Role({ role: "button", name })
	var $state = SpecRunner.mount_in(base, {})
	var $modal = NoModal
	var $opener = button("Open modal")
	var $page_has_opener = True
	var $rows = ["a", "b"]
	var $row_open = False
	var $row_opener_lost = False
	var $popover = NoPopover
	var $popover_opener = button("Open auto A")
	var $popover_has_opener = True
	var $scrolls = 0.U64
	var $stale = 0.U64
	for event in events {
		var $name = ""
		var $dismiss = False
		var $focus = []
		var $no_focus = False
		var $reorder = False
		match $modal {
			PageModal => {
				$dismiss = event % 2 == 1
				$name = "Close modal"
				$focus = if $page_has_opener {
					[$opener]
				} else {
					[]
				}
				$no_focus = !$page_has_opener
				$modal = NoModal
			}
			RowModal => match event % 4 {
				0 => {
					$name = "Reverse modal rows"
					$rows = $rows.fold([], |out, key| [key].concat(out))
					$focus = [button($name)]
					$reorder = True
				}
				1 => {
					$name = "Dispose modal rows"
					$rows = []
					$modal = NoModal
					$no_focus = True
				}
				_ => {
					$name = "Close row modal"
					$dismiss = event % 4 == 3
					$modal = NoModal
					$focus = if $row_opener_lost {
						[]
					} else {
						[button("Open row modal")]
					}
					$no_focus = $row_opener_lost
				}
			}
			NoModal => {
				# Every outside click light-dismisses an auto popover; the two
				# inside buttons instead exercise native sibling/modal hiding.
				operation = event % 16
				previous_popover = $popover
				$popover = NoPopover
				match operation {
					0 => {
						$name = "Open modal"
						$opener = button($name)
						$page_has_opener = True
						$modal = PageModal
						$focus = [Label("Modal first")]
					}
					1 => {
						$dismiss = True
						$focus = if previous_popover == NoPopover {
							[]
						} else {
							if $popover_has_opener {
								[$popover_opener]
							} else {
								[]
							}
						}
						$no_focus = previous_popover != NoPopover and !$popover_has_opener
					}
					2 => {
						$name = "Open row dialogs"
						$focus = if !$row_open and !$rows.is_empty() {
							[TestId("dialog-${$rows.last() ?? crash "top layer: row order"}")]
						} else [button($name)]
						$row_open = True
					}
					3 => {
						$name = "Reverse shown rows"
						$rows = $rows.fold([], |out, key| [key].concat(out))
						$focus = [button($name)]
						$reorder = True
					}
					4 => {
						$name = "Remove shown rows"
						$rows = []
						$row_open = False
					}
					5 => {
						$name = "Restore shown rows"
						$focus = if $rows.is_empty() and $row_open {
							[TestId("dialog-b")]
						} else [button($name)]
						$rows = ["a", "b"]
					}
					6 => {
						$name = "Scroll into target"
						$scrolls = $scrolls + 1
						$focus = [button("Target")]
					}
					7 => {
						$name = "Scroll to target"
						$scrolls = $scrolls + 1
					}
					8 => {
						$name = "Open auto A"
						$popover_opener = button($name)
						$popover_has_opener = True
						$popover = if previous_popover == AutoA {
							NoPopover
						} else {
							AutoA
						}
					}
					9 => {
						$name = if previous_popover == AutoA {
							"Open B from A"
						} else "Open auto B"
						$popover_opener = button($name)
						$popover_has_opener = previous_popover != AutoA
						$focus = if $popover_has_opener {
							[$popover_opener]
						} else {
							[]
						}
						$no_focus = !$popover_has_opener
						$popover = if previous_popover == AutoB {
							NoPopover
						} else {
							AutoB
						}
					}
					10 => {
						$name = if previous_popover == AutoB {
							"Open modal from B"
						} else "Open modal"
						$opener = button($name)
						$page_has_opener = previous_popover != AutoB
						$modal = PageModal
						$focus = [Label("Modal first")]
					}
					11 => {
						$name = "Scroll missing"
						$stale = $stale + 1
					}
					12 => {
						$name = "Focus target in place"
						$focus = [button("Target")]
					}
					13 if !$rows.is_empty() => {
						$name = "Open row modal"
						$row_opener_lost = False
						$modal = RowModal
						$focus = [button("Reverse modal rows")]
					}
					_ => {
						$name = "Outside"
					}
				}
				if !$dismiss and !$no_focus and $focus.is_empty() {
					$focus = [button($name)]
				}
			}
		}
		before = $state.dom
		live = if $reorder {
			rows_live = if $row_open {
				$rows.map(|key| SpecRunner.find(before, TestId("dialog-${key}")) ?? crash "top layer: missing live row")
			} else []
			if $modal == RowModal {
				rows_live.append(SpecRunner.find(before, TestId("modal-row-a")) ?? crash "top layer: missing row modal")
			} else rows_live
		} else []
		program = {
			..base,
			event: |inst, buf, wbuf, node, handler, payload| {
				(next, commands, work) = (base.event)(inst, buf, wbuf, node, handler, payload)
				if $reorder {
					check_moved_shown(before, { commands, live })
				}
				(next, commands, work)
			},
		}
		op = if ($dismiss) Dismiss else Click(button($name))
		$state = SpecRunner.one(program, $state, op) ?? crash "top layer: action ${Str.inspect(op)} failed"
		if $modal == RowModal and $reorder {
			# MOVE is an observable browser detach. Follow only the modal's
			# ancestor path, never the runner's opener or focus bookkeeping.
			var $ancestor = SpecRunner.find(before, TestId("modal-row-a")) ?? crash "top layer: row modal missing before move"
			while True {
				if Dom.node(before, $ancestor).detach_count != Dom.node($state.dom, $ancestor).detach_count {
					$row_opener_lost = True
				}
				parent = Dom.node(before, $ancestor).parent
				if parent == 0 {
					break
				}
				$ancestor = parent - 1
			}
		}
		var $tasks = 0.U64
		while !$state.browser.ui_tasks.is_empty() {
			if $tasks >= 16 {
				crash "top layer test program exceeded its finite UI-task bound"
			}
			$state = SpecRunner.drain_focus(program, SpecRunner.deliver_ui(program, { ..$state, draining: False, turns: 0 }))
			$tasks = $tasks + 1
			match SpecRunner.check_settled(base, $state) {
				Ok(_) => {}
				Err(message) => crash "top layer callback: ${message}"
			}
		}
		if $no_focus {
			if $state.focused != 0 {
				crash "top layer: ${Str.inspect(op)} retained focus ${$state.focused.to_str()} instead of body"
			}
		} else if !$focus.is_empty() {
			if !$focus.any(|loc| (SpecRunner.find($state.dom, loc) ?? crash "top layer: expected focus target missing") + 1 == $state.focused) {
				crash "top layer: action ${Str.inspect(op)} focused ${$state.focused.to_str()}, expected ${Str.inspect($focus)}"
			}
		}
		$state = SpecRunner.one(base, $state, ExpectShown(Label("Modal"), if ($modal == PageModal) Modal else Hidden)) ?? crash "top layer: modal differs from model"
		$state = SpecRunner.one(base, $state, ExpectShown(Label("Auto A"), if ($popover == AutoA) Popover else Hidden)) ?? crash "top layer: auto A differs from model"
		$state = SpecRunner.one(base, $state, ExpectShown(Label("Auto B"), if ($popover == AutoB) Popover else Hidden)) ?? crash "top layer: auto B differs after ${Str.inspect(op)} from ${Str.inspect(events)}"
		$state = SpecRunner.one(base, $state, ExpectScrolls($scrolls)) ?? crash "top layer: scroll count differs from model"
		if Core.fx_stats($state.inst).stale != $stale {
			crash "top layer: stale-reference count differs from model"
		}
		for key in ["a", "b"] {
			loc = TestId("dialog-${key}")
			$state = SpecRunner.one(base, $state, if ($rows.contains(key)) ExpectShown(loc, if ($row_open) Open else Hidden) else ExpectAbsent(loc)) ?? crash "top layer: keyed dialog differs from model"
			modal_loc = TestId("modal-row-${key}")
			$state = SpecRunner.one(base, $state, if ($rows.contains(key)) ExpectShown(modal_loc, if ($modal == RowModal and key == "a") Modal else Hidden) else ExpectAbsent(modal_loc)) ?? crash "top layer: keyed modal differs from model"
		}
		match SpecRunner.check_settled(base, $state) {
			Ok(_) => {}
			Err(message) => crash "top layer: ${message}"
		}
		match SpecRunner.check_counters($state) {
			Ok(_) => {}
			Err(message) => crash "top layer: ${message}"
		}
	}
	{}
}

## Popover sibling/modal hiding, focus restoration and missing references share a session.
expect top_layer_history([8, 9, 10, 1, 11, 12, 0, 0, 8, 1, 9, 1]) == {}

## Shown and hidden rows move, dispose, reuse their ids, reopen, and move a modal.
expect top_layer_history([2, 3, 4, 5, 2, 3, 13, 0, 2, 13, 1, 5, 2, 3, 6, 7, 11]) == {}

## Every byte drives a valid action from the state left by its predecessors.
expect {
	var $bytes = []
	for byte in 0.U16..<256 {
		$bytes = $bytes.append(byte.to_u8_wrap())
	}
	top_layer_history($bytes) == {}
}

## Mixed byte histories exercise every action after varied live and retired scopes.
expect {
	for seed in 0.U16..<32 {
		var $bytes = []
		for index in 0.U16..<64 {
			$bytes = $bytes.append((seed * 73 + index * 31 + index * index).to_u8_wrap())
		}
		top_layer_history($bytes)
	}
	True
}

Input : { mode : U8, pad : U8, events : List(U8) }

target = Fuzz.target_with!({
	name: "controls",
	examples: [
		Fuzz.example({ name: "focus", revision: "2", make: || { mode: 0, pad: 0, events: [] } }),
		Fuzz.example({ name: "many-sites", revision: "2", make: || { mode: 1, pad: 0, events: [] } }),
		Fuzz.example({ name: "attribute-history", revision: "1", make: || { mode: 3, pad: 0, events: [0, 0, 1, 3, 4, 2, 5, 0, 4, 1, 5, 2] } }),
		Fuzz.example({ name: "reference-history", revision: "1", make: || { mode: 2, pad: 0, events: [0, 2, 0, 3, 0, 4, 0, 5, 8, 6, 8, 2, 8, 7, 8, 9, 10] } }),
		Fuzz.example({ name: "top-layer-history", revision: "2", make: || { mode: 5, pad: 0, events: [8, 9, 10, 1, 11, 2, 3, 4, 5, 2, 3, 13, 0, 2, 13, 1, 5, 2, 3, 6, 7, 12, 11, 0, 0] } }),
		Fuzz.example({ name: "top-layer-openers", revision: "1", make: || { mode: 5, pad: 0, events: [8, 9, 10, 1, 11, 0, 0, 9, 1, 8, 1] } }),
		Fuzz.example({ name: "top-layer-row-lifetimes", revision: "1", make: || { mode: 5, pad: 0, events: [13, 2, 13, 3, 2, 3, 4, 5, 2, 3, 13, 0, 1, 5, 2, 3, 11, 12] } }),
		Fuzz.example({ name: "pointer-reports", revision: "1", make: || { mode: 4, pad: 0, events: [0, 2, 1, 4, 1, 3, 2, 0, 1, 3, 4] } }),
	],
	generator: {
		mode: |arbitrary| {
			next = Fuzz.u8(arbitrary)
			{ state: next.state, value: 2 + next.value % 4 }
		},
		pad: Fuzz.constant(0),
		events: Fuzz.list(Fuzz.u8, 64),
	}.Fuzz,
	test!: |{ mode, pad, events }| match mode {
		0 => focus!({})
		1 => many!(5000 + pad.to_u64())
		2 => reference_focus!(events)
		3 => attribute_presence!(events)
		4 => pointer_history!(events)
		_ => {
			top_layer_history(events)
			Fuzz.keep
		}
	},
	show: Str.inspect,
})
