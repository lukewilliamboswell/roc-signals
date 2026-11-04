import HostValue exposing [HostValue]

Bridge := {}.{
	## Private alias token: used only by the platform, never exposed to apps.
	identity! : Box(a) -> U64
	## A private non-reused capability identity; it owns no payload or heap cell.
	fresh! : {} -> U64
	equal : HostValue.CapabilityHandle, HostValue, HostValue -> Bool
	equal = |cap, a, b| (cap.eq)(a, b)
	drop : HostValue.CapabilityHandle, HostValue -> {}
	drop = |_cap, _value| {}
}
