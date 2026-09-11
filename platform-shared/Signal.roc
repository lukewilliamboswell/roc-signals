import HostValue exposing [HostValue]
import Capability exposing [Capability]
import Node

## Opaque, typed signal. Wraps a boxed pure `Node.SignalExpr` descriptor
## referencing state/source binders. The `a` lives only in Roc's type system.
## Runtime values are opaque host-owned cells; each edge carries the exact typed
## thunks that can read, compare, transform, and release that cell.
Signal(a) := { expr : Box(Node.SignalExpr), cap : Capability(a) }.{

	## One exact-key selector construction site shared by keyed rows.
	Keyed(value) := {
		input : Box(Node.SignalExpr),
		input_read : HostValue.TextReadHandle,
		false_init : Box((() -> HostValue)),
		true_init : Box((() -> HostValue)),
		cap : Capability(value),
	}.{

		## Build one ordinary keyed selector record for a stable row handle.
		for_row : Keyed(value), U64, Str -> Signal(value)
		for_row = |keyed, row_handle, key|
			Signal.from_expr(
				Node.SignalExpr.KeyedSelect(
					row_handle,
					keyed.false_init,
					keyed.input,
					key,
					keyed.input_read,
					keyed.false_init,
					keyed.true_init,
					Capability.handle(keyed.cap),
				),
				keyed.cap,
			)
	}

	## Copy a boxed signal expression descriptor.
	clone_expr : Box(Node.SignalExpr) -> Box(Node.SignalExpr)
	clone_expr = |expr| expr

	## Expose the host-readable expression descriptor for platform helpers.
	to_expr : Signal(a) -> Box(Node.SignalExpr)
	to_expr = |signal| signal.expr

	## Build a typed signal from a host descriptor and matching capability.
	from_expr : Node.SignalExpr, Capability(a) -> Signal(a)
	from_expr = |expr, cap| { expr: Box.box(expr), cap }

	## Command that intentionally performs no host work.
	noop : Node.Cmd
	noop = Node.Cmd.Noop

	## Create a named cleanup command for lifecycle testing and host effects.
	cleanup : Str -> Node.Cleanup
	cleanup = |name| Node.Cleanup.Cleanup(name)

	## Tick upward from zero every `period_ms` while mounted.
	interval : U64 -> Signal(U64)
	interval = |period_ms| {
		source_from_tick :
			a, (a -> a) -> Signal(a)
				where [
					a.is_eq : a, a -> Bool,
				]
		source_from_tick = |initial_value, next| {
			cap = Capability.new()

			initial : () -> HostValue
			initial = || Capability.store(Box.box(initial_value), cap)
			initial_box = Box.box(initial)

			tick : HostValue -> HostValue
			tick = |current_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, cap))
				Capability.store(Box.box(next(current)), cap)
			}

			{
				expr: Box.box(
					Node.SignalExpr.IntervalSource({
						token: initial_box,
						period_ms,
						cap: Capability.handle(cap),
						initial: initial_box,
						tick: Box.box(tick),
					}),
				),
				cap,
			}
		}

		source_from_tick(0, |current| current + 1)
	}

	## A constant signal.
	const : a -> Signal(a)
		where [
			a.is_eq : a, a -> Bool,
		]
	const = |value| {
		cap = Capability.new()
		init : () -> HostValue
		init = || Capability.store(Box.box(value), cap)
		init_box = Box.box(init)
		{
			expr: Box.box(
				Node.SignalExpr.ConstValue(
					init_box,
					init_box,
					Capability.handle(cap),
				),
			),
			cap,
		}
	}

	## Derived signal. The transform is a typed `a -> b`; the host passes opaque
	## cells and this thunk is the only place that can read the `a` input and
	## construct the `b` output cell.
	map : Signal(a), (a -> b) -> Signal(b)
		where [
			b.is_eq : b, b -> Bool,
		]
	map = |signal, f| {
		output_cap = Capability.new()
		wrapped : HostValue -> HostValue
		wrapped = |input_hv| {
			typed_input : a
			typed_input = Box.unbox(Capability.get(input_hv, signal.cap))
			typed_output : b
			typed_output = f(typed_input)
			Capability.store(Box.box(typed_output), output_cap)
		}
		transform_box = Box.box(wrapped)

		{
			expr: Box.box(
				Node.SignalExpr.Map(
					transform_box,
					signal.expr,
					transform_box,
					Capability.handle(output_cap),
				),
			),
			cap: output_cap,
		}
	}

	## Derived signal from two input signals.
	map2 : Signal(a), Signal(b), (a, b -> c) -> Signal(c)
		where [
			c.is_eq : c, c -> Bool,
		]
	map2 = |left, right, f| {
		output_cap = Capability.new()
		wrapped : HostValue, HostValue -> HostValue
		wrapped = |left_hv, right_hv| {
			left_v : a
			left_v = Box.unbox(Capability.get(left_hv, left.cap))
			right_v : b
			right_v = Box.unbox(Capability.get(right_hv, right.cap))
			output : c
			output = f(left_v, right_v)
			Capability.store(Box.box(output), output_cap)
		}
		transform_box = Box.box(wrapped)

		{
			expr: Box.box(
				Node.SignalExpr.Map2(
					transform_box,
					left.expr,
					right.expr,
					transform_box,
					Capability.handle(output_cap),
				),
			),
			cap: output_cap,
		}
	}

	## Test whether a selected string equals `key`. The host groups members by
	## their shared input and dirties only the old and new keys when it changes.
	select : Signal(Str), Str -> Signal(Bool)
	select = |selected, key| {
		output_cap = Capability.new()

		read_selected : HostValue -> Str
		read_selected = |input_hv| Box.unbox(Capability.get(input_hv, selected.cap))

		init_false : () -> HostValue
		init_false = || Capability.store(Box.box(False), output_cap)
		false_box = Box.box(init_false)

		init_true : () -> HostValue
		init_true = || Capability.store(Box.box(True), output_cap)

		{
			expr: Box.box(
				Node.SignalExpr.Select(
					false_box,
					selected.expr,
					key,
					{ capability: Capability.handle(selected.cap), read: Box.box(read_selected) },
					false_box,
					Box.box(init_true),
					Capability.handle(output_cap),
				),
			),
			cap: output_cap,
		}
	}

	## Prepare exact-key selected and unselected values once for a keyed-row site.
	keyed : Signal(Str), value, value -> Keyed(value)
		where [
			value.is_eq : value, value -> Bool,
		]
	keyed = |selected, when_selected, otherwise| {
		output_cap = Capability.new()
		read_selected : HostValue -> Str
		read_selected = |input_hv| Box.unbox(Capability.get(input_hv, selected.cap))
		init_false : () -> HostValue
		init_false = || Capability.store(Box.box(otherwise), output_cap)
		init_true : () -> HostValue
		init_true = || Capability.store(Box.box(when_selected), output_cap)
		{
			input: selected.expr,
			input_read: { capability: Capability.handle(selected.cap), read: Box.box(read_selected) },
			false_init: Box.box(init_false),
			true_init: Box.box(init_true),
			cap: output_cap,
		}
	}

	## Combine a list of same-typed signals into a signal of the list of values.
	combine : List(Signal(a)) -> Signal(List(a))
		where [
			a.is_eq : a, a -> Bool,
		]
	combine = |signals| Signal.combine_map(signals, |values| values)

	## Combine same-typed signals and project their values in the same graph node.
	## This is useful when the natural derived value is not itself a `List`, such
	## as a keyed `Rows` generation, and avoids an otherwise redundant `map` node.
	combine_map : List(Signal(a)), (List(a) -> b) -> Signal(b)
		where [
			b.is_eq : b, b -> Bool,
		]
	combine_map = |signals, project| {
		# Each input signal owns its own capability, so every element has to be
		# read back through the capability that stored it. Reading them all
		# through the first signal's capability fails at runtime as soon as the
		# inputs come from different call sites.
		input_caps = signals.map(|s| s.cap)
		output_cap = Capability.new()
		exprs = signals.map(|s| Box.unbox(Signal.clone_expr(s.expr)))
		transform : List(HostValue) -> HostValue
		transform = |items| {
			values : List(a)
			values = List.map2(items, input_caps, |host_value, cap| Box.unbox(Capability.get(host_value, cap)))
			Capability.store(Box.box(project(values)), output_cap)
		}
		transform_box = Box.box(transform)
		{
			expr: Box.box(
				Node.SignalExpr.Combine(
					transform_box,
					exprs,
					transform_box,
					Capability.handle(output_cap),
				),
			),
			cap: output_cap,
		}
	}
}
