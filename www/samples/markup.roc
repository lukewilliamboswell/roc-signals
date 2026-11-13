app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.Svg

Ctx : Engine.In(Engine.Root, U64)

# region literals
## Markup supplies mostly fixed structure; the surrounding constructor owns
## the handler. Both literals bind the same ordinary text signal.
view : Engine.State(Ctx, U64) -> Engine.Elem(Ctx)
view = |state| {
	count = state.signal().to_text_signal()
	card : Html.Markup(Ctx)
	card =
		\\<article class="card">
		\\  <h2>Markup card</h2>
		\\  <p>Count: ${count}</p>
		\\</article>
	drawing : Svg.Markup(Ctx)
	drawing =
		\\<svg viewBox="0 0 100 40" width="200" height="80" aria-label="Count drawing">
		\\  <circle cx="20" cy="20" r="16" fill="steelblue"/>
		\\  <text x="50" y="24">${count}</text>
		\\</svg>
	Engine.element(
		"section",
		[],
		[
			Html.button("Add", [], state.update(|before| before + 1)),
			card.to_elem(),
			drawing.to_elem(),
		],
	)
}

# endregion literals

main : Engine.Program
main = Engine.program(|| Engine.state(0.U64, view))

## The instance holds this store beside its site tree.
Store : {}

## Check the first page while this sample compiles.
mounted : U64
mounted = Engine.mounts(main)
