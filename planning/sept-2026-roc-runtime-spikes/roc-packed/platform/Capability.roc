import HostValue exposing [HostValue]

## Same typed capability API; values now have ordinary Roc ARC ownership.
Capability(a) := [Capability(HostValue.CapabilityHandle)].{
	new_with_eq : (a, a -> Bool) -> Capability(a)
	new_with_eq = |is_equal| {
		token = Box.box(|| {})
		eq : HostValue, HostValue -> Bool
		eq = |left, right| {
			l : a
			l = HostValue.read(left, token)
			r : a
			r = HostValue.read(right, token)
			is_equal(l, r)
		}
		Capability({ token, eq })
	}

	new : () -> Capability(a)
		where [a.is_eq : a, a -> Bool]
	new = || Capability.new_with_eq(|a, b| a.is_eq(b))

	handle : Capability(a) -> HostValue.CapabilityHandle
	handle = |Capability(cap)| cap

	eq : Capability(a) -> Box((HostValue, HostValue -> Bool))
	eq = |Capability(cap)| Box.box(cap.eq)

	drop : Capability(a) -> Box((HostValue -> {}))
	drop = |_| Box.box(|_value| {})

	store : Box(a), Capability(a) -> HostValue
	store = |boxed, Capability(cap)| HostValue.store(boxed, cap)

	get : HostValue, Capability(a) -> Box(a)
	get = |value, Capability(cap)| Box.box(HostValue.read(value, cap.token))

	take : HostValue, Capability(a) -> Box(a)
	take = |value, Capability(cap)| Box.box(HostValue.read(value, cap.token))
}
