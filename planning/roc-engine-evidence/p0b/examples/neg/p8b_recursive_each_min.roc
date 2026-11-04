app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui
import pf.Val

## Minimal hang: a recursive view through `Ui.each` (each depth is a new
## context type). `roc check` never finishes; replacing the root each source
## with `crash` makes it pass.
node_view : Ui.RowRef(ctx, Str) -> Elem(Ui.Site(ctx, Str))
node_view = |_node| Html.element("ul", [], [Ui.each(Val.const(Rows.empty(|s| s)), node_view)])

main : () -> Elem(Ui.Root)
main = || Html.element("ul", [], [Ui.each(Val.const(Rows.empty(|s| s)), node_view)])
