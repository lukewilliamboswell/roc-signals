app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Signal
import pf.Ui
import pf.Val

Inputs(ctx) : { title : Val(ctx, Str) }

view : Inputs(ctx) -> Elem(ctx)
view = |inputs| Html.text_s(inputs.title)

## Negative: a root Signal passed where a component's record field wants a Val
## (the record field is not a `to_val` call site).
main : () -> Elem(Ui.Root)
main = || {
	title : Signal(Str)
	title = Signal.const("hello")
	view({ title })
}
