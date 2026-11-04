import Rows exposing [RowsGenerationCallable]

## Hosted sinks used by app-compiled `Rows` adapters. Every token identifies one
## active, call-scoped sink and is threaded through Roc so pushes stay ordered.
EachSink := {}.{

	## Describe a snapshot generation before the host reserves its exact storage.
	push_snapshot_description! : U64, RowsGenerationCallable, U64, U64 -> U64

	## Describe a delta generation and its authenticated immediate parent before
	## the host reserves operation and key storage.
	push_delta_description! : U64, RowsGenerationCallable, RowsGenerationCallable, U64, U64, U64, U64, U64 -> U64

	## Append one ordered stable slot and its owned exact UTF-8 key to a snapshot.
	push_snapshot! : U64, U64, U64, Str -> U64

	## Append a canonical clear operation at `op_index`.
	push_delta_clear! : U64, U64 -> U64

	## Insert `slot` before `before_slot`; zero denotes the end of the order.
	push_delta_insert! : U64, U64, U64, U64, Str -> U64

	## Remove `count` rows beginning at `first_slot`.
	push_delta_remove_range! : U64, U64, U64, U64 -> U64

	## Update the item and cached exact key belonging to `slot`.
	push_delta_update! : U64, U64, U64, Str -> U64

	## Move `count` rows beginning at `first_slot` before `before_slot`; zero
	## denotes the end of the order.
	push_delta_move_range! : U64, U64, U64, U64, U64 -> U64

	## Append one equality result for an ordered stable-slot pair.
	push_bool! : U64, U64, Bool -> U64
}
