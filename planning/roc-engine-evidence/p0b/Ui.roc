import Elem
import Node
import Rows
import Signal
import Val

## Sketch stub: the engine mounts an erased site from the captured template.
site_mount : template, Str -> List(U8)
site_mount = |_template, _message| crash "sketch: engine mounts this site"

## Structure, state and keyed lists for typed sites.
##
## The central change from today's API: `Ui.each` calls its row builder ONCE
## per site, with a `RowRef(ctx, item)` that has no key and no item. The
## builder describes the row through accessors (`row.field`, `row.key`,
## `row.select`), which return `Val(Site(ctx, item), a)`. Handlers receive the
## row's context when they fire instead of capturing a key.
Ui := [].{

	## The context outside any keyed list.
	Root :: [Root]

	## The context inside a row of a `Ui.each` over `item`, nested in `outer`.
	## Opaque: the engine builds it from its typed columns when it evaluates a
	## row value or fires a row handler.
	Site(outer, item) :: { outer : outer, key : Str, item : item }

	## The enclosing context of a row in a recursive `Ui.tree`: either the
	## tree's own outer context, or the parent row. Every depth of one tree
	## shares the context type `Site(Up(outer, node), node)`, so a recursive
	## view is ordinary recursion rather than polymorphic recursion.
	Up(outer, node) :: [Top(outer), Parent(Site(Up(outer, node), node))]

	## An event handler usable in context `ctx`.
	Handler(ctx) : Node.Handler(ctx)

	## A proposed write to a root state, applied atomically by `Action.update`.
	StateWrite : Node.StateWrite

	## Keyboard payload, unchanged.
	KeyPayload : { key : Str, shift_key : Bool }

	## The builder's handle on "the row" of one `Ui.each` site. It is not a row:
	## it holds no key and no item. Every method returns a description that the
	## engine evaluates per row from that site's typed columns.
	RowRef(outer, item) :: [RowRef].{

		## The row's exact UTF-8 key.
		key : RowRef(outer, item) -> Val(Site(outer, item), Str)
		key = |_row| Val.platform_row(|site| site.key)

		## A projection of the row's item, equality-pruned per row.
		field : RowRef(outer, item), (item -> a) -> Val(Site(outer, item), a)
			where [
				a.is_eq : a, a -> Bool,
			]
		field = |_row, project| Val.platform_row(|site| project(site.item))

		## The whole item, for a component that takes the row record.
		item : RowRef(outer, item) -> Val(Site(outer, item), item)
			where [
				item.is_eq : item, item -> Bool,
			]
		item = |_row| Val.platform_row(|site| site.item)

		## Read a site-shared keyed selector at this row. Changing the selected
		## key re-evaluates only the old and new row, whatever the list length.
		select : RowRef(outer, item), Signal.Keyed(value) -> Val(Site(outer, item), value)
		select = |_row, keyed| Val.platform_row(|site| Signal.platform_keyed_for(keyed, site.key))

		## Read a value of the enclosing row (nested `each`) inside this row.
		outer : RowRef(outer, item), Val(outer, a) -> Val(Site(outer, item), a)
		outer = |_row, value| Val.platform_contramap(value, |site| site.outer)

		## Use a handler of the enclosing row (nested `each`) inside this row.
		outer_handler : RowRef(outer, item), Node.Handler(outer) -> Node.Handler(Site(outer, item))
		outer_handler = |_row, _h| crash "sketch: engine fires the outer handler with site.outer"
	}

	## A root state. Its handlers fire from any context, because the state has
	## exactly one instance; that is why `update` returns `Handler(ctx)` for any
	## `ctx`. It can only be introduced at `Root` (see `Ui.state`).
	State(a) :: { binder : U64, read : Box((() -> a)) }.{

		## Read this state as a site-level signal.
		signal : State(a) -> Signal(a)
		signal = |st| Signal.platform_from_read(Box.unbox(st.read))

		## A unit-event reducer, usable at any depth.
		update : State(a), (a -> a) -> Node.Handler(ctx)
		update = |_st, _f| Node.handler(Unit, |_ctx, _payload| crash "sketch")

		## A unit-event reducer that also receives a context value read when the
		## event fires, typically the row key: `model.update_by(row.key(), remove)`.
		update_by : State(a), v, (a, b -> a) -> Node.Handler(ctx)
			where [
				v.to_val : v -> Val(ctx, b),
			]
		update_by = |_st, _v, _f| Node.handler(Unit, |_ctx, _payload| crash "sketch")

		## A text-input reducer.
		update_str : State(a), (a, Str -> a) -> Node.Handler(ctx)
		update_str = |_st, _f| Node.handler(TargetValue, |_ctx, _payload| crash "sketch")

		## A text-input reducer that also receives a context value.
		update_str_by : State(a), v, (a, b, Str -> a) -> Node.Handler(ctx)
			where [
				v.to_val : v -> Val(ctx, b),
			]
		update_str_by = |_st, _v, _f| Node.handler(TargetValue, |_ctx, _payload| crash "sketch")

		## A checkbox reducer.
		update_bool : State(a), (a, Bool -> a) -> Node.Handler(ctx)
		update_bool = |_st, _f| Node.handler(TargetChecked, |_ctx, _payload| crash "sketch")

		## A checkbox reducer that also receives a context value.
		update_bool_by : State(a), v, (a, b, Bool -> a) -> Node.Handler(ctx)
			where [
				v.to_val : v -> Val(ctx, b),
			]
		update_bool_by = |_st, _v, _f| Node.handler(TargetChecked, |_ctx, _payload| crash "sketch")

		## Describe reducing this state when a batch commits.
		write : State(a), (a -> a) -> Node.StateWrite
		write = |st, _f| Node.state_write(st.binder, |x| x)

		## Describe replacing this state when a batch commits.
		set : State(a), a -> Node.StateWrite
		set = |st, _next| Node.state_write(st.binder, |x| x)
	}

	## Local state that exists once per instance of its context: once per row
	## inside a row template. Stored by the engine as one typed column per site.
	## Its value and handlers carry the context, so they cannot escape the row.
	RowState(ctx, a) :: { slot : U64, init : a }.{

		## Read this row's value.
		to_val : RowState(ctx, a) -> Val(ctx, a)
		to_val = |st| Val.platform_row(|_ctx| st.init)

		## Same as `to_val`, spelled for call sites.
		val : RowState(ctx, a) -> Val(ctx, a)
		val = |st| Val.platform_row(|_ctx| st.init)

		## A unit-event reducer for this row's instance.
		update : RowState(ctx, a), (a -> a) -> Node.Handler(ctx)
		update = |_st, _f| Node.handler(Unit, |_ctx, _payload| crash "sketch")

		## A text-input reducer for this row's instance.
		update_str : RowState(ctx, a), (a, Str -> a) -> Node.Handler(ctx)
		update_str = |_st, _f| Node.handler(TargetValue, |_ctx, _payload| crash "sketch")
	}

	## Introduce a root state. Only valid at `Root`: the type says so, rather
	## than a runtime contract error. Use `Ui.local` inside a row.
	state : a, (State(a) -> Elem(Root)) -> Elem(Root)
		where [
			a.is_eq : a, a -> Bool,
		]
	state = |init, body| {
		handle = { binder: 0, read: Box.box(|| init) }
		child = body(handle)
		Elem.platform_component(child)
	}

	## Introduce state once per instance of the current context. At `Root` this
	## is a single instance; inside a row it is a typed column.
	local : a, (RowState(ctx, a) -> Elem(ctx)) -> Elem(ctx)
		where [
			a.is_eq : a, a -> Bool,
		]
	local = |init, body| {
		template = body({ slot: 0, init })
		Elem.platform_erased(LocalState, |_ctx| site_mount(template, "sketch: engine mounts the local state column"), || "{local ${Elem.platform_describe(template)}}")
	}

	## A reusable local identity scope.
	component : (() -> Elem(ctx)) -> Elem(ctx)
	component = |body| Elem.platform_component(body())

	## Select a branch by a boolean context value. The branch builders are
	## called at most once per site per branch, never per row.
	when : c, (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
		where [
			c.to_val : c -> Val(ctx, Bool),
		]
	when = |condition, when_true, when_false| Elem.platform_when(condition.to_val(), when_true, when_false)

	## Select a branch by any equality-comparable context value. The builder is
	## called once per site per distinct case value.
	switch : c, (case -> Elem(ctx)) -> Elem(ctx)
		where [
			c.to_val : c -> Val(ctx, case),
			case.is_eq : case, case -> Bool,
		]
	switch = |condition, build| {
		_value = condition.to_val()
		Elem.platform_erased(Switch, |_ctx| site_mount(build, "sketch: engine selects the case per instance"), || "{switch}")
	}

	## Keyed rows. `rows` is any context value holding `Rows(item)`: a root
	## signal for a top-level list, or `row.field(.children)` for a nested one.
	## `row_template` runs once per site and describes every row.
	each : r, (RowRef(ctx, item) -> Elem(Site(ctx, item))) -> Elem(ctx)
		where [
			r.to_val : r -> Val(ctx, Rows(item)),
			item.is_eq : item, item -> Bool,
		]
	each = |rows, row_template| {
		_source = rows.to_val()
		template = row_template(RowRef)
		Elem.platform_erased(Each, |_ctx| site_mount(template, "sketch: engine mounts the site's typed columns"), || "{each ${Elem.platform_describe(template)}}")
	}

	## Recursive keyed rows: one site whose rows may have child rows of the same
	## type, at any depth. `node_template` runs once for the whole tree; place
	## `Ui.children(row, project)` inside it to say where a row's children go.
	## Needed because a nested `Ui.each` per level would give every depth a
	## new context type, which is polymorphic recursion (see report).
	tree : r, (RowRef(Up(ctx, node), node) -> Elem(Site(Up(ctx, node), node))) -> Elem(ctx)
		where [
			r.to_val : r -> Val(ctx, Rows(node)),
			node.is_eq : node, node -> Bool,
		]
	tree = |rows, node_template| {
		_source = rows.to_val()
		template = node_template(RowRef)
		Elem.platform_erased(Each, |_ctx| site_mount(template, "sketch: engine mounts the tree site"), || "{tree ${Elem.platform_describe(template)}}")
	}

	## Where this row's children render, instantiating the enclosing tree's
	## template again one level down.
	children : RowRef(Up(ctx, node), node), (node -> Rows(node)) -> Elem(Site(Up(ctx, node), node))
		where [
			node.is_eq : node, node -> Bool,
		]
	children = |_row, _project| Elem.platform_erased(Each, |_ctx| crash "sketch: engine re-enters the tree template", || "{children}")
}

## One row projection, built once for the site, reads every row from that
## row's context: the engine supplies the context, the template captures none.
expect {
	row : Ui.RowRef(Ui.Root, { id : Str, label : Str })
	row = RowRef
	label = row.field(|item| item.label)
	class = row.select(Signal.const("2").keyed("danger", ""))
	first : Ui.Site(Ui.Root, { id : Str, label : Str })
	first = { outer: Root, key: "1", item: { id: "1", label: "one" } }
	second : Ui.Site(Ui.Root, { id : Str, label : Str })
	second = { outer: Root, key: "2", item: { id: "2", label: "two" } }
	actual = [Val.platform_eval(label, first), Val.platform_eval(label, second), Val.platform_eval(class, first), Val.platform_eval(class, second)]
	actual == ["one", "two", "", "danger"]
}
