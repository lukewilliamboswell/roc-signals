Repro := [].{
	Inputs : { title : U64 }

	view : Inputs -> Str
	view = |_inputs| "ok"

	bad : Str -> Str
	bad = |title| view({ title })
}
