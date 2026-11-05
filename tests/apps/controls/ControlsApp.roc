import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Controlled inputs, focus and containment test app.
## - "Plain": a controlled text input whose state is exactly what was typed.
## - "Upper": a controlled text input whose state is the typed text upper-cased
##   (the engine's value differs from what the user typed).
## Both carry focus references; buttons ask for Focus / SelectText / Blur
## through an effect site, and focus/blur handlers on "Plain" log their
## payloads. The log is rendered for the tests.
ControlsApp := [].{
	S : { plain : Str, upper : Str, log : List(Str), ask : { serial : U64, req : [None, F(Str), B(Str), Sel(Str)] }, rows : List(Str) }

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
				st.val().map(|s| s.plain),
				[
					Engine.ref("plain"),
					Engine.on("focus", st.set_value(|s, v| ControlsApp.log(s, "focus:${v}"))),
					Engine.on("blur", st.set_value(|s, v| ControlsApp.log(s, "blur:${v}"))),
				],
				st.set_value(|s, v| { ..s, plain: v }),
			),
			Html.text_input(Engine.const("Upper"), "text", st.val().map(|s| s.upper), [Engine.ref("upper")], st.set_value(|s, v| { ..s, upper: ControlsApp.upper_ascii(v) })),
			Html.button("Focus upper", [], st.update(|s| ControlsApp.ask(s, F("upper")))),
			Html.button("Select plain", [], st.update(|s| ControlsApp.ask(s, Sel("plain")))),
			Html.button("Blur plain", [], st.update(|s| ControlsApp.ask(s, B("plain")))),
			Html.button("Focus missing", [], st.update(|s| ControlsApp.ask(s, F("nowhere")))),
			Engine.on_change(
				st.val().map(|s| s.ask),
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
			Engine.element("ul", [Engine.test_id("rows")], [Engine.each(st.val().map(|s| s.rows), |r| r, |row| Engine.element("li", [], [Engine.text_v(row.key())]))]),
			Engine.element("p", [Engine.test_id("state")], [Engine.text_v(st.val().map(|s| "${s.plain}|${s.upper}"))]),
			Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
		],
	)

	## The program both hosts run: the web platform (`main-web.roc`) and the
	## test platform (`main-test.roc`, `main-fuzz.roc`).
	program : Engine.Program
	program = Engine.program(|| ControlsApp.main({}))

	main : {} -> Elem(Root)
	main = |_| Engine.state({ plain: "hello world", upper: "", log: [], ask: { serial: 0, req: None }, rows: [] }, |st| ControlsApp.view(st))
}
