import pf.Engine exposing [Elem, Val]
import Styles

## Small pieces of view the article page's components share. Each works in
## any context.
Parts := [].{

	button : Str, Str, Engine.Handler(ctx) -> Elem(ctx)
	button = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text(label)])

	button_v : Val(ctx, Str), Str, Engine.Handler(ctx) -> Elem(ctx)
	button_v = |label, cls, h| Engine.element("button", [Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text_v(label)])

	textarea : Str, Val(ctx, Str), Engine.Handler(ctx) -> Elem(ctx)
	textarea = |name, v, h| Engine.element("textarea", [Engine.attr("aria-label", name), Engine.class(Styles.field), Engine.attr_v("value", v), Engine.on("input", h)], [])

	keyed_lines : List(Str) -> List({ key : Str, text : Str })
	keyed_lines = |lines| {
		var $out = []
		var $i = 0.U64
		for line in lines {
			$out = $out.append({ key: "e:${$i.to_str()}", text: line })
			$i = $i + 1
		}
		$out
	}

	## A list of error lines, absent while there are none.
	error_list : Val(ctx, List(Str)) -> Elem(ctx)
	error_list = |errors| Engine.element(
		"div",
		[],
		[
			Engine.when(
				errors.map(|l| !l.is_empty()),
				|| Engine.element("ul", [Engine.class(Styles.error_list)], [Engine.each(errors.map(Parts.keyed_lines), |i| i.key, |row| Engine.element("li", [], [Engine.text_v(row.field(|i| i.text))]))]),
				|| Engine.text(""),
			),
		],
	)
}
