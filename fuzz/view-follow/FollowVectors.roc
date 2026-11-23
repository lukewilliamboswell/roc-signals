## Fixed histories of one table cell and one table view of it, each turn
## with the outcome it must have: how the view followed its table, the
## table's rows, changes and counts, the view's ordered keys, the keys
## drawn, and the changes of the rows drawn. Each vector gives the view's
## rebuild thresholds, the table's starting rows and the view's query and
## window; a turn hands its modifiers to the cell's generated modifier
## through `Store.after` and may bring a new query or window, and a turn
## marked `keep` keeps a copy of the table for later `Saved` and `Other`
## modifiers. `FuzzViewFollowProperty` replays each against its model
## (top-level `expect`s) and against `TableCore`, `View` and a table view
## site (its fixed examples), so all are held to these outcomes. Each
## vector's comment names the ways of following and the changes of the
## rows drawn it reaches.
##
## The operations, modifiers and records are those of
## `fuzz/table-changes/ChangeVectors.roc`; each target's package keeps its
## own copy of the types.
FollowVectors := [].{

	## An operation on a table, as in `ChangeVectors.Op`.
	Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), All, Undo]

	## A function handed to the cell's modifier, as in
	## `ChangeVectors.Modifier`.
	Modifier : [On(List(Op)), Saved(U64, List(Op)), Other(U64), Fresh(List((U64, U64)))]

	## What a table's changes say after a turn.
	Record : [Keyed(List({ key : U64, before : [Was(U64), Absent] })), Rewritten]

	## How the view followed its table, as `View.follow` answers.
	How : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])]

	## A change of the rows drawn, as `View.draw` answers.
	Change : [Left(U64), Entered({ key : U64, before : [Row(U64), End] }), Moved({ key : U64, before : [Row(U64), End] }), Changed(U64)]

	Window : { start : U64, count : U64 }

	## What the site and the cell hold after a turn: how the view followed,
	## the table's rows, changes and counts, the view's ordered keys, the
	## keys drawn, and the changes of the rows drawn.
	Outcome : { how : How, rows : List((U64, U64)), record : Record, version : U64, start : U64, keys : List(U64), drawn : List(U64), changes : List(Change) }

	## One turn: its modifiers, the query and the window the pass brings if
	## it changes them, what it leaves, and whether a copy of the table is
	## kept for later `Saved` and `Other`.
	Turn : { modifiers : List(Modifier), query : Try(U64, [Same]), window : Try(Window, [Same]), outcome : Outcome, keep : Bool }

	## A history of one cell and one view of it: the rebuild thresholds,
	## the table's starting rows, the view's query and window, and its turns.
	Vector : { seed : U64, ratio : U64, floor : U64, rows : List((U64, U64)), query : U64, window : Window, turns : List(Turn) }

	## Every vector, named by its seed.
	vectors : List(Vector)
	vectors =
		[
			# Covers absorbed changed, rebuilt-rewritten left, rebuilt-rewritten changed.
			{
				seed: 0,
				ratio: 8,
				floor: 64,
				rows: [(0, 1), (1, 0)],
				query: 2,
				window: { start: 0, count: 2 },
				turns: [
					{ modifiers: [On([Replace(2, 2), Put(1, 0)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 1), (1, 0)], record: Keyed([{ key: 1, before: Was(0) }]), version: 1, start: 0, keys: [1, 0], drawn: [1, 0], changes: [Changed(1)] }, keep: Bool.False },
					{ modifiers: [On([Replace(0, 2)]), On([Insert(0, 1)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 2), (1, 0)], record: Keyed([{ key: 0, before: Was(1) }]), version: 2, start: 1, keys: [1, 0], drawn: [1, 0], changes: [Changed(0)] }, keep: Bool.False },
					{ modifiers: [Fresh([(0, 0)]), On([Insert(1, 2), Remove(1)])], query: Err(Same), window: Err(Same), outcome: { how: Rebuilt(Rewritten), rows: [(0, 0)], record: Rewritten, version: 5, start: 2, keys: [0], drawn: [0], changes: [Left(1), Changed(0)] }, keep: Bool.False },
				],
			},
			# Covers unchanged none.
			{
				seed: 1,
				ratio: 8,
				floor: 64,
				rows: [(0, 1), (1, 0)],
				query: 0,
				window: { start: 1, count: 2 },
				turns: [
					{ modifiers: [On([Remove(2)])], query: Ok(2), window: Ok({ start: 1, count: 2 }), outcome: { how: Unchanged, rows: [(0, 1), (1, 0)], record: Keyed([]), version: 0, start: 0, keys: [1, 0], drawn: [0], changes: [] }, keep: Bool.True },
				],
			},
			# Covers absorbed entered, rebuilt-rewritten entered.
			{
				seed: 2,
				ratio: 8,
				floor: 64,
				rows: [(0, 0)],
				query: 0,
				window: { start: 0, count: 1000 },
				turns: [
					{ modifiers: [Fresh([(0, 1), (1, 0)]), Fresh([])], query: Ok(1), window: Ok({ start: 0, count: 2 }), outcome: { how: Rebuilt(Rewritten), rows: [], record: Rewritten, version: 2, start: 0, keys: [], drawn: [], changes: [Left(0)] }, keep: Bool.False },
					{ modifiers: [On([Put(2, 0)]), On([Update(1), Insert(1, 2)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(1, 2), (2, 0)], record: Keyed([{ key: 2, before: Absent }, { key: 1, before: Absent }]), version: 4, start: 2, keys: [1], drawn: [1], changes: [Entered({ key: 1, before: End })] }, keep: Bool.True },
					{ modifiers: [Fresh([(0, 1), (1, 0)])], query: Ok(2), window: Ok({ start: 1, count: 2 }), outcome: { how: Rebuilt(Rewritten), rows: [(0, 1), (1, 0)], record: Rewritten, version: 5, start: 4, keys: [1, 0], drawn: [0], changes: [Left(1), Entered({ key: 0, before: End })] }, keep: Bool.False },
				],
			},
			# Covers absorbed none.
			{
				seed: 3,
				ratio: 8,
				floor: 64,
				rows: [],
				query: 0,
				window: { start: 1, count: 1 },
				turns: [
					{ modifiers: [On([Insert(2, 0)]), On([Insert(2, 0)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(2, 0)], record: Keyed([{ key: 2, before: Absent }]), version: 1, start: 0, keys: [2], drawn: [], changes: [] }, keep: Bool.True },
					{ modifiers: [On([Update(0), Insert(1, 0)])], query: Ok(0), window: Err(Same), outcome: { how: Absorbed, rows: [(1, 0), (2, 0)], record: Keyed([{ key: 1, before: Absent }]), version: 2, start: 1, keys: [1, 2], drawn: [2], changes: [Entered({ key: 2, before: End })] }, keep: Bool.False },
					{ modifiers: [On([Replace(2, 0)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(1, 0), (2, 0)], record: Keyed([{ key: 2, before: Was(0) }]), version: 3, start: 2, keys: [1, 2], drawn: [2], changes: [Changed(2)] }, keep: Bool.False },
				],
			},
			# Covers rebuilt-rewritten none.
			{
				seed: 6,
				ratio: 8,
				floor: 64,
				rows: [],
				query: 1,
				window: { start: 0, count: 2 },
				turns: [
					{ modifiers: [Fresh([(0, 0)]), On([Update(0)])], query: Err(Same), window: Ok({ start: 1, count: 1 }), outcome: { how: Rebuilt(Rewritten), rows: [(0, 1)], record: Rewritten, version: 2, start: 0, keys: [0], drawn: [], changes: [] }, keep: Bool.True },
					{ modifiers: [On([Update(0)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 2)], record: Keyed([{ key: 0, before: Was(1) }]), version: 3, start: 2, keys: [0], drawn: [], changes: [] }, keep: Bool.False },
					{ modifiers: [On([Insert(1, 1)]), On([Replace(1, 1)])], query: Ok(0), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 2), (1, 1)], record: Keyed([{ key: 1, before: Absent }]), version: 5, start: 3, keys: [1, 0], drawn: [0], changes: [Entered({ key: 0, before: End })] }, keep: Bool.False },
				],
			},
			# Covers absorbed left.
			{
				seed: 9,
				ratio: 8,
				floor: 64,
				rows: [(0, 0)],
				query: 0,
				window: { start: 1, count: 1 },
				turns: [
					{ modifiers: [On([Put(1, 0)]), On([Update(2), Insert(1, 1)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 0), (1, 0)], record: Keyed([{ key: 1, before: Absent }]), version: 1, start: 0, keys: [0, 1], drawn: [1], changes: [Entered({ key: 1, before: End })] }, keep: Bool.False },
					{ modifiers: [On([Replace(2, 1)]), On([Put(0, 1)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 1), (1, 0)], record: Keyed([{ key: 0, before: Was(0) }]), version: 2, start: 1, keys: [1, 0], drawn: [0], changes: [Left(1), Entered({ key: 0, before: End })] }, keep: Bool.True },
				],
			},
			# Covers unchanged entered.
			{
				seed: 15,
				ratio: 8,
				floor: 64,
				rows: [(0, 1), (1, 0)],
				query: 1,
				window: { start: 0, count: 2 },
				turns: [
					{ modifiers: [On([Update(2), Insert(0, 0)]), On([Insert(0, 0)])], query: Ok(0), window: Err(Same), outcome: { how: Unchanged, rows: [(0, 1), (1, 0)], record: Keyed([]), version: 0, start: 0, keys: [1, 0], drawn: [1, 0], changes: [Entered({ key: 1, before: Row(0) })] }, keep: Bool.True },
					{ modifiers: [Other(0), On([Put(2, 0)])], query: Err(Same), window: Err(Same), outcome: { how: Rebuilt(Rewritten), rows: [(0, 1), (1, 0), (2, 0)], record: Rewritten, version: 2, start: 0, keys: [1, 2, 0], drawn: [1, 2], changes: [Left(0), Entered({ key: 2, before: End }), Changed(1)] }, keep: Bool.False },
				],
			},
			# Covers rebuilt-rewritten moved.
			{
				seed: 29,
				ratio: 8,
				floor: 64,
				rows: [],
				query: 0,
				window: { start: 0, count: 2 },
				turns: [
					{ modifiers: [On([Put(0, 2)]), On([Put(2, 0)])], query: Err(Same), window: Ok({ start: 0, count: 1000 }), outcome: { how: Absorbed, rows: [(0, 2), (2, 0)], record: Keyed([{ key: 0, before: Absent }, { key: 2, before: Absent }]), version: 2, start: 0, keys: [2, 0], drawn: [2, 0], changes: [Entered({ key: 2, before: End }), Entered({ key: 0, before: End })] }, keep: Bool.True },
					{ modifiers: [On([Put(2, 2)]), On([All])], query: Err(Same), window: Err(Same), outcome: { how: Rebuilt(Rewritten), rows: [(0, 3), (2, 3)], record: Rewritten, version: 4, start: 2, keys: [0, 2], drawn: [0, 2], changes: [Moved({ key: 2, before: End }), Changed(0), Changed(2)] }, keep: Bool.False },
					{ modifiers: [On([Put(1, 2)])], query: Ok(1), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 3), (1, 2), (2, 3)], record: Keyed([{ key: 1, before: Absent }]), version: 5, start: 4, keys: [1, 0, 2], drawn: [1, 0, 2], changes: [Entered({ key: 1, before: Row(0) })] }, keep: Bool.True },
				],
			},
			# Covers absorbed moved.
			{
				seed: 51,
				ratio: 8,
				floor: 64,
				rows: [(0, 1), (1, 0)],
				query: 0,
				window: { start: 0, count: 2 },
				turns: [
					{ modifiers: [On([Replace(1, 1), Put(1, 2)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 1), (1, 2)], record: Keyed([{ key: 1, before: Was(0) }]), version: 2, start: 0, keys: [0, 1], drawn: [0, 1], changes: [Moved({ key: 1, before: End }), Changed(1)] }, keep: Bool.True },
					{ modifiers: [On([Put(0, 0), Update(1)]), On([Insert(1, 2)])], query: Err(Same), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 0), (1, 3)], record: Keyed([{ key: 0, before: Was(1) }, { key: 1, before: Was(2) }]), version: 4, start: 2, keys: [0, 1], drawn: [0, 1], changes: [Changed(0), Changed(1)] }, keep: Bool.True },
					{ modifiers: [Saved(1, [])], query: Err(Same), window: Err(Same), outcome: { how: Rebuilt(Rewritten), rows: [(0, 0), (1, 3)], record: Rewritten, version: 5, start: 4, keys: [0, 1], drawn: [0, 1], changes: [Changed(0), Changed(1)] }, keep: Bool.False },
				],
			},
			# Covers unchanged left.
			{
				seed: 78,
				ratio: 8,
				floor: 64,
				rows: [(0, 0)],
				query: 0,
				window: { start: 0, count: 1000 },
				turns: [
					{ modifiers: [On([Replace(2, 2)])], query: Ok(0), window: Ok({ start: 1, count: 1 }), outcome: { how: Unchanged, rows: [(0, 0)], record: Keyed([]), version: 0, start: 0, keys: [0], drawn: [], changes: [Left(0)] }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 1)])], query: Err(Same), window: Err(Same), outcome: { how: Unchanged, rows: [(0, 0)], record: Keyed([]), version: 0, start: 0, keys: [0], drawn: [], changes: [] }, keep: Bool.False },
				],
			},
			# Covers unchanged moved.
			{
				seed: 1495,
				ratio: 8,
				floor: 64,
				rows: [(0, 1), (1, 0)],
				query: 2,
				window: { start: 0, count: 1000 },
				turns: [
					{ modifiers: [On([Replace(1, 1), Insert(1, 0)])], query: Ok(1), window: Err(Same), outcome: { how: Absorbed, rows: [(0, 1), (1, 1)], record: Keyed([{ key: 1, before: Was(0) }]), version: 1, start: 0, keys: [0, 1], drawn: [0, 1], changes: [Moved({ key: 1, before: End }), Changed(1)] }, keep: Bool.True },
					{ modifiers: [On([Insert(1, 0)])], query: Ok(2), window: Err(Same), outcome: { how: Unchanged, rows: [(0, 1), (1, 1)], record: Keyed([]), version: 1, start: 1, keys: [1, 0], drawn: [1, 0], changes: [Moved({ key: 0, before: End })] }, keep: Bool.False },
				],
			},
		]
}
