## A host-owned slot holding one opaque `Box(a)` ownership unit.
Cell := [Cell(U64)].{
	## Move a box into a new host slot.
	store! : Box(a) => Cell

	## Variant A: the host increments the outer box and returns an alias; the
	## slot keeps its own unit.
	alias! : Cell => Box(a)

	## Variant B: the host calls the app-compiled share closure, moving the
	## slot's unit in, writing `keep` back, and returning `out`.
	share! : Cell, Box((Box(a) -> { keep : Box(a), out : Box(a) })) => Box(a)

	## Move the box out of the slot, which becomes vacant.
	take! : Cell => Box(a)

	## The outer box refcount word of the slot.
	rc! : Cell => I64

	## True when both slots hold the same box pointer.
	same! : Cell, Cell => Bool

	## Live Roc allocations according to the host ledger.
	live! : () => U64

	## A value the optimizer cannot see, so test data is built at runtime.
	seed! : () => U64

	## Record one assertion.
	check! : U64, Bool => {}
}
