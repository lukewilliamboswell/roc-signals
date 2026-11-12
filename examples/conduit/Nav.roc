import pf.Engine exposing [Cell, Elem, Handler, Val]

## Navigation inside the app, asked for through a cell: the outbox of URLs
## the root pushes to the history and moves to. A component that draws a
## link is handed that cell and uses these, so it works with whichever
## store holds the cell and never imports the app's.
Nav := [].{

	## The cell a navigation is asked through, in a store whose storage is `st`.
	Asked(st) : Cell(st, Engine.Outbox(Str))

	## A handler that asks to go to `url`.
	go : Asked(st), Str -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	go = |nav, url| Engine.does([nav.change(|o| o.post(url))])

	## A handler that asks to go to the URL `url` holds when the event fires.
	go_by : Asked(st), Val(ctx, Str) -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	go_by = |nav, url| Engine.handle_by(url, |to, _| [nav.change(|o| o.post(to))])

	## A link with a fixed label, class and URL.
	link : Asked(st), Str, Str, Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link = |nav, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr("href", url), Engine.on("click:prevent", Nav.go(nav, url))], [Engine.text(label)])

	## A link whose class follows a value.
	link_c : Asked(st), Str, Val(ctx, Str), Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link_c = |nav, label, cls, url| Engine.element("a", [Engine.class_v(cls), Engine.attr("href", url), Engine.on("click:prevent", Nav.go(nav, url))], [Engine.text(label)])

	## A link whose label and URL follow values.
	link_v : Asked(st), Val(ctx, Str), Str, Val(ctx, Str) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link_v = |nav, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr_v("href", url), Engine.on("click:prevent", Nav.go_by(nav, url))], [Engine.text_v(label)])
}
