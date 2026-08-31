import Node
import HostValue exposing [HostValue]

## UI element descriptor tree. Markup nodes (`Element`, `Text`, `TextSignal`)
## carry no identity. Scope/binder nodes are the identity-bearing positions the
## host walk accounts for:
## - `State`: introduces a state binder (boxed init thunk + boxed is_eq thunk)
##   and a child subtree built with that binder in scope. Advances the scope
##   ordinal.
## - `When`: a value-selected lazy branch. Its retained builder materializes only
##   the live subtree, which owns a branch scope. Advances the scope ordinal.
## - `Each`: a keyed list backed by an immutable collection capability. Each row
##   is its own scope keyed by exact UTF-8 bytes. The row thunk receives the
##   host-owned key and stable row handle. Advances the scope ordinal.
## - `Component`: introduces a reusable local scope for helper-owned state.
##   Advances the parent scope ordinal and collects the child under a component
##   scope whose internal ordinals are local to the component instance.
## - `OnChange`: a non-rendering sink that runs a host command when a signal's
##   value changes, optionally including the first mounted value.
## - `OnMount`: a non-rendering sink that runs a host command when the owning
##   scope first enters the live tree.
## - `Cleanup`: a non-rendering descriptor run when the owning scope is disposed.
Elem := [
	Component({ child : Box(Elem) }),
	Cleanup({ cleanup : Node.Cleanup }),
	Element({ tag : Str, attrs : List(Node.Attr), children : List(Elem) }),
	OnChange({ signal : Box(Node.SignalExpr), to_cmd : Box((HostValue -> Node.Cmd)) }),
	OnChangeInitial({ signal : Box(Node.SignalExpr), to_cmd : Box((HostValue -> Node.Cmd)) }),
	OnMount({ to_cmd : Box((() -> Node.Cmd)) }),
	Text(Str),
	TextSignal({ signal : Box(Node.SignalExpr), read : HostValue.TextReadHandle }),
	State({ binder : Node.BinderRef, initial : Box((() -> HostValue)), cap : HostValue.CapabilityHandle, child : Box(Elem) }),
	When(
		{
			condition : Box(Node.SignalExpr),
			ops : {
				case_capability : HostValue.CapabilityHandle,
				build : Box((HostValue -> Elem)),
			},
		},
	),
	Each(
		{
			items : Box(Node.SignalExpr),
			ops : {
				items_capability : HostValue.CapabilityHandle,
				item_capability : HostValue.CapabilityHandle,
				len : Box((HostValue -> U64)),
				copy_keys : Box((HostValue, U64 -> U64)),
				compare_pairs : Box((HostValue, HostValue, List(U64), U64 -> U64)),
				clone_item_at : Box((HostValue, U64 -> HostValue)),
				row : Box((Str, U64 -> Elem)),
			},
		},
	),
]
