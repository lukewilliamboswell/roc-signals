import pf.Engine
import pf.Html

## One ordinary first frame whose literal data must survive rendering and
## asset URL projection. Host template rewriting cannot rewrite app values.
PrerenderApp := [].{
    Ctx : Engine.In(Engine.Root, I64)
    ## Both hosts run this counter through the ordinary engine and command stream.
    program : Engine.Program
    program = Engine.program(|| Engine.state(0.I64, |count| {
        comments : Html.Markup(Ctx)
        comments = "<span><!--roc:node=9--><!--roc:node=9-->literal &amp; text</span>"
        Engine.element("section", [Engine.test_id("picture-frame")], [
            Engine.element("button", [Engine.on_click(count.update(|value| value + 1))], [Engine.text("Increment")]),
            Engine.element("button", [Engine.on_click(count.update(|value| value - 1))], [Engine.text("Decrement")]),
            Engine.element("output", [Engine.test_id("count")], [Engine.text_s(count.signal().map(|value| value.to_str()))]),
            Engine.element("span", [Engine.test_id("asset-looking-data"), Engine.attr("title", "app.wasm")], [Engine.text("\"app.wasm\"")]),
            Engine.element("input", [Engine.attr("aria-label", "Escaped value"), Engine.prop_s(Engine.Prop.value, Engine.const("<&\"'"))], []),
            comments.to_elem(),
        ])
    }))
}
