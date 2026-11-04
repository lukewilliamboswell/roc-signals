import Engine exposing [Elem, Root, In, State]
import H

## Controlled inputs, focus and containment test app.
## - "Plain": a controlled text input whose state is exactly what was typed.
## - "Upper": a controlled text input whose state is the typed text upper-cased
##   (the engine's value differs from what the user typed).
## Both carry focus references; buttons ask for Focus / SelectText / Blur
## through an effect site, and focus/blur handlers on "Plain" log their
## payloads. The log is rendered for the tests.
ControlsApp := [].{
	S : { plain : Str, upper : Str, log : List(Str), ask : { serial : U64, req : [None, F(Str), B(Str), Sel(Str)] } }

	Ctx : In(Root, S)

	upper_ascii : Str -> Str
	upper_ascii = |s| {
		var $b = []
		for c in s.iter_utf8() {
			$b = $b.append(if c >= 97 and c <= 122 c - 32 else c)
		}
		Str.from_utf8($b) ?? s
	}

	log : S, Str -> S
	log = |s, line| { ..s, log: s.log.append(line) }

	ask : S, [None, F(Str), B(Str), Sel(Str)] -> S
	ask = |s, req| { ..s, ask: { serial: s.ask.serial + 1, req } }

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| Engine.element("div", [], [
		H.text_input(
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
		H.text_input(Engine.const("Upper"), "text", st.val().map(|s| s.upper), [Engine.ref("upper")], st.set_value(|s, v| { ..s, upper: ControlsApp.upper_ascii(v) })),
		H.button("Focus upper", [], st.update(|s| ControlsApp.ask(s, F("upper")))),
		H.button("Select plain", [], st.update(|s| ControlsApp.ask(s, Sel("plain")))),
		H.button("Blur plain", [], st.update(|s| ControlsApp.ask(s, B("plain")))),
		H.button("Focus missing", [], st.update(|s| ControlsApp.ask(s, F("nowhere")))),
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
		Engine.element("p", [Engine.test_id("state")], [Engine.text_v(st.val().map(|s| "${s.plain}|${s.upper}"))]),
		Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
	])

	main : {} -> Elem(Root)
	main = |_| Engine.state({ plain: "hello world", upper: "", log: [], ask: { serial: 0, req: None } }, |st| ControlsApp.view(st))
}
