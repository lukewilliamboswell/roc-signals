import HostValue exposing [HostValue]

Bridge := {}.{
	## Private alias token: used only by the platform, never exposed to apps.
	identity! : Box(a) -> U64
	require_owners : HostValue.CapabilityHandle, HostValue, HostValue -> {}
	require_owners = |cap, a, b| if Bridge.identity!(a.token) != Bridge.identity!(cap.token) or Bridge.identity!(b.token) != Bridge.identity!(cap.token) { crash "CapabilityMismatch" } else { {} }
	drop : HostValue.CapabilityHandle, HostValue -> {}
	drop = |_cap, _value| {}
}
