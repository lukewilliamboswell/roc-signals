import Erased exposing [Erased]

## Roc-owned getter and capability token for typed values in erased descriptors.
HostValue := { payload : Erased, token : U64 }.{

	## Identity and typed equality retained by the Roc runtime for each capability.
	CapabilityHandle := {
        token : U64,
		eq : HostValue, HostValue -> Bool,
	}

	## Text reader paired with the capability that validates the value.
	TextReadHandle := {
		capability : CapabilityHandle,
		read : HostValue -> Str,
	}

	## Bool reader paired with the capability that validates the value.
	BoolReadHandle := {
		capability : CapabilityHandle,
		read : HostValue -> Bool,
	}

	## Event reducer paired with the read-state and payload capabilities it expects.
	EventReducerHandle := {
		capability : CapabilityHandle,
		read_capability : CapabilityHandle,
		transform : HostValue, HostValue, HostValue -> HostValue,
	}

	## Reusable state-value recipe. Each execution creates an independently
	## owned Roc value; shared copies follow ordinary ARC ownership.
	StateValueHandle := {
		capability : CapabilityHandle,
		initial : Box((() -> HostValue)),
	}


	## Duplication and destruction follow ordinary Roc value ownership.
	clone : HostValue -> HostValue
	clone = |value| value

	store : Box(a), CapabilityHandle -> HostValue
	store = |boxed, cap| {
		value = Box.unbox(boxed)
		getter : () -> a
		getter = || value
		{ payload: Erased.erase!(Box.box(getter)), token: cap.token }
	}

	## The getter keeps its capture while producing an independently owned value.
	read : HostValue, U64 -> a
	read = |value, expected| {
		getter : Box((() -> a))
		getter = Erased.restore!(value.payload, value.token, expected)
		(Box.unbox(getter))()
	}

	get_with_capability : HostValue, CapabilityHandle -> Box(a)
	get_with_capability = |value, cap| Box.box(HostValue.read(value, cap.token))
}
