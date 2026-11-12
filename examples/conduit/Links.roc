import pf.Engine exposing [Elem, Signal]
import AppStore
import Nav

## Links that navigate inside the app, usable in any scope at any depth by
## a module that imports the app's store: `Nav`'s links over the store's
## navigation cell. A component the store holds cannot import this; it is
## handed the cell and uses `Nav`.
Links := [].{

	## A link with a fixed label, class and URL.
	link : Str, Str, Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	link = |label, cls, url| Nav.link(AppStore.cells.nav, label, cls, url)

	## A link whose class follows a value.
	link_c : Str, Signal(ctx, Str), Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	link_c = |label, cls, url| Nav.link_c(AppStore.cells.nav, label, cls, url)

	## A link whose label and URL follow values.
	link_s : Signal(ctx, Str), Str, Signal(ctx, Str) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	link_s = |label, cls, url| Nav.link_s(AppStore.cells.nav, label, cls, url)
}
