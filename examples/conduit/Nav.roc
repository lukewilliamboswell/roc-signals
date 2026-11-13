import pf.Engine exposing [Cell, Elem, Handler, Signal]

## Navigation inside the app, asked for through a cell: the outbox of URLs
## the root pushes to the history and moves to. A component that draws a
## link is handed that cell and uses these, so it works with whichever
## store holds the cell and never imports the app's.
Nav := [].{

	## The cell a navigation is asked through, in a store whose type is `st`.
	Asked(st) : Cell(st, Engine.Outbox(Str))

	## A handler that asks to go to `url`.
	go : Asked(st), Str -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	go = |nav, url| Engine.does([nav.update(|o| o.post(url))])

	## A handler that asks to go to the URL `url` holds when the event fires.
	go_by : Asked(st), Signal(ctx, Str) -> Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	go_by = |nav, url| Engine.handle_by(url, |to, _| [nav.update(|o| o.post(to))])

	## A link with a fixed label, class and URL.
	link : Asked(st), Str, Str, Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link = |nav, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr("href", url), Engine.on_with("click", { prevent: True }, Nav.go(nav, url))], [Engine.text(label)])

	## A link whose class follows a value.
	link_c : Asked(st), Str, Signal(ctx, Str), Str -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link_c = |nav, label, cls, url| Engine.element("a", [Engine.class_s(cls), Engine.attr("href", url), Engine.on_with("click", { prevent: True }, Nav.go(nav, url))], [Engine.text(label)])

	## A link whose label and URL follow values.
	link_s : Asked(st), Signal(ctx, Str), Str, Signal(ctx, Str) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	link_s = |nav, label, cls, url| Engine.element("a", [Engine.class(cls), Engine.attr_s("href", url), Engine.on_with("click", { prevent: True }, Nav.go_by(nav, url))], [Engine.text_s(label)])
}
