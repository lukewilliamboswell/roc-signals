## A value that may vary by context.
##
## `Val(ctx, a)` is the typed-sites replacement for "a signal per row". It is
## described once per `Ui.each` site, never once per row. `ctx` names where the
## value can be read:
##
## - `Ui.Root` outside any keyed list;
## - `Ui.Site(outer, item)` inside the template of a `Ui.each` whose rows have
##   type `item`, nested inside context `outer`.
##
## A `Val` is either site-level (it reads only site signals, so every row sees
## the same value) or row-level (it projects from the row's item or key). The
## engine evaluates a row-level `Val` against each row's typed column entry;
## the projection closure is created once per site.
##
## Sketch representation: the two variants are what the engine needs to know to
## decide whether a site-signal change dirties zero rows (`SiteVal` used through
## `Ui.RowRef.select`), all rows (a `SiteVal` mixed into a row projection), or
## only rows whose item changed (`RowVal`).
Val(ctx, a) :: [SiteVal(Box((() -> a))), RowVal(Box((ctx -> a)))].{

	## Every reactive argument in the sketch API accepts anything with a
	## `to_val` method: a `Val(ctx, a)` itself, or a site-level `Signal(a)`.
	to_val : Val(ctx, a) -> Val(ctx, a)
	to_val = |v| v

	## A constant, readable in any context.
	const : a -> Val(ctx, a)
		where [
			a.is_eq : a, a -> Bool,
		]
	const = |value| SiteVal(Box.box(|| value))

	## Equality-pruned projection. A row-level input gives a row-level output.
	map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		where [
			b.is_eq : b, b -> Bool,
		]
	map = |v, f|
		match v {
			SiteVal(read) => SiteVal(Box.box(|| f(Box.unbox(read)())))
			RowVal(read) => RowVal(Box.box(|ctx| f(Box.unbox(read)(ctx))))
		}

	## Combine two values in one context. Also the record-builder hook, so
	## `{ title: a, done: b }.Val` builds a `Val(ctx, { title : _, done : _ })`.
	map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		where [
			c.is_eq : c, c -> Bool,
		]
	map2 = |left, right, f|
		match (left, right) {
			(SiteVal(l), SiteVal(r)) => SiteVal(Box.box(|| f(Box.unbox(l)(), Box.unbox(r)())))
			_ => RowVal(Box.box(|ctx| f(platform_eval(left, ctx), platform_eval(right, ctx))))
		}

	## Platform-private: wrap a site read.
	platform_site : (() -> a) -> Val(ctx, a)
	platform_site = |read| SiteVal(Box.box(read))

	## Platform-private: wrap a row projection.
	platform_row : (ctx -> a) -> Val(ctx, a)
	platform_row = |read| RowVal(Box.box(read))

	## Platform-private: read in a concrete context (engine only).
	platform_eval : Val(ctx, a), ctx -> a
	platform_eval = |v, ctx|
		match v {
			SiteVal(read) => Box.unbox(read)()
			RowVal(read) => Box.unbox(read)(ctx)
		}

	## Platform-private: change the context a value is read in.
	platform_contramap : Val(inner, a), (outer -> inner) -> Val(outer, a)
	platform_contramap = |v, project|
		match v {
			SiteVal(read) => SiteVal(read)
			RowVal(read) => RowVal(Box.box(|ctx| Box.unbox(read)(project(ctx))))
		}
}
