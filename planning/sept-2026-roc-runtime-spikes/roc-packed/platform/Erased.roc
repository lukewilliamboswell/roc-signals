## Opaque boxed callable. Only its owning capability may restore its signature.
## The erased function is never invoked; its compiler-supplied destructor owns
## the concrete captured fields independently of the erased return signature.
Erased := Box((() -> {})).{
	erase! : Box((() -> a)) -> Erased
	restore! : Erased, Box((() -> {})), Box((() -> {})) -> Box((() -> a))
}
