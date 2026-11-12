import pf.Engine exposing [Elem, Val]
import pf.Html

## Pieces of markup the page and the live panel both draw.
Parts := [].{

	## The classes of one panel of the page.
	panel_class : Str
	panel_class = "panel grid gap-4 p-5"

	## One label-and-number metric. The `test_id` sits on the value, so a spec
	## reads the number the page shows rather than a sentence built for the
	## spec.
	metric : Str, Str, Val(ctx, Str) -> Elem(ctx)
	metric = |id, label, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value numeric"), Engine.test_id(id), Html.aria_label(label)])])
}
