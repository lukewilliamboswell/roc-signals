PolyRec := [].{
	Nest(ctx) :: [Nest(ctx)]

	## Annotated polymorphic recursion: the recursive call is at `Nest(ctx)`.
	depth : ctx, U64 -> U64
	depth = |ctx, n|
		if n == 0 {
			0
		} else {
			1 + depth(Nest(ctx), n - 1)
		}
}

## Calling it forces a specialization.
expect PolyRec.depth({}, 3) == 3
