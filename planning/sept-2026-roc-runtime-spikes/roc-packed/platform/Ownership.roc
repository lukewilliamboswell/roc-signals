import Capability exposing [Capability]

## Exercises typed capture ownership independently of the graph scheduler.
Ownership := {}.{
	Payload : { name : Str, labels : List(Str), numbers : List(U64), callback : Box((U64 -> Str)) }

	check : U64 -> {}
	check = |seed| {
		name = "a dynamically allocated captured owner ${seed.to_str()} with long text"
		callback : U64 -> Str
		callback = |n| "${name}: callback ${n.to_str()}"
		cap : Capability(Payload)
		cap = Capability.new_with_eq(|_left, _right| False)
		carrier = Capability.store(Box.box({ name, labels: [name, "second ${name}"], numbers: List.repeat(seed, 32), callback: Box.box(callback) }), cap)
		first : Payload
		first = Box.unbox(Capability.get(carrier, cap))
		second : Payload
		second = Box.unbox(Capability.get(carrier, cap))
		changed = { ..first, numbers: first.numbers.set(0, seed + 1) ?? crash "missing first number", labels: first.labels.set(0, "replacement ${name}") ?? crash "missing first label" }
		if (second.numbers.get(0) ?? crash "missing number") != seed { crash "read aliases mutable numbers" }
		if (second.labels.get(0) ?? crash "missing label") != name { crash "read aliases mutable labels" }
		if (changed.numbers.get(0) ?? crash "missing changed number") != seed + 1 { crash "copy did not update" }
		# Dropping the carrier releases only its owner, not either typed read.
		(Box.unbox(Capability.drop(cap)))(carrier)
		if (Box.unbox(second.callback))(seed) != "${name}: callback ${seed.to_str()}" { crash "captured callback lost ownership" }
		next_seed = seed + 1
		if (Box.unbox(changed.callback))(next_seed) != "${name}: callback ${next_seed.to_str()}" { crash "changed copy callback lost ownership" }
		{}
	}
}
