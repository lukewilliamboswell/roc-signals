import HostValue exposing [HostValue]

Bridge := {}.{
	## Private alias token: used only by the platform, never exposed to apps.
	identity! : Box(a) -> U64
	equal : HostValue.CapabilityHandle, HostValue, HostValue -> Bool
	equal = |cap, a, b| (Box.unbox(cap.eq))(a, b)
	drop : HostValue.CapabilityHandle, HostValue -> {}
	drop = |_cap, _value| {}
}
