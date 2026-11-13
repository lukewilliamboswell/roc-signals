import pf.Engine
import pf.Html

## One ordinary first frame whose literal data must survive rendering and
## asset URL projection. Host template rewriting cannot rewrite app values.
PrerenderApp := [].{
	Ctx : Engine.In(Engine.Root, I64)

	## Both hosts run this counter through the ordinary engine and command stream.
	program : Engine.Program
	program = Engine.program_boot({}, |boot| Engine.state(0.I64, |count| if (boot.url.ends_with("#foreign")) PrerenderApp.foreign_view(count) else PrerenderApp.view(count)))

	view : Engine.State(Ctx, I64) -> Engine.Elem(Ctx)
	view = |count| {
		comments : Html.Markup(Ctx)
		comments = "<span><!--roc:node=9--><!--roc:node=9-->literal &amp; text</span>"
		Engine.element(
			"section",
			[Engine.test_id("picture-frame")],
			[
				Engine.element("button", [Engine.on_click(count.update(|value| value + 1))], [Engine.text("Increment")]),
				Engine.element("button", [Engine.on_click(count.update(|value| value - 1))], [Engine.text("Decrement")]),
				Engine.element("output", [Engine.test_id("count")], [Engine.text_s(count.signal().map(|value| value.to_str()))]),
				Engine.element("span", [Engine.test_id("asset-looking-data"), Engine.attr("title", "app.wasm")], [Engine.text("\"app.wasm\"")]),
				Engine.element("input", [Engine.attr("aria-label", "Escaped value"), Engine.prop_s(Engine.Prop.value, Engine.const("<&\"'"))], []),
				comments.to_elem(),
			],
		)
	}

	## A real SVG-root view uses the same counter and event path. The host's
	## explicit inert parent changes neither this namespace nor the app's root.
	foreign_view : Engine.State(Ctx, I64) -> Engine.Elem(Ctx)
	foreign_view = |count| Engine.element("g", [Engine.test_id("foreign-frame")], [
		Engine.element("g", [Engine.test_id("foreign-increment"), Engine.attr("role", "button"), Engine.attr("aria-label", "Foreign increment"), Engine.attr("tabindex", "0"), Engine.on_click(count.update(|value| value + 1))], [Engine.element("text", [Engine.attr("x", "0"), Engine.attr("y", "20")], [Engine.text("+")])]),
		Engine.element("g", [Engine.test_id("foreign-decrement"), Engine.attr("role", "button"), Engine.attr("aria-label", "Foreign decrement"), Engine.attr("tabindex", "0"), Engine.on_click(count.update(|value| value - 1))], [Engine.element("text", [Engine.attr("x", "30"), Engine.attr("y", "20")], [Engine.text("-")])]),
		Engine.element("text", [Engine.test_id("foreign-count"), Engine.attr("x", "60"), Engine.attr("y", "20")], [Engine.text_s(count.signal().map(|value| value.to_str()))]),
	])
}
