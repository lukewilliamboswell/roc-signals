import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

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
			Html.button("Blur plain", [], st.update(|s| ControlsApp.ask(s, B("plain")))),
			Html.button("Focus missing", [], st.update(|s| ControlsApp.ask(s, F("nowhere")))),
			Engine.watch_changes(
				st.signal().map(|s| s.ask),
				|a| match a.req {
					F(n) => [Focus(n)]
					B(n) => [Blur(n)]
					Sel(n) => [SelectText(n)]
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
		],
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `fuzz-controls.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program(|| ControlsApp.main({}))

	main : {} -> Elem(Root)
	main = |_| Engine.state({ plain: "hello world", upper: "", log: [], ask: { serial: 0, req: None }, rows: [], twice: Neither }, |st| ControlsApp.view(st))
}
