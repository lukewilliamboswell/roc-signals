import Engine exposing [Elem, Root, In, State]
import H

## Controlled inputs, focus and containment test app.
## - "Plain": a controlled text input whose state is exactly what was typed.
## - "Upper": a controlled text input whose state is the typed text upper-cased
##   (the engine's value differs from what the user typed).
## Both log their values; the log is rendered for the browser tests.
ControlsApp := [].{
	S : { plain : Str, upper : Str, log : List(Str) }

	Ctx : In(Root, S)

	upper_ascii : Str -> Str
	upper_ascii = |s| {
		var $b = []
		for c in s.iter_utf8() {
			$b = $b.append(if c >= 97 and c <= 122 c - 32 else c)
		}
		Str.from_utf8($b) ?? s
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| Engine.element("div", [], [
		H.text_input(Engine.const("Plain"), "text", st.val().map(|s| s.plain), [], st.set_value(|s, v| { ..s, plain: v })),
		H.text_input(Engine.const("Upper"), "text", st.val().map(|s| s.upper), [], st.set_value(|s, v| { ..s, upper: ControlsApp.upper_ascii(v) })),
		Engine.element("p", [Engine.test_id("state")], [Engine.text_v(st.val().map(|s| "${s.plain}|${s.upper}"))]),
		Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
	])

	main : {} -> Elem(Root)
	main = |_| Engine.state({ plain: "hello world", upper: "", log: [] }, |st| ControlsApp.view(st))
}
