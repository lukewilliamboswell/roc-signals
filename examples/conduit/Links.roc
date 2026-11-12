import pf.Engine exposing [Elem, Val]
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
	link = |label, cls, url| Nav.link(AppStore.h.nav, label, cls, url)

	## A link whose class follows a value.
	link_c : Str, Val(ctx, Str), Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	link_c = |label, cls, url| Nav.link_c(AppStore.h.nav, label, cls, url)

	## A link whose label and URL follow values.
	link_v : Val(ctx, Str), Str, Val(ctx, Str) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	link_v = |label, cls, url| Nav.link_v(AppStore.h.nav, label, cls, url)
}
