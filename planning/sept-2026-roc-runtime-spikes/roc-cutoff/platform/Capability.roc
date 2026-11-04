import HostValue exposing [HostValue]

## Typed comparison stays with the typed edge; erased handles carry only identity.
Capability(a) := [Capability({ token : Box((() -> {})), is_equal : a, a -> Bool })].{
	new_with_eq : (a, a -> Bool) -> Capability(a)
	new_with_eq = |is_equal| Capability({ token: Box.box(|| {}), is_equal })

	new : () -> Capability(a) where [a.is_eq : a, a -> Bool]
	new = || Capability.new_with_eq(|a, b| a.is_eq(b))

	handle : Capability(a) -> HostValue.CapabilityHandle
	handle = |Capability(cap)| { token: cap.token }

	eq : Capability(a) -> Box((HostValue, HostValue -> Bool))
	eq = |Capability(cap)| Box.box(|left, right| (cap.is_equal)(HostValue.read(left, cap.token), HostValue.read(right, cap.token)))

	drop : Capability(a) -> Box((HostValue -> {}))
	drop = |_| Box.box(|_value| {})

	store : Box(a), Capability(a) -> HostValue
	store = |boxed, cap| HostValue.store(boxed, Capability.handle(cap))

	get : HostValue, Capability(a) -> Box(a)
	get = |value, Capability(cap)| Box.box(HostValue.read(value, cap.token))

	take : HostValue, Capability(a) -> Box(a)
	take = |value, Capability(cap)| Box.box(HostValue.read(value, cap.token))

	## Compare before erasing/allocating the replacement getter.
	change : a, HostValue.Previous, Capability(a) -> HostValue.Change
	change = |next, previous, Capability(cap)| {
		unchanged = match previous {
			Initial => False
			Previous(old) => (cap.is_equal)(HostValue.read(old, cap.token), next)
		}
		if unchanged { Unchanged } else { Changed(HostValue.store(Box.box(next), { token: cap.token })) }
	}
}
