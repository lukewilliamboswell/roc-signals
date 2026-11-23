## Fixed histories of one table cell, each turn with the outcome it must
## have: the rows the cell holds after it, what its changes say, and its
## write count and the count its changes began at. Each vector starts from
## its rows and runs its turns in order, each a list of modifiers handed to
## the cell's generated modifier through `Store.after`; a turn marked
## `keep` keeps a copy of the cell's table for later `Saved` and `Other`
## modifiers. `FuzzTableChangesProperty` replays each against its model
## (top-level `expect`s) and against `TableCore` and the generated modifier
## (its fixed examples), so both are held to these outcomes. Each vector's
## comment names the shapes of operation, turn and record it reaches.
ChangeVectors := [].{

	## An operation on a table: `update` and `update_all` add 1 to a row
	## modulo the target's row space; `Undo` applies the table's own
	## `inverse`.
	Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), All, Undo]

	## A function handed to the cell's modifier: operations on the table it
	## is given; operations on the i-th kept copy instead; the i-th kept copy
	## under another cell's identity; or a new table of these rows.
	Modifier : [On(List(Op)), Saved(U64, List(Op)), Other(U64), Fresh(List((U64, U64)))]

	## What a table's changes say after a turn: each key the turn wrote and
	## its row when the turn began, or a whole rewrite.
	Record : [Keyed(List({ key : U64, before : [Was(U64), Absent] })), Rewritten]

	## A cell's table after a turn: its rows by key, its changes, its write
	## count and the count its changes began at.
	Outcome : { rows : List((U64, U64)), record : Record, version : U64, start : U64 }

	## One turn: its modifiers, in order, what the cell holds after it, and
	## whether a copy of that is kept for later `Saved` and `Other`.
	Turn : { modifiers : List(Modifier), outcome : Outcome, keep : Bool }

	## A history of one cell from its starting rows.
	Vector : { seed : U64, start : List((U64, U64)), turns : List(Turn) }

	## Every vector, named by its seed. `oracle/tables` writes this list from
	## its transliteration of `TableCore.roc` and the cell's generated modifier
	## (`blueprint run oracle`, which fails if it differs), and keeps
	## everything above it as it is: change the model there, never the list.
	vectors : List(Vector)
	vectors =
		[
			# Covers ops turn-start writes, update_all turn-start rewritten, put rewritten writes, fresh turn-start rewritten, ops rewritten no-write.
			{
				seed: 0,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Put(1, 2), Insert(2, 1)])], outcome: { rows: [(0, 1), (1, 2), (2, 1)], record: Keyed([{ key: 1, before: Was(0) }, { key: 2, before: Absent }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([All]), On([Put(0, 2)])], outcome: { rows: [(0, 2), (1, 3), (2, 2)], record: Rewritten, version: 4, start: 2 }, keep: Bool.False },
					{ modifiers: [Fresh([(0, 0)]), On([Update(1), Insert(0, 2)])], outcome: { rows: [(0, 0)], record: Rewritten, version: 5, start: 4 }, keep: Bool.False },
				],
			},
			# Covers insert turn-start writes.
			{
				seed: 1,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Insert(2, 2)])], outcome: { rows: [(0, 1), (1, 0), (2, 2)], record: Keyed([{ key: 2, before: Absent }]), version: 1, start: 0 }, keep: Bool.True },
				],
			},
			# Covers fresh rewritten writes, put turn-start writes, ops keyed writes.
			{
				seed: 2,
				start: [(0, 0)],
				turns: [
					{ modifiers: [Fresh([(0, 1), (1, 0)]), Fresh([])], outcome: { rows: [], record: Rewritten, version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Put(1, 2)]), On([Insert(0, 0), Remove(1)])], outcome: { rows: [(0, 0)], record: Keyed([{ key: 1, before: Absent }, { key: 0, before: Absent }]), version: 5, start: 2 }, keep: Bool.True },
					{ modifiers: [Fresh([(0, 1), (1, 0)])], outcome: { rows: [(0, 1), (1, 0)], record: Rewritten, version: 6, start: 5 }, keep: Bool.False },
				],
			},
			# Covers remove turn-start no-write, replace key-unrecorded no-write.
			{
				seed: 3,
				start: [],
				turns: [
					{ modifiers: [On([Remove(0)]), On([Replace(0, 0)])], outcome: { rows: [], record: Keyed([]), version: 0, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Put(0, 1), Put(0, 2)])], outcome: { rows: [(0, 2)], record: Keyed([{ key: 0, before: Absent }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Put(0, 2)])], outcome: { rows: [(0, 2)], record: Keyed([{ key: 0, before: Was(2) }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers fresh keyed rewritten.
			{
				seed: 5,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Replace(0, 0), Replace(2, 0)]), Fresh([(0, 2), (1, 0), (2, 1)])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Rewritten, version: 3, start: 0 }, keep: Bool.True },
				],
			},
			# Covers replace rewritten writes, insert turn-start no-write, update key-unrecorded no-write.
			{
				seed: 6,
				start: [],
				turns: [
					{ modifiers: [Fresh([(0, 0)]), On([Replace(0, 0)])], outcome: { rows: [(0, 0)], record: Rewritten, version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Insert(2, 2)])], outcome: { rows: [(0, 0), (2, 2)], record: Keyed([{ key: 2, before: Absent }]), version: 3, start: 2 }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 0)]), On([Update(1)])], outcome: { rows: [(0, 0), (2, 2)], record: Keyed([]), version: 3, start: 3 }, keep: Bool.False },
				],
			},
			# Covers undo turn-start no-write, replace turn-start writes, other turn-start rewritten.
			{
				seed: 7,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Undo]), On([Replace(1, 0), Put(1, 1)])], outcome: { rows: [(0, 2), (1, 1), (2, 1)], record: Keyed([{ key: 1, before: Was(0) }]), version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Replace(1, 2)]), On([Put(0, 1), Replace(1, 2)])], outcome: { rows: [(0, 1), (1, 2), (2, 1)], record: Keyed([{ key: 1, before: Was(1) }, { key: 0, before: Was(2) }]), version: 5, start: 2 }, keep: Bool.False },
					{ modifiers: [Other(0)], outcome: { rows: [(0, 2), (1, 1), (2, 1)], record: Rewritten, version: 6, start: 5 }, keep: Bool.False },
				],
			},
			# Covers update turn-start no-write, replace key-unrecorded writes.
			{
				seed: 8,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Put(2, 2)])], outcome: { rows: [(0, 0), (2, 2)], record: Keyed([{ key: 2, before: Absent }]), version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [Fresh([(0, 0)])], outcome: { rows: [(0, 0)], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Update(1)]), On([Replace(0, 2)])], outcome: { rows: [(0, 2)], record: Keyed([{ key: 0, before: Was(0) }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers put key-unrecorded writes, replace turn-start no-write, other keyed rewritten.
			{
				seed: 10,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Remove(2)]), On([Put(0, 0)])], outcome: { rows: [(0, 0), (1, 0)], record: Keyed([{ key: 0, before: Was(1) }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [Fresh([(0, 1), (1, 0)])], outcome: { rows: [(0, 1), (1, 0)], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Replace(2, 0)]), Other(0)], outcome: { rows: [(0, 0), (1, 0)], record: Rewritten, version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers ops rewritten writes, replace key-recorded writes.
			{
				seed: 18,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Insert(0, 2)]), On([Replace(0, 0)])], outcome: { rows: [(0, 0), (1, 0), (2, 1)], record: Keyed([{ key: 0, before: Was(2) }]), version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([All]), On([Put(2, 2), Remove(2)])], outcome: { rows: [(0, 1), (1, 1)], record: Rewritten, version: 4, start: 1 }, keep: Bool.True },
					{ modifiers: [On([Insert(2, 1)]), On([Replace(2, 1)])], outcome: { rows: [(0, 1), (1, 1), (2, 1)], record: Keyed([{ key: 2, before: Absent }]), version: 6, start: 4 }, keep: Bool.True },
				],
			},
			# Covers insert key-unrecorded writes.
			{
				seed: 22,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Put(0, 1), Replace(1, 1)]), On([Remove(1), Remove(0)])], outcome: { rows: [], record: Keyed([{ key: 0, before: Was(0) }]), version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Replace(0, 1), Put(1, 1)]), On([Insert(0, 2)])], outcome: { rows: [(0, 2), (1, 1)], record: Keyed([{ key: 1, before: Absent }, { key: 0, before: Absent }]), version: 4, start: 2 }, keep: Bool.True },
				],
			},
			# Covers insert key-recorded no-write.
			{
				seed: 23,
				start: [],
				turns: [
					{ modifiers: [On([Put(0, 2), Remove(1)]), On([Insert(0, 2)])], outcome: { rows: [(0, 2)], record: Keyed([{ key: 0, before: Absent }]), version: 1, start: 0 }, keep: Bool.False },
				],
			},
			# Covers ops turn-start rewritten, remove turn-start writes.
			{
				seed: 24,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Remove(2), All]), On([Replace(2, 1), Replace(1, 2)])], outcome: { rows: [(0, 2), (1, 2)], record: Rewritten, version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Remove(0)])], outcome: { rows: [(1, 2)], record: Keyed([{ key: 0, before: Was(2) }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers ops turn-start no-write, ops keyed no-write.
			{
				seed: 26,
				start: [],
				turns: [
					{ modifiers: [On([Replace(0, 2), Insert(2, 1)]), On([Put(0, 0)])], outcome: { rows: [(0, 0), (2, 1)], record: Keyed([{ key: 2, before: Absent }, { key: 0, before: Absent }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 0), Insert(2, 0)])], outcome: { rows: [(0, 0), (2, 1)], record: Keyed([]), version: 2, start: 2 }, keep: Bool.True },
					{ modifiers: [On([Insert(2, 2), Update(0)]), On([Update(1), Insert(0, 1)])], outcome: { rows: [(0, 1), (2, 1)], record: Keyed([{ key: 0, before: Was(0) }]), version: 3, start: 2 }, keep: Bool.True },
				],
			},
			# Covers saved turn-start rewritten.
			{
				seed: 30,
				start: [],
				turns: [
					{ modifiers: [On([Insert(0, 2)])], outcome: { rows: [(0, 2)], record: Keyed([{ key: 0, before: Absent }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [Saved(0, [Replace(0, 1)])], outcome: { rows: [(0, 1)], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Put(2, 0)])], outcome: { rows: [(0, 1), (2, 0)], record: Keyed([{ key: 2, before: Absent }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers update turn-start writes, saved keyed rewritten.
			{
				seed: 33,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Update(0), Put(1, 2)]), On([Replace(0, 1), Replace(2, 2)])], outcome: { rows: [(0, 1), (1, 2)], record: Keyed([{ key: 0, before: Was(0) }, { key: 1, before: Absent }]), version: 3, start: 0 }, keep: Bool.True },
					{ modifiers: [Other(0)], outcome: { rows: [(0, 1), (1, 2)], record: Rewritten, version: 4, start: 3 }, keep: Bool.True },
					{ modifiers: [On([Update(1)]), Saved(1, [])], outcome: { rows: [(0, 1), (1, 2)], record: Rewritten, version: 6, start: 4 }, keep: Bool.False },
				],
			},
			# Covers put key-recorded writes.
			{
				seed: 41,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Insert(1, 2)]), On([Put(1, 0)])], outcome: { rows: [(0, 0), (1, 0)], record: Keyed([{ key: 1, before: Absent }]), version: 2, start: 0 }, keep: Bool.True },
				],
			},
			# Covers ops keyed rewritten.
			{
				seed: 49,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Insert(2, 0)]), On([All, Remove(1)])], outcome: { rows: [(0, 2), (2, 1)], record: Rewritten, version: 3, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Replace(0, 1)])], outcome: { rows: [(0, 1), (2, 1)], record: Keyed([{ key: 0, before: Was(2) }]), version: 4, start: 3 }, keep: Bool.True },
				],
			},
			# Covers replace rewritten no-write.
			{
				seed: 53,
				start: [],
				turns: [
					{ modifiers: [On([Put(0, 1), All]), On([Replace(1, 0)])], outcome: { rows: [(0, 2)], record: Rewritten, version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Put(1, 0)])], outcome: { rows: [(0, 2), (1, 0)], record: Keyed([{ key: 1, before: Absent }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers insert key-unrecorded no-write, remove key-unrecorded writes.
			{
				seed: 56,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Put(0, 0)]), On([Replace(1, 0), Insert(0, 2)])], outcome: { rows: [(0, 0), (1, 0)], record: Keyed([{ key: 0, before: Was(1) }, { key: 1, before: Was(0) }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Insert(2, 1)]), On([Insert(0, 0)])], outcome: { rows: [(0, 0), (1, 0), (2, 1)], record: Keyed([{ key: 2, before: Absent }]), version: 3, start: 2 }, keep: Bool.False },
					{ modifiers: [On([Undo]), On([Remove(0)])], outcome: { rows: [(1, 0), (2, 1)], record: Keyed([{ key: 0, before: Was(0) }]), version: 4, start: 3 }, keep: Bool.True },
				],
			},
			# Covers update_all keyed rewritten.
			{
				seed: 76,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Replace(1, 1)])], outcome: { rows: [(0, 1), (1, 1)], record: Keyed([{ key: 1, before: Was(0) }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Insert(0, 1), Undo]), On([All])], outcome: { rows: [(0, 2), (1, 2)], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
				],
			},
			# Covers update key-recorded writes.
			{
				seed: 86,
				start: [],
				turns: [
					{ modifiers: [On([Insert(2, 2), Insert(1, 1)]), On([Insert(1, 0)])], outcome: { rows: [(1, 1), (2, 2)], record: Keyed([{ key: 2, before: Absent }, { key: 1, before: Absent }]), version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Put(2, 2)]), On([Update(2)])], outcome: { rows: [(1, 1), (2, 3)], record: Keyed([{ key: 2, before: Was(2) }]), version: 4, start: 2 }, keep: Bool.False },
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Rewritten, version: 5, start: 4 }, keep: Bool.False },
				],
			},
			# Covers insert rewritten writes.
			{
				seed: 94,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Replace(2, 2), Remove(0)])], outcome: { rows: [(1, 0)], record: Keyed([{ key: 0, before: Was(1) }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Insert(1, 0)])], outcome: { rows: [(1, 0)], record: Keyed([]), version: 1, start: 1 }, keep: Bool.False },
					{ modifiers: [Saved(0, []), On([Insert(0, 1)])], outcome: { rows: [(0, 1), (1, 0)], record: Rewritten, version: 3, start: 1 }, keep: Bool.True },
				],
			},
			# Covers remove key-unrecorded no-write.
			{
				seed: 96,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Insert(1, 2)]), On([Remove(2)])], outcome: { rows: [(0, 0), (1, 2)], record: Keyed([{ key: 1, before: Absent }]), version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 2), Insert(2, 0)])], outcome: { rows: [(0, 0), (1, 2), (2, 0)], record: Keyed([{ key: 2, before: Absent }]), version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 1)])], outcome: { rows: [(0, 0), (1, 2), (2, 0)], record: Keyed([]), version: 2, start: 2 }, keep: Bool.False },
				],
			},
			# Covers insert rewritten no-write.
			{
				seed: 167,
				start: [(0, 0)],
				turns: [
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)]), On([Insert(2, 2)])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Rewritten, version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Put(1, 1)])], outcome: { rows: [(0, 2), (1, 1), (2, 1)], record: Keyed([{ key: 1, before: Was(0) }]), version: 2, start: 1 }, keep: Bool.False },
				],
			},
			# Covers insert key-recorded writes.
			{
				seed: 172,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Remove(2)]), On([Insert(2, 2)])], outcome: { rows: [(0, 2), (1, 0), (2, 2)], record: Keyed([{ key: 2, before: Was(1) }]), version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Put(0, 1)])], outcome: { rows: [(0, 1), (1, 0), (2, 2)], record: Keyed([{ key: 0, before: Was(2) }]), version: 3, start: 2 }, keep: Bool.True },
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)]), On([Put(0, 0), Remove(0)])], outcome: { rows: [(1, 0), (2, 1)], record: Rewritten, version: 6, start: 3 }, keep: Bool.False },
				],
			},
			# Covers undo keyed writes.
			{
				seed: 179,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Remove(2), Insert(0, 2)]), On([Undo])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Keyed([{ key: 2, before: Was(1) }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Put(0, 1), Put(2, 2)])], outcome: { rows: [(0, 1), (1, 0), (2, 2)], record: Keyed([{ key: 0, before: Was(2) }, { key: 2, before: Was(1) }]), version: 4, start: 2 }, keep: Bool.True },
				],
			},
			# Covers update key-unrecorded writes.
			{
				seed: 214,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Undo, Put(0, 1)]), On([Replace(2, 2)])], outcome: { rows: [(0, 1), (1, 0)], record: Keyed([{ key: 0, before: Was(1) }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Put(2, 1)]), On([Update(0)])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Keyed([{ key: 2, before: Absent }, { key: 0, before: Was(1) }]), version: 3, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Replace(1, 1), Update(0)])], outcome: { rows: [(0, 3), (1, 1), (2, 1)], record: Keyed([{ key: 1, before: Was(0) }, { key: 0, before: Was(2) }]), version: 5, start: 3 }, keep: Bool.False },
				],
			},
			# Covers undo keyed no-write.
			{
				seed: 227,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Put(1, 2)]), On([Replace(1, 1)])], outcome: { rows: [(0, 0), (1, 1)], record: Keyed([{ key: 1, before: Absent }]), version: 2, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Insert(0, 2)]), On([Undo])], outcome: { rows: [(0, 0), (1, 1)], record: Keyed([]), version: 2, start: 2 }, keep: Bool.True },
				],
			},
			# Covers update rewritten writes.
			{
				seed: 284,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Put(0, 0)])], outcome: { rows: [(0, 0), (1, 0)], record: Keyed([{ key: 0, before: Was(1) }]), version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Replace(2, 0)]), Fresh([])], outcome: { rows: [], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)]), On([Update(2)])], outcome: { rows: [(0, 2), (1, 0), (2, 2)], record: Rewritten, version: 4, start: 2 }, keep: Bool.True },
				],
			},
			# Covers update rewritten no-write.
			{
				seed: 287,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [Fresh([]), On([Update(0)])], outcome: { rows: [], record: Rewritten, version: 1, start: 0 }, keep: Bool.True },
				],
			},
			# Covers remove key-recorded writes.
			{
				seed: 293,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [On([Put(2, 2), Insert(1, 2)])], outcome: { rows: [(0, 1), (1, 0), (2, 2)], record: Keyed([{ key: 2, before: Absent }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [On([Put(2, 2)]), On([Remove(2)])], outcome: { rows: [(0, 1), (1, 0)], record: Keyed([{ key: 2, before: Was(2) }]), version: 3, start: 1 }, keep: Bool.False },
				],
			},
			# Covers replace key-recorded no-write.
			{
				seed: 297,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Insert(2, 2)])], outcome: { rows: [(0, 0), (2, 2)], record: Keyed([{ key: 2, before: Absent }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [Saved(0, [])], outcome: { rows: [(0, 0), (2, 2)], record: Rewritten, version: 2, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Insert(1, 0), Remove(1)]), On([Replace(1, 0)])], outcome: { rows: [(0, 0), (2, 2)], record: Keyed([{ key: 1, before: Absent }]), version: 4, start: 2 }, keep: Bool.False },
				],
			},
			# Covers remove key-recorded no-write.
			{
				seed: 480,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Remove(1)]), On([Remove(1)])], outcome: { rows: [(0, 2), (2, 1)], record: Keyed([{ key: 1, before: Was(0) }]), version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Insert(2, 2)])], outcome: { rows: [(0, 2), (2, 1)], record: Keyed([]), version: 1, start: 1 }, keep: Bool.True },
				],
			},
			# Covers other rewritten writes.
			{
				seed: 523,
				start: [],
				turns: [
					{ modifiers: [On([Put(0, 0)])], outcome: { rows: [(0, 0)], record: Keyed([{ key: 0, before: Absent }]), version: 1, start: 0 }, keep: Bool.True },
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)]), Other(0)], outcome: { rows: [(0, 0)], record: Rewritten, version: 3, start: 1 }, keep: Bool.False },
					{ modifiers: [On([Remove(1), Replace(1, 2)])], outcome: { rows: [(0, 0)], record: Keyed([]), version: 3, start: 3 }, keep: Bool.False },
				],
			},
			# Covers remove rewritten writes.
			{
				seed: 541,
				start: [(0, 1), (1, 0)],
				turns: [
					{ modifiers: [Fresh([(0, 2), (1, 0), (2, 1)]), On([Remove(0)])], outcome: { rows: [(1, 0), (2, 1)], record: Rewritten, version: 2, start: 0 }, keep: Bool.False },
				],
			},
			# Covers update_all rewritten writes, saved rewritten writes.
			{
				seed: 569,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [Fresh([(0, 1), (1, 0)]), On([All])], outcome: { rows: [(0, 2), (1, 1)], record: Rewritten, version: 2, start: 0 }, keep: Bool.True },
					{ modifiers: [Saved(0, [Replace(1, 2)]), Saved(0, [Update(0)])], outcome: { rows: [(0, 3), (1, 1)], record: Rewritten, version: 4, start: 2 }, keep: Bool.False },
					{ modifiers: [On([Replace(0, 2)]), Fresh([(0, 1), (1, 0)])], outcome: { rows: [(0, 1), (1, 0)], record: Rewritten, version: 6, start: 4 }, keep: Bool.False },
				],
			},
			# Covers update key-recorded no-write.
			{
				seed: 668,
				start: [(0, 2), (1, 0), (2, 1)],
				turns: [
					{ modifiers: [On([Remove(0)]), On([Update(0)])], outcome: { rows: [(1, 0), (2, 1)], record: Keyed([{ key: 0, before: Was(2) }]), version: 1, start: 0 }, keep: Bool.True },
				],
			},
			# Covers undo rewritten no-write.
			{
				seed: 1119,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([All]), On([Undo])], outcome: { rows: [(0, 1)], record: Rewritten, version: 1, start: 0 }, keep: Bool.False },
					{ modifiers: [On([Replace(1, 2)]), Fresh([(0, 2), (1, 0), (2, 1)])], outcome: { rows: [(0, 2), (1, 0), (2, 1)], record: Rewritten, version: 2, start: 1 }, keep: Bool.True },
					{ modifiers: [On([Insert(1, 2), Update(0)])], outcome: { rows: [(0, 3), (1, 0), (2, 1)], record: Keyed([{ key: 0, before: Was(2) }]), version: 3, start: 2 }, keep: Bool.False },
				],
			},
			# Covers remove rewritten no-write.
			{
				seed: 1236,
				start: [(0, 0)],
				turns: [
					{ modifiers: [On([Replace(1, 2)])], outcome: { rows: [(0, 0)], record: Keyed([]), version: 0, start: 0 }, keep: Bool.False },
					{ modifiers: [On([All]), On([Remove(1)])], outcome: { rows: [(0, 1)], record: Rewritten, version: 1, start: 0 }, keep: Bool.False },
				],
			},
		]
}
