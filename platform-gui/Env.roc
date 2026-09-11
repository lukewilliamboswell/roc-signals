## Process environment access for effect closures. These are hosted effectful
## functions: they can only be called from a `!` function, which on this
## platform means inside the closure given to `Effect.run`.
Env := [].{
	## Read one environment variable of the running process.
	var! : Str => Try(Str, [Missing])
}
