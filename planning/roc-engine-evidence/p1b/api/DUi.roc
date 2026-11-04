## Representation D's application API, as types. Same value and handler
## representation as the runtime engine (`d/Engine.roc`); `each` is a stub here
## because the column store is Phase 0a's and is not wired into D yet.
##
## Contexts are environments. `In(outer, s)` is "inside a state of type s",
## `Site(outer, item)` is "inside a row of item". Every value, handler and state
## handle names the context it is used in. Crossing into a state or a row is an
## explicit, type-checked `lift` / `lift_row`; nothing else is hidden.
DUi := [].{
	Root := [Root]

	In(outer, s) := { outer : outer, value : s }

	Site(outer, item) := { outer : outer, key : Str, item : item }

	## A value readable in context `ctx`; `mask` lists the layers it reads.
	Val(ctx, a) := { mask : U64, read : (ctx -> a) }.{
		map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		map = |{ mask, read }, f| { mask, read: |env| f(read(env)) }

		map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		map2 = |l, r, f| {
			lr = l.read
			rr = r.read
			{ mask: l.mask.bitwise_or(r.mask), read: |env| f(lr(env), rr(env)) }
		}

		## Use this value inside a state body nested in its context.
		lift : Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |{ mask, read }| { mask, read: |e| read(e.outer) }

		## Use this value inside a row template nested in its context.
		lift_row : Val(ctx, a) -> Val(Site(ctx, item), a)
		lift_row = |{ mask, read }| { mask, read: |e| read(e.outer) }

		to_val : Val(ctx, a) -> Val(ctx, a)
		to_val = |v| v
	}

	## An event handler usable in context `ctx`: an environment transformer.
	Handler(ctx) := { mask : U64, run : (ctx -> ctx) }.{
		lift : Handler(ctx) -> Handler(In(ctx, s))
		lift = |{ mask, run }| { mask, run: |e| In.{ outer: run(e.outer), value: e.value } }

		lift_row : Handler(ctx) -> Handler(Site(ctx, item))
		lift_row = |{ mask, run }| { mask, run: |e| Site.{ outer: run(e.outer), key: e.key, item: e.item } }
	}

	## A state handle usable in context `ctx`: a lens from the context to the
	## state's value. `Ui.state` creates it at the state's own layer; `lift` and
	## `lift_row` carry it into nested states and rows.
	State(ctx, s) := { mask : U64, get : (ctx -> s), set : (ctx, s -> ctx) }.{
		val : State(ctx, s) -> Val(ctx, s)
		val = |{ mask, get, set: _ }| { mask, read: get }

		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ mask, get, set }, f| { mask, run: |e| set(e, f(get(e))) }

		## A reducer that also receives a context value read when the event fires
		## (typically the row key).
		update_by : State(ctx, s), Val(ctx, b), (s, b -> s) -> Handler(ctx)
		update_by = |{ mask, get, set }, v, f| {
			read = v.read
			{ mask, run: |e| set(e, f(get(e), read(e))) }
		}

		update_bool_by : State(ctx, s), Val(ctx, b), (s, b, Bool -> s) -> Handler(ctx)
		update_bool_by = |{ mask, get, set }, v, f| {
			read = v.read
			{ mask, run: |e| set(e, f(get(e), read(e), Bool.True)) }
		}

		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ mask, get, set }| { mask, get: |e| get(e.outer), set: |e, v| In.{ outer: set(e.outer, v), value: e.value } }

		lift_row : State(ctx, s) -> State(Site(ctx, item), s)
		lift_row = |{ mask, get, set }| { mask, get: |e| get(e.outer), set: |e, v| Site.{ outer: set(e.outer, v), key: e.key, item: e.item } }
	}

	Attr(ctx) := [Static(Str, Str), Dyn(Str, Val(ctx, Str)), DynBool(Str, Val(ctx, Bool)), On(Str, Handler(ctx))]

	Elem(ctx) := [
		Element(Str, List(Attr(ctx)), List(Elem(ctx))),
		Text(Str),
		TextV(Val(ctx, Str)),
		Erased(Str, (() -> Str)),
	]

	## Keyed rows. The template runs once per site; rows are typed columns.
	RowRef(outer, item) := [RowRef].{
		key : RowRef(outer, item) -> Val(Site(outer, item), Str)
		key = |_| { mask: 1, read: |e| e.key }

		field : RowRef(outer, item), (item -> a) -> Val(Site(outer, item), a)
		field = |_, f| { mask: 1, read: |e| f(e.item) }

		## Exact-key selection: only the old and new key's rows change.
		select : RowRef(outer, item), Keyed(outer, v) -> Val(Site(outer, item), v)
		select = |_, { selected, yes, no }| { mask: 1, read: |e| if selected(e.outer) == e.key yes else no }
	}

	Keyed(ctx, v) : { selected : (ctx -> Str), yes : v, no : v }

	keyed : Val(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sel, yes, no| { selected: sel.read, yes, no }

	## A state per instance of the current context (per row inside a template).
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [s.is_eq : s, s -> Bool]
	state = |init, body| {
		handle = { mask: 2, get: |e| e.value, set: |e, v| In.{ outer: e.outer, value: v } }
		inner = body(handle)
		Erased("state", || "{state ${DUi.describe(inner)}}")
	}

	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Site(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |_rows, _key, template| {
		inner = template(RowRef)
		Erased("each", || "{each ${DUi.describe(inner)}}")
	}

	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |_cond, yes, no| {
		y = yes()
		n = no()
		Erased("when", || "{when ${DUi.describe(y)} | ${DUi.describe(n)}}")
	}

	component : (() -> Elem(ctx)) -> Elem(ctx)
	component = |body| body()

	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value }

	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Element(tag, attrs, kids)

	text : Str -> Elem(ctx)
	text = |s| Text(s)

	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| TextV(v)

	class_attr : Str -> Attr(ctx)
	class_attr = |c| Static("class", c)

	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| Dyn("class", v)

	test_id_v : Val(ctx, Str) -> Attr(ctx)
	test_id_v = |v| Dyn("data-testid", v)

	button : Str, Handler(ctx) -> Elem(ctx)
	button = |label, h| Element("button", [On("click", h)], [Text(label)])

	checkbox : Str, Val(ctx, Bool), Handler(ctx) -> Elem(ctx)
	checkbox = |label, checked, h| Element("input", [Static("type", "checkbox"), Static("aria-label", label), DynBool("checked", checked), On("change", h)], [])

	describe : Elem(ctx) -> Str
	describe = |elem|
		match elem {
			Element(tag, attrs, kids) => "<${tag}:${attrs.len().to_str()}>${Str.join_with(kids.map(DUi.describe), "")}</${tag}>"
			Text(s) => s
			TextV(_) => "{val}"
			Erased(_, d) => d()
		}
}
