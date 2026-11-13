import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import PointerApp
import TopLayerApp
import RawInputApp
import RenderingApp
import TypedControlsApp

## Controlled inputs, focus and containment test app.
## - "Plain": a controlled text input whose state is exactly what was typed.
## - "Upper": a controlled text input whose state is the typed text upper-cased
##   (the engine's value differs from what the user typed).
## Both carry focus references; buttons ask for Focus / SelectText / Blur
## through an effect site, and focus/blur handlers on "Plain" log their
## payloads. The log is rendered for the tests.
## - "Two handlers" and "Two row handlers" mount an element with two `click`
##   handlers, plainly or in an `each` row template: a contract error at
##   mount (`tests/browser/controls-browser.mjs` observes it).
ControlsApp := [].{

	## Empty text and absence are different observations, in plain blocks and
	## keyed row templates. The controls also exercise row reuse and disposal.
	attributes : {} -> Elem(ctx)
	attributes = |_props| Engine.state(
		{ presence: Absent, rows: ["a", "b"] },
		|attributes| Engine.element(
			"section",
			[],
			[
				Html.button("Empty attribute", [], attributes.update(|s| { ..s, presence: Present("") })),
				Html.button("Text attribute", [], attributes.update(|s| { ..s, presence: Present("named") })),
				Html.button("Absent attribute", [], attributes.update(|s| { ..s, presence: Absent })),
				Html.button("Reverse attribute rows", [], attributes.update(|s| { ..s, rows: s.rows.fold([], |reversed, key| [key].concat(reversed)) })),
				Html.button("Remove attribute row", [], attributes.update(|s| { ..s, rows: s.rows.keep_if(|key| key != "a") })),
				Html.button("Restore attribute rows", [], attributes.update(|s| { ..s, rows: ["a", "b"] })),
				Engine.element("img", [Engine.test_id("attribute-plain"), Engine.attr("alt", ""), Engine.attr_presence("title", attributes.signal().map(|s| s.presence))], []),
				Engine.each(
					attributes.signal().map(|s| s.rows),
					|key| key,
					|row| Engine.element(
						"div",
						[
							Engine.test_id_s(row.key().map(|key| "attribute-row-${key}")),
							Engine.attr("aria-label", ""),
							Engine.attr_presence("title", attributes.lift_row().signal().map(|s| s.presence)),
						],
						[],
					),
				),
			],
		),
	)

	## References follow row keys and selection without changing event routing.
	## The fault buttons deliberately exercise duplicate names and a focus
	## feedback loop; ordinary specs never press them.
	references : {} -> Elem(ctx)
	references = |_props| Engine.state(
		{ rows: ["a", "b"], selected: "a", names: PerRow, requests: Engine.outbox({}), log: "", duplicate: False },
		|references| Engine.element(
			"section",
			[],
			[
				Html.button("Focus row a", [], references.update(|s| { ..s, requests: s.requests.post("row-a") })),
				Html.button("Focus row b", [], references.update(|s| { ..s, requests: s.requests.post("row-b") })),
				Html.button("Focus current row", [], references.update(|s| { ..s, requests: s.requests.post("current") })),
				Html.button("Focus empty name", [], references.update(|s| { ..s, requests: s.requests.post("") })),
				Html.button("Focus paragraph", [], references.update(|s| { ..s, requests: s.requests.post("paragraph") })),
				Html.button("Reverse reference rows", [], references.update(|s| { ..s, rows: s.rows.fold([], |reversed, key| [key].concat(reversed)) })),
				Html.button("Remove row a", [], references.update(|s| { ..s, rows: s.rows.keep_if(|key| key != "a") })),
				Html.button("Restore reference rows", [], references.update(|s| { ..s, rows: ["a", "b"] })),
				Html.button("Use selected reference", [], references.update(|s| { ..s, names: Selected })),
				Html.button("Select row b", [], references.update(|s| { ..s, selected: "b" })),
				Html.button("Clear reference names", [], references.update(|s| { ..s, names: Unnamed })),
				Engine.each(
					references.signal().map(|s| s.rows),
					|key| key,
					|row| Engine.element(
						"button",
						[
							Engine.attr("type", "button"),
							Html.aria_label_s(row.key().map(|key| "Row ${key}")),
							Engine.ref_s(
								row.key().map2(
									references.lift_row().signal(),
									|key, s| match s.names {
										PerRow => "row-${key}"
										Selected => if (key == s.selected) "current" else ""
										Unnamed => ""
									},
								),
							),
							Engine.on_click(references.lift_row().update_by(row.key(), |s, key| { ..s, log: key })),
						],
						[Engine.text_s(row.key())],
					),
				),
				Html.p_s(references.signal().map(|s| s.log), [Engine.test_id("reference-log"), Engine.ref("paragraph")]),
				Html.button("Duplicate references", [], references.update(|s| { ..s, duplicate: True })),
				Engine.when(
					references.signal().map(|s| s.duplicate),
					|| Engine.element(
						"div",
						[],
						[
							Engine.element("input", [Engine.ref("duplicate")], []),
							Engine.element("input", [Engine.ref("duplicate")], []),
						],
					),
					|| Engine.text(""),
				),
				Html.button("Start focus loop", [], references.update(|s| { ..s, requests: s.requests.post("loop-left") })),
				Engine.element("input", [Html.aria_label("Loop left"), Engine.ref("loop-left"), Html.on_focus(references.update(|s| { ..s, requests: s.requests.post("loop-right") }))], []),
				Engine.element("input", [Html.aria_label("Loop right"), Engine.ref("loop-right"), Html.on_focus(references.update(|s| { ..s, requests: s.requests.post("loop-left") }))], []),
				Engine.on_post(references.signal().map(|s| s.requests), |name| [Engine.command(Focus(name))], Engine.ignore({})),
			],
		),
	)

	S : { plain : Str, upper : Str, log : List(Str), ask : { serial : U64, req : [None, F(Str), B(Str), Sel(Str)] }, rows : List(Str), twice : [Neither, OnElement, InRow] }

	Ctx : In(Root, S)

	upper_ascii : Str -> Str
	upper_ascii = |s| {
		var $b = []
		for c in s.iter_utf8() {
			$b = $b.append(if (c >= 97 and c <= 122) c - 32 else c)
		}
		Str.from_utf8($b) ?? s
	}

	log : S, Str -> S
	log = |s, line| { ..s, log: s.log.append(line) }

	ask : S, [None, F(Str), B(Str), Sel(Str)] -> S
	ask = |s, req| { ..s, ask: { serial: s.ask.serial + 1, req } }

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| Engine.element(
		"div",
		[],
		[
			ControlsApp.references({}),
			ControlsApp.attributes({}),
			Html.text_input(
				Engine.const("Plain"),
				"text",
				st.signal().map(|s| s.plain),
				[
					Engine.ref("plain"),
					Engine.on("focus", st.set_value(|s, v| ControlsApp.log(s, "focus:${v}"))),
					Engine.on("blur", st.set_value(|s, v| ControlsApp.log(s, "blur:${v}"))),
				],
				st.set_value(|s, v| { ..s, plain: v }),
			),
			Html.text_input(Engine.const("Upper"), "text", st.signal().map(|s| s.upper), [Engine.ref("upper")], st.set_value(|s, v| { ..s, upper: ControlsApp.upper_ascii(v) })),
			Html.button("Focus upper", [], st.update(|s| ControlsApp.ask(s, F("upper")))),
			Html.button("Select plain", [], st.update(|s| ControlsApp.ask(s, Sel("plain")))),
			Html.button("Blur plain", [Engine.on_with("mousedown", { prevent: True }, Engine.does([]))], st.update(|s| ControlsApp.ask(s, B("plain")))),
			Html.button("Focus missing", [], st.update(|s| ControlsApp.ask(s, F("nowhere")))),
			Engine.watch_changes(
				st.signal().map(|s| s.ask),
				|a| match a.req {
					F(n) => [Engine.command(Focus(n))]
					B(n) => [Engine.command(Blur(n))]
					Sel(n) => [Engine.command(SelectText(n))]
					None => []
				},
				Engine.ignore({}),
			),

			## Containment: "Duplicate row" appends an existing key (a contract
			## error: duplicate keys are errors, not aliases).
			Html.button("Add row", [], st.update(|s| { ..s, rows: s.rows.append("r${s.rows.len().to_str()}") })),
			Html.button("Duplicate row", [], st.update(|s| { ..s, rows: s.rows.append("r0") })),
			Engine.element("ul", [Engine.test_id("rows")], [Engine.each(st.signal().map(|s| s.rows), |r| r, |row| Engine.element("li", [], [Engine.text_s(row.key())]))]),

			## Containment: two handlers for one event on one element (a
			## contract error at mount, never a silently dropped listener).
			Html.button("Two handlers", [], st.update(|s| { ..s, twice: OnElement })),
			Html.button("Two row handlers", [], st.update(|s| { ..s, twice: InRow })),
			Engine.when(
				st.signal().map(|s| s.twice == OnElement),
				|| Engine.element("button", [Engine.on_click(st.update(|s| ControlsApp.log(s, "one"))), Engine.on_click(st.update(|s| ControlsApp.log(s, "two")))], [Engine.text("Twice")]),
				|| Engine.text(""),
			),
			Engine.when(
				st.signal().map(|s| s.twice == InRow),
				|| Engine.each(
					Engine.const(["r"]),
					|r| r,
					|_| Engine.element("button", [Engine.on_click(st.lift_row().update(|s| ControlsApp.log(s, "one"))), Engine.on_click(st.lift_row().update(|s| ControlsApp.log(s, "two")))], [Engine.text("Twice in a row")]),
				),
				|| Engine.text(""),
			),
			Engine.element("p", [Engine.test_id("state")], [Engine.text_s(st.signal().map(|s| "${s.plain}|${s.upper}"))]),
			Engine.element("pre", [Engine.test_id("log")], [Engine.text_s(st.signal().map(|s| Str.join_with(s.log, "|")))]),
			ControlsApp.properties({}),
			TypedControlsApp.view({}),
		],
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `fuzz-controls.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program_boot({}, |boot| if (boot.url.ends_with("#rendering")) RenderingApp.view({}) else if (boot.url.ends_with("#raw-input")) RawInputApp.view({}) else if (boot.url.ends_with("#pointer")) PointerApp.view({}) else if (boot.url.ends_with("#top-layer")) TopLayerApp.view({}) else ControlsApp.main({}))

	main : {} -> Elem(Root)
	main = |_| Engine.state({ plain: "hello world", upper: "", log: [], ask: { serial: 0, req: None }, rows: [], twice: Neither }, |st| ControlsApp.view(st))

	## Property holes retain row identity and prune equal values even when
	## another field of their row changed. Fault controls exercise the public
	## declaration checks and the current-type check on a value command.
	properties : {} -> Elem(ctx)
	properties = |_props| Engine.state(
		{ rows: [{ key: "a", checked: False, choice: "a", stamp: 0.U64 }, { key: "b", checked: True, choice: "b", stamp: 0 }], fault: Clean, input_type: "text", value: "draft", custom: "" },
		|properties| Engine.element(
			"section",
			[],
			[
				Html.button("Set row checks", [], properties.update(|s| { ..s, rows: s.rows.map(|row| { ..row, checked: True }) })),
				Html.button("Touch row metadata", [], properties.update(|s| { ..s, rows: s.rows.map(|row| { ..row, stamp: row.stamp.plus_wrap(1) }) })),
				Engine.each(
					properties.signal().map(|s| s.rows),
					|row| row.key,
					|row| Engine.element(
						"div",
						[],
						[
							Engine.element(
								"input",
								[
									Engine.attr("type", "checkbox"),
									Html.aria_label_s(row.key().map(|key| "Property check ${key}")),
									Engine.prop_s(Engine.Prop.checked, row.field(|value| value.checked)),
									Engine.on("change", properties.lift_row().set_value_by(row.key(), |s, key, value| { ..s, rows: s.rows.map(|entry| if (entry.key == key) { ..entry, checked: value == "true" } else entry) })),
								],
								[],
							),
							Engine.element(
								"select",
								[
									Html.aria_label_s(row.key().map(|key| "Property option ${key}")),
									Engine.prop_s(Engine.Prop.value, row.field(|value| value.choice)),
									Engine.on("change", properties.lift_row().set_value_by(row.key(), |s, key, value| { ..s, rows: s.rows.map(|entry| if (entry.key == key) { ..entry, choice: value } else entry) })),
								],
								[
									Engine.element("option", [Engine.prop_s(Engine.Prop.value, row.key())], [Engine.text_s(row.key())]),
									Engine.element("option", [Engine.prop(Engine.Prop.value, "other")], [Engine.text("Other")]),
								],
							),
						],
					),
				),
				Engine.element("progress", [Engine.test_id("ordinary-progress"), Engine.attr("value", "0.5")], []),
				Engine.element("custom-value", [Engine.test_id("ordinary-custom-value"), Engine.attr("value", "attribute only")], []),
				Engine.element("button", [Html.aria_label("Custom colon event"), Engine.on("x:y", properties.update(|s| { ..s, custom: "received" }))], [Engine.text("Custom colon event")]),
				Html.p_s(properties.signal().map(|s| s.custom), [Engine.test_id("custom-event-log")]),
				Engine.element("input", [Html.aria_label("Dynamic file value"), Engine.attr_s("type", properties.signal().map(|s| s.input_type)), Engine.prop_s(Engine.Prop.value, properties.signal().map(|s| s.value))], []),
				Html.button("Make value input a file", [], properties.update(|s| { ..s, input_type: "file" })),
				Html.button("Write file value", [], properties.update(|s| { ..s, value: "changed" })),
				Engine.element(
					"div",
					[],
					[
						{ name: "Retired prevent suffix", fault: RetiredPrevent },
						{ name: "Retired files suffix", fault: RetiredFiles },
						{ name: "Duplicate click policies", fault: ClickPolicies },
						{ name: "Duplicate change kinds", fault: ChangeKinds },
						{ name: "Checked property on div", fault: CheckedDiv },
						{ name: "Value attribute on input", fault: AttributeValue },
						{ name: "Duplicate value property", fault: DuplicateProperty },
						{ name: "Value property on file input", fault: FileValue },
					].map(|trigger| Html.button(trigger.name, [], properties.update(|s| { ..s, fault: trigger.fault }))),
				),
				Engine.switch(
					properties.signal().map(|s| s.fault),
					[Clean, RetiredPrevent, RetiredFiles, ClickPolicies, ChangeKinds, CheckedDiv, AttributeValue, DuplicateProperty, FileValue],
					|fault| match fault {
						Clean => Engine.text("")
						RetiredPrevent => Engine.element("button", [Engine.on("click:prevent", properties.update(|s| s))], [])
						RetiredFiles => Engine.element("input", [Engine.on("change:files", properties.update(|s| s))], [])
						ClickPolicies => Engine.element("button", [Engine.on("click", properties.update(|s| s)), Engine.on_with("click", { prevent: True }, properties.update(|s| s))], [])
						ChangeKinds => Engine.element("input", [Engine.on("change", properties.update(|s| s)), Engine.on_files(Change, properties.update(|s| s))], [])
						CheckedDiv => Engine.element("div", [Engine.prop(Engine.Prop.checked, True)], [])
						AttributeValue => Engine.element("input", [Engine.attr_s("value", Engine.const("not a property"))], [])
						DuplicateProperty => Engine.element("input", [Engine.prop(Engine.Prop.value, "first"), Engine.prop(Engine.Prop.value, "second")], [])
						FileValue => Engine.element("input", [Engine.attr("type", "file"), Engine.prop(Engine.Prop.value, "")], [])
					},
				),
			],
		),
	)
}
