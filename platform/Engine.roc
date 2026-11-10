import Core

## The authoring API of the roc-signals web platform: the reactive engine as an
## app sees it.
##
## An app describes its UI as an [Elem] tree over typed reactive values ([Val])
## and state layers ([State]); `program` turns that description into the
## [Program] the host drives. The engine mounts the tree once, then runs one
## transaction per DOM event or effect result: handlers write states, and only
## the text, attributes, rows and sites that read a changed layer are
## re-evaluated, emitting DOM commands for values that actually changed.
##
## Every dynamic site (`state`, `derive`, `when`, `switch`, `each`,
## `component`, effect sites) is one closure that owns its typed storage, so
## updates happen in place. `design.md` ("Representation D") describes the
## model; Appendix B specifies the command stream and the host protocol.
##
## Every type here is opaque: an app builds values with the functions below
## and never sees their representation. The engine itself is the platform's
## internal `Core` module.
Engine := [].{

	## The context at the top of the application: the context of the [Elem] that
	## `program`'s view returns. Nested contexts ([In], [Row], [Comp]) are built
	## on top of it.
	Root : Core.Root

	## The context inside a `state` or `derive` body: a layer holding a value of
	## type `s`, nested in `outer`. Values and handlers from `outer` enter with
	## `lift`.
	In(outer, s) : Core.In(outer, s)

	## The context inside one row of an `each` template: the row's key and item,
	## nested in `outer`. Values and handlers from `outer` enter with `lift_row`.
	Row(outer, item) : Core.Row(outer, item)

	## The context inside a `component` body: the prop of type `p` and the outward
	## action list of type `List(a)`. A body typed over `Comp(p, a)` is specialised
	## once per prop and action type, not once per call site.
	Comp(p, a) : Core.Comp(p, a)

	## A reactive value of type `a`, readable in context `ctx`.
	##
	## A value records which layers it reads, so only the text, attributes and sites
	## that read a changed layer are re-evaluated. Make one with `const`,
	## `State.val`, a [RowRef] accessor or `derive`, and transform it with `map` and
	## `map2`. A value is a recipe, not a cache: mapping functions run each time a
	## reader is re-evaluated, so they must be pure and should be cheap (`derive`
	## memoises an expensive or shared result).
	Val(ctx, a) :: { v : Core.Val(ctx, a) }.{

		## Transform a value with a pure function. The result reads the same layers
		## as the input; the function runs wherever the result is read, each time a
		## read layer changes.
		map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		map = |{ v }, f| { v: v.map(f) }

		## Combine two values with a pure function. The result reads the union of
		## both inputs' layers.
		map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		map2 = |l, r, f| { v: l.v.map2(r.v, f) }

		## Use a value from the enclosing context inside a `state` or `derive` body
		## nested in it. The value keeps reading the same layers.
		lift : Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |{ v }| { v: v.lift() }

		## Use a value from the enclosing context inside an `each` row template
		## nested in it. The value keeps reading the same layers.
		lift_row : Val(ctx, a) -> Val(Row(ctx, item), a)
		lift_row = |{ v }| { v: v.lift_row() }
	}

	## An event handler usable in context `ctx`: a write to one state layer that
	## also receives the event's payload (an input's value, `"true"`/`"false"` for
	## a checkbox, `""` for a click). Make one with the [State] methods and attach
	## it with `on`, `on_click` or an `Html` control. A handler runs once per event,
	## in the transaction that delivers it.
	Handler(ctx) :: { h : Core.Handler(ctx) }.{

		## Use a handler from the enclosing context inside a `state` or `derive` body
		## nested in it.
		lift : Handler(ctx) -> Handler(In(ctx, s))
		lift = |{ h }| { h: h.lift() }

		## Use a handler from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : Handler(ctx) -> Handler(Row(ctx, item))
		lift_row = |{ h }| { h: h.lift_row() }
	}

	## A handle on one `state` layer holding an `s`, usable in context `ctx`.
	##
	## Read it with `val`; write it only through handlers (`update`, `set_value`,
	## ...) and reactions (`on_result`). A write marks the layer changed and its
	## readers refresh; equality pruning happens where the value is read (text,
	## attributes, rows, `derive`), not at the state, so a reducer that returns an
	## equal value still costs a refresh pass but emits no DOM commands. Reducers
	## receive the value uniquely owned, so list and record updates happen in place.
	State(ctx, s) :: { s : Core.State(ctx, s) }.{

		## The state's current value.
		val : State(ctx, s) -> Val(ctx, s)
		val = |{ s }| { v: s.val() }

		## A handler that replaces the state with `f` of it, ignoring the event's
		## payload.
		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ s }, f| { h: s.update(f) }

		## A handler whose reducer also receives `v`, read in the handler's context
		## when the event fires (typically the row key or a row field), so a row's
		## handler needs no captured row.
		update_by : State(ctx, s), Val(ctx, b), (s, b -> s) -> Handler(ctx)
		update_by = |{ s }, b, f| { h: s.update_by(b.v, f) }

		## An effect site's [Reaction] that writes this state: the reducer receives
		## the value the request was issued for and its [Res]. If the state has been
		## disposed by the time a reparented result arrives, the write is skipped and
		## counted (`skipped`).
		on_result : State(ctx, s), (s, a, Res -> s) -> Reaction(ctx, a)
		on_result = |{ s }, f| s.on_result(f)

		## A handler whose reducer receives the event's payload, such as an input's
		## new value or `"true"`/`"false"` from a checkbox.
		set_value : State(ctx, s), (s, Str -> s) -> Handler(ctx)
		set_value = |{ s }, f| { h: s.set_value(f) }

		## A handler whose reducer receives both `v`, read when the event fires, and
		## the event's payload.
		set_value_by : State(ctx, s), Val(ctx, b), (s, b, Str -> s) -> Handler(ctx)
		set_value_by = |{ s }, b, f| { h: s.set_value_by(b.v, f) }

		## For a component's outward action list (the second argument of a `component`
		## body): a handler that appends `a`. After the event settles, the boundary
		## hands each pushed action, in order, to the caller's [Sink].
		push : State(ctx, List(a)), a -> Handler(ctx)
		push = |{ s }, a| { h: s.push(a) }

		## Like `push`, appending an action built from `v` read when the event fires
		## (typically the row key).
		push_by : State(ctx, List(a)), Val(ctx, b), (b -> a) -> Handler(ctx)
		push_by = |{ s }, b, f| { h: s.push_by(b.v, f) }

		## Like `push`, appending an action built from `v` read when the event fires
		## and the event's payload.
		push_value_by : State(ctx, List(a)), Val(ctx, b), (b, Str -> a) -> Handler(ctx)
		push_value_by = |{ s }, b, f| { h: s.push_value_by(b.v, f) }

		## Use a state handle from the enclosing context inside a `state` or `derive`
		## body nested in it.
		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ s }| { s: s.lift() }

		## Use a state handle from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : State(ctx, s) -> State(Row(ctx, item), s)
		lift_row = |{ s }| { s: s.lift_row() }
	}

	## A keyed selection for `RowRef.select`: the selected key and the values a
	## selected and an unselected row see. Make one with `keyed`.
	Keyed(ctx, v) : Core.Keyed(ctx, v)

	## `keyed(selected, yes, no)`: rows whose key equals `selected` see `yes`, all
	## others `no`. Read through `RowRef.select`, a change of `selected`
	## re-evaluates exactly the previously and the newly selected rows instead of
	## every row.
	keyed : Val(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sel, yes, no| Core.keyed(sel.v, yes, no)

	## The current row of an `each` template. The template runs once per `each`
	## site, not once per row, so it reads the row through these accessors rather
	## than receiving a row value.
	RowRef(outer, item) :: { r : Core.RowRef(outer, item) }.{

		## The row's key. It is fixed for the row's lifetime, so it never triggers a refresh.
		key : RowRef(outer, item) -> Val(Row(outer, item), Str)
		key = |{ r }| { v: r.key() }

		## A projection of the row's item. It is re-evaluated only for rows whose new
		## item differs from the old one.
		field : RowRef(outer, item), (item -> a) -> Val(Row(outer, item), a)
		field = |{ r }, f| { v: r.field(f) }

		## `yes` or `no` from a [Keyed] selection, depending on whether this row's key
		## is the selected one.
		select : RowRef(outer, item), Keyed(outer, v) -> Val(Row(outer, item), v)
		select = |{ r }, kd| { v: r.select(kd) }
	}

	## An attribute, event listener or focus reference on an element, in context
	## `ctx`. Make one with `attr`, `attr_v`, `class`, `class_v`, `test_id`,
	## `test_id_v`, `on`, `on_click` or `ref`.
	Attr(ctx) : Core.Attr(ctx)

	## A piece of UI in context `ctx`: an element, a text node or a dynamic site
	## (`state`, `derive`, `when`, `switch`, `each`, `component` or an effect site).
	## An `Elem` is a description; the engine mounts it once and afterwards updates
	## only what reads a changed layer.
	Elem(ctx) : Core.Elem(ctx)

	## `state(init, body)` adds a state layer, starting at `init`, for the elements
	## `body` builds. There is one instance per mount of the site (so one per row
	## inside an `each` row) and it lives as long as the enclosing scope: it is
	## dropped when its branch, row or component is disposed, and starts again at
	## `init` if remounted. Values from the enclosing context enter `body` with
	## `lift`. More than 63 nested `state`, `derive` or `each` layers within one
	## component is a `resource_limit` error.
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Core.state(init, |s| body({ s: s }))

	## `each(rows, key, template)` renders one row per item of `rows`, identified by
	## `key(item)`. Rows are matched by key across updates: a surviving row is kept
	## (and moved if needed) rather than rebuilt, a row whose item is unchanged does
	## no work, and a changed item re-evaluates only that row's holes that read it.
	##
	## `template` runs once per site against a [RowRef] and must return a single
	## element. A duplicate key is a contract error, as is a focus `ref` directly in
	## the row template (put it in a nested site instead).
	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Core.each(rows.v, key, |r| template({ r: r }))

	## `when(cond, yes, no)` builds only the branch `cond` selects, and rebuilds it
	## when `cond` changes, disposing the old branch with everything it owns.
	## Because the unselected branch is never built, recursive UI can be expressed
	## directly.
	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Core.when(cond.v, yes, no)

	## `switch(sel, cases, body)` builds `body(k)` for the current value `k` of
	## `sel`, and rebuilds it when `sel` changes to a different case. `cases` lists
	## every value `sel` can take, so the site listens to everything any branch
	## could read; a value outside `cases` is a contract error.
	switch : Val(ctx, k), List(k), (k -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	switch = |sel, cases, body| Core.switch(sel.v, cases, body)

	## `derive(input, body)` evaluates `input` once per change of the layers it
	## reads and gives `body` the result as a new layer. Readers inside `body` that
	## read only the derived value do no work while it is equal to the previous
	## result, so use `derive` for a value that is expensive or read in many
	## places. Values from the enclosing context enter `body` with `lift`.
	derive : Val(ctx, a), (Val(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Core.derive(input.v, |v| body({ v: v }))

	## Where a component's outward actions go in the caller: each action becomes a
	## write of a caller state. Make one with `sink`, or route actions to two sinks
	## with `split`.
	Sink(ctx, a) : Core.Sink(ctx, a)

	## A [Sink] that folds each action into state `st` with the reducer `f`.
	sink : State(ctx, s), (s, a -> s) -> Sink(ctx, a)
	sink = |{ s }, f| Core.sink(s, f)

	## A [Sink] that drops every action, for a component that reports none.
	discard : {} -> Sink(ctx, a)
	discard = |_| Core.discard({})

	## A [Sink] that routes each action to one of two sinks: `route` tags it `L`
	## for the first or `R` for the second.
	split : Sink(ctx, a), Sink(ctx, b), (c -> [L(a), R(b)]) -> Sink(ctx, c)
	split = |left, right, route| Core.split(left, right, route)

	## `component(prop, sink, body)` mounts a reusable piece of UI with its own
	## context. `body` sees the prop as a value read from the caller (re-read, not
	## retained, whenever a caller layer it reads changes) and a handle on its
	## outward action list; actions pushed during an event are delivered, in order,
	## to `sink` when the event settles. The body is specialised once per prop and
	## action type, which keeps code size bounded as an app grows.
	component : Val(ctx, p), Sink(ctx, a), (Val(Comp(p, a), p), State(Comp(p, a), List(a)) -> Elem(Comp(p, a))) -> Elem(ctx)
	component = |prop, out, body| Core.component(prop.v, out, |p, s| body({ v: p }, { s: s }))

	## A request from an effect site.
	##
	## Commands are emitted and forgotten: `Push` and `Replace` (history), `Title`,
	## `StorageSet` and `StorageRemove` (local storage), and `Focus`, `Blur` and
	## `SelectText` on a reference named with `ref` (resolved at the end of the
	## turn; a reference that is not mounted then is counted stale).
	##
	## Awaited requests deliver results to the site's [Reaction]: `Http`,
	## `StorageGet` and `Timer` deliver one; `Interval`, `Popstate`,
	## `OnlineChanges` and `VisibilityChanges` are subscriptions that deliver any
	## number until their site is disposed. `Self` asks for a follow-up turn whose
	## result is `Now`, so a site can write state in response to its value changing.
	## `Http`'s `timeout_ms` of 0 means no timeout; it is capped at 10 minutes.
	##
	## `Work` runs the pure program registered under `program` (see
	## `Program.with_workers`) on `input`, off the page's thread, and delivers one
	## `Work(output)` or `WorkLost(fault)`. Like a timer it belongs to its site:
	## disposing the site cancels it. `deadline_ms` 0 means no deadline; it is
	## capped at 10 minutes and delivers `Timeout` when it expires. Issuing work
	## for a program that is not registered is a contract error.
	Req : [
		## `timeout_ms` 0 = no timeout; capped at `max_timeout_ms`.
		Http({ method : Str, url : Str, headers : List((Str, Str)), body : Str, timeout_ms : U32 }),
		StorageGet(Str),
		Timer(U32),
		Work({ program : Str, input : List(U8), deadline_ms : U32 }),
		Interval(U32),
		Popstate,

		## Subscriptions to the browser's connectivity (`online`/`offline`)
		## and page visibility (`visibilitychange`). Each change delivers
		## `Online(Bool)` or `Visible(Bool)`; the value at mount is in `Boot`.
		OnlineChanges,
		VisibilityChanges,
		Self,
		Push(Str),
		Replace(Str),
		Title(Str),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		StorageSet(Str, Str),
		StorageRemove(Str),
	]

	## The result of an awaited request: an HTTP response (`Http`, with any status),
	## a network failure (`Network`) or `Timeout`, a storage `Value` or `Missing`, a
	## timer or interval tick (`Fired`), the URL after `Popstate` (`Location`), a
	## connectivity or visibility change (`Online`, `Visible`), a `Self` follow-up
	## (`Now`), `Refused` when the in-flight bound turned the request away, or a
	## worker program's output (`Work`) or the reason it produced none
	## (`WorkLost`).
	Res : [Http({ status : U16, headers : List((Str, Str)), body : Str }), Network(Str), Timeout, Value(Str), Missing, Fired, Location(Str), Online(Bool), Visible(Bool), Now, Refused, Work(List(U8)), WorkLost(WorkFault)]

	## Why a `Work` request produced no output: the worker's instance faulted
	## running the program (`Contract`, `ResourceLimit`, `OutOfMemory`,
	## `AppCrash` and `ExpectFailed`, the fault classes of an instance), the
	## browser has no workers (`Unavailable`), or the worker itself failed
	## (`Executor`). The diagnostic goes to the page's console, never into the
	## result.
	WorkFault : [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## Why an HTTP request did not produce a successful response, as `http_text`
	## reports it: the browser could not reach the server (`Network`, with the
	## browser's message), the request's `timeout_ms` expired (`Timeout`), the
	## server answered outside 2xx (`Status`), or the in-flight bound refused the
	## request (`Refused`).
	HttpError : [Network(Str), Timeout, Status(U16), Refused]

	## An HTTP result as the body of a 2xx response or a typed [HttpError]. Apps
	## that classify statuses themselves match on `Http` directly. Any result that
	## is not from an HTTP request is a contract error.
	http_text : Res -> Try(Str, HttpError)
	http_text = |res| Core.http_text(res)

	## What an effect site does with a result: a write to a state given the value
	## the request was issued for and the [Res]. Make one with `State.on_result`,
	## or use `ignore`.
	Reaction(ctx, a) : Core.Reaction(ctx, a)

	## A reaction that discards every result, for sites that only issue commands.
	ignore : {} -> Reaction(ctx, a)
	ignore = |_| Core.ignore({})

	## `on_cleanup(name, v, plan)` runs `plan` on `v`, read in the scope's last
	## environment, when the scope this site is mounted in is disposed, and issues
	## the requests in the disposing turn. Only commands are allowed (history,
	## title, storage writes, focus): a request that awaits a result would outlive
	## its owner, so it is a contract error. Each run is counted by `name`. The site
	## renders nothing and reads nothing while it is live.
	on_cleanup : Str, Val(ctx, a), (a -> List(Req)) -> Elem(ctx)
	on_cleanup = |name, v, plan| Core.on_cleanup(name, v.v, plan)

	## A cleanup site that issues nothing and only counts its runs under `name`.
	cleanup : Str -> Elem(ctx)
	cleanup = |name| Core.cleanup(name)

	## `watch(v, plan, react)` issues `plan(v)` when the site mounts and again
	## whenever `v` changes to an unequal value; results go to `react`. Awaited
	## requests belong to the site: when it is disposed, its subscriptions, timers
	## and work are cancelled, and admitted `Http` and `StorageGet` requests are
	## delivered to the nearest surviving ancestor instead. At most 32 requests are
	## in flight by default (see `program_boot`); beyond that a request is answered
	## with `Refused`.
	watch : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch = |v, plan, react| Core.watch(v.v, plan, react)

	## Like `watch`, but issues only when `v` changes after mount, never for its
	## initial value.
	on_change : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	on_change = |v, plan, react| Core.on_change(v.v, plan, react)

	## What the host knows before the first render: the URL, the declared storage
	## keys' values (missing keys are absent), whether the browser is online and
	## the page visible, and whether local storage is available at all. When it is
	## not, the storage list is empty and `StorageSet`/`StorageRemove` do not
	## persist, so an app that relies on reloads surviving can say so.
	Boot : { url : Str, storage : List((Str, Str)), online : Bool, visible : Bool, storage_available : Bool }

	## The boot value of a declared storage key, or `Missing` if it has none.
	boot_storage : Boot, Str -> Try(Str, [Missing])
	boot_storage = |boot, key| Core.boot_storage(boot, key)

	## A value that never changes. It reads no layer, so it never triggers a refresh.
	const : a -> Val(ctx, a)
	const = |value| { v: Core.const(value) }

	## `element(tag, attrs, children)`: an HTML element. `Html` offers typed
	## helpers for common elements and controls.
	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Core.element(tag, attrs, kids)

	## A static text node.
	text : Str -> Elem(ctx)
	text = |s| Core.text(s)

	## A text node whose content follows a value; the DOM is written only when
	## the text changes.
	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |{ v }| Core.text_v(v)

	## A static attribute.
	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Core.attr(name, value)

	## An attribute that follows a value; the DOM is written only when it changes.
	## An empty string removes the attribute. `value` and `checked` update the
	## control's live state (a focused text control keeps the user's draft until
	## blur).
	attr_v : Str, Val(ctx, Str) -> Attr(ctx)
	attr_v = |name, { v }| Core.attr_v(name, v)

	## A static `class` attribute.
	class : Str -> Attr(ctx)
	class = |c| Core.class(c)

	## A `class` attribute that follows a value.
	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |{ v }| Core.class_v(v)

	## A static `data-testid` attribute, for spec locators.
	test_id : Str -> Attr(ctx)
	test_id = |id| Core.test_id(id)

	## A `data-testid` attribute that follows a value.
	test_id_v : Val(ctx, Str) -> Attr(ctx)
	test_id_v = |{ v }| Core.test_id_v(v)

	## `on(event, handler)` listens for a DOM event by name (`"input"`, `"keydown"`,
	## ...). A `:prevent` suffix (`"click:prevent"`) calls `preventDefault` when the
	## handler runs. The handler's payload depends on the event type (design.md,
	## Appendix B).
	on : Str, Handler(ctx) -> Attr(ctx)
	on = |ev, { h }| Core.on(ev, h)

	## Name this element as a focus reference for `Focus`, `Blur` and `SelectText`
	## requests, so the app never handles engine node ids. A name refers to one
	## element at a time (the latest mounted wins) and is released when that
	## element is removed. A `ref` directly in an `each` row template is a contract
	## error; put it in a nested site.
	ref : Str -> Attr(ctx)
	ref = |name| Core.ref(name)

	## A `click` listener; its payload is empty.
	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |{ h }| Core.on_click(h)

	## What the host drives: an app built with `program` or `program_boot`, bound
	## as the app's `main`. The platform mounts it with the boot data and runs one
	## transaction per DOM event or effect result. `with_workers` adds the worker
	## programs its `Work` requests may name:
	## `Engine.program(view).with_workers([Engine.registration("example.org/x", run)])`.
	Program : Core.Program

	## A worker program for `Program.with_workers`. Make one with `registration`.
	Registration : Core.Registration

	## `registration(name, run)`: the worker program `name`, which turns a `Work`
	## request's input bytes into its output bytes with `run`. Names are
	## namespaced and unversioned (`"example.org/search/filter"`): every instance
	## runs the same compiled module, so a name means one function. `run` must be
	## pure; it runs in a separate instance that shares nothing with the page but
	## the bytes it is given, and a crash there poisons that worker instance only
	## and is delivered as `WorkLost`.
	registration : Str, (List(U8) -> List(U8)) -> Registration
	registration = |name, run| Core.registration(name, run)

	## The [Program] for an app that needs no boot data: mount `view()` with the
	## default in-flight bound of 32.
	program : (() -> Elem(Root)) -> Program
	program = |view| Core.program(view)

	## The [Program] for an app that reads boot data: the host reads
	## `storage_keys` from local storage before mount, and `view` receives them in
	## the [Boot] with the URL and connectivity. `max_inflight` bounds the awaited
	## requests in flight at once.
	program_boot : { storage_keys : List(Str), max_inflight : U64 }, (Boot -> Elem(Root)) -> Program
	program_boot = |cfg, view| Core.program_boot(cfg, view)
}
