## Opaque host-owned value handle used to move typed Roc values through erased
## platform descriptors.
HostValue := [HostValue(U64)].{

	## Erased operations the host uses to own values with a Roc type capability.
	CapabilityHandle := {
		clone : Box((HostValue -> HostValue)),
		drop : Box((HostValue -> {})),
		eq : Box((HostValue, HostValue -> Bool)),
	}

	## Text reader paired with the capability that validates the value.
	TextReadHandle := {
		capability : CapabilityHandle,
		read : Box((HostValue -> Str)),
	}

	## Bool reader paired with the capability that validates the value.
	BoolReadHandle := {
		capability : CapabilityHandle,
		read : Box((HostValue -> Bool)),
	}

	## Task request reader paired with the capability that validates the value.
	TaskRequestReadHandle := {
		capability : CapabilityHandle,
		read : Box((HostValue -> Str)),
	}

	## Event reducer paired with the payload capability it expects.
	EventReducerHandle := {
		capability : CapabilityHandle,
		transform : Box((HostValue, HostValue -> HostValue)),
	}

	## Clone a host-owned value.
	clone : HostValue -> HostValue

	## Store a boxed Roc value with a new capability.
	store_with_capability : Box(a), CapabilityHandle -> HostValue

	## Store a boxed Roc value using an existing host value's capability.
	store_with_existing_capability : Box(a), HostValue -> HostValue

	## Read a boxed Roc value through a capability without consuming it.
	get_with_capability : HostValue, CapabilityHandle -> Box(a)

	## Consume a host value and recover the boxed Roc value through a capability.
	take_with_capability : HostValue, CapabilityHandle -> Box(a)

	## Read by splitting a boxed value into retained and returned boxes.
	get_with_split : HostValue, Box((Box(a) -> { keep : Box(a), out : Box(a) })) -> Box(a)

	## Consume by splitting a boxed value into dropped and returned boxes.
	take_with_split : HostValue, Box((Box(a) -> { keep : Box(a), out : Box(a) })) -> Box(a)
}
