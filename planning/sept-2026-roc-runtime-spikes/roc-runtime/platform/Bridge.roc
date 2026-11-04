import HostValue exposing [HostValue]

Bridge := {}.{
	## Private alias token: used only by the platform, never exposed to apps.
	identity! : Box(a) -> U64
	equal! : HostValue.CapabilityHandle, HostValue, HostValue -> Bool
	drop! : HostValue.CapabilityHandle, HostValue -> {}
}
