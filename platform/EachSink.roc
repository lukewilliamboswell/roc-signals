## Hosted sinks used to append one keyed-collection entry to the active
## generation-scoped collection transaction.
EachSink := {}.{

	## Append one owned string key for `item_handle` to the active sink token.
	## The returned token is threaded through Roc so every push remains ordered.
	push_key! : U64, U64, Str -> U64

	## Append one boolean item for `item_handle` to the active sink token.
	## The returned token is threaded through Roc so every push remains ordered.
	push_bool! : U64, U64, Bool -> U64
}
