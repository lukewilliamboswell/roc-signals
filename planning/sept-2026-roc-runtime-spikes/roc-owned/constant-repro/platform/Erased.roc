Erased := Box((() -> {})).{
	erase! : Box((() -> a)) -> Erased
	restore! : Erased -> Box((() -> a))
}
