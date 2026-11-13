app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Notes

## The outbox's board, over any sequence of what the user and the sync
## service can do to it: save a draft, edit, retry, queue, delete or
## promote a note, go offline or online, pause or resume auto-sync, answer
## a lane's send (successfully or not, current or stale), and reload the
## page, and stamp a capture with a sample that may go backwards. The bugs
## to fear are a note the storage format cannot give back,
## two notes in one lane, a send for anything but the outbox's head, and an
## edit that is never sent.
##
## After every step:
##
## - stored notes decode back exactly, except an in-instance Awaiting
##   capture restores as Unknown because no pending timer survives reload;
## - no two notes share an id or a slot, and every slot is a lane;
## - a lane asks to send only while the app is online with auto-sync on,
##   and then exactly the lane of the head of the outbox (the first queued
##   note its lane has not settled) asks, with that note's current token;
## - a send's answer for an older generation of its lane changes nothing,
##   and an answer for the current one settles exactly that lane;
## - an edit or a retry leaves the note outstanding, whatever its lane had
##   settled.
## - a capture's sample changes only its own note, leaving the generator
##   and every lane untouched.
##
## A reload is a step like any other: a new session starts from the notes
## as stored, with lanes that have settled nothing, and every rule holds on
## from there. So a note is edited, synced and edited again at whatever
## revision an earlier session left it, and a session saves notes beside
## the ids it restored. Every sequence ends with a reload and a save.
Input : List(U8)

## The pieces a typed body is made of; an input byte picks one.
pieces : List(Str)
pieces = ["Fence", " line", "|", ";", "", "  ", "é", "n0", "check", "#", ":"]

## Text from two pieces.
typed : U8, U8 -> Str
typed = |a, b| "${pieces.get(a.to_u64() % pieces.len()) ?? ""}${pieces.get(b.to_u64() % pieces.len()) ?? ""}"

## The id of the note `b` picks, or one no note has.
note_id : Notes.Board, U8 -> Str
note_id = |board, b| match board.notes.get(b.to_u64() % (board.notes.len() + 1)) {
	Ok(note) => note.id
	Err(_) => "gone"
}

## Every rule, or the first broken.
rules : Notes.Board -> Try({}, Str)
rules = |board| {
	stored = Notes.encode_notes(board.notes)
	expected_notes = board.notes.map(
		|note| match note.captured {
			Awaiting => { ..note, captured: Unknown }
			_ => note
		},
	)
	if Notes.decode_notes(stored) != expected_notes {
		return Err("the notes store as ${Str.inspect(stored)}, which decodes as ${Str.inspect(Notes.decode_notes(stored))}")
	}
	ids = board.notes.map(|n| n.id)
	slots = board.notes.map(|n| n.slot)
	if Set.from_list(ids).len() != ids.len() or Set.from_list(slots).len() != slots.len() or slots.any(|s| s >= Notes.slot_count) {
		return Err("notes share an id or a slot, or sit outside the lanes: ${Str.inspect(board.notes)}")
	}
	views = Notes.views(board)
	head = board.notes.find_first(|n| n.queued and Notes.is_outstanding(n, Notes.view_at(views, n.slot)))
	want = |slot| match head {
		Ok(note) if board.online and board.auto and note.slot == slot => Send(Notes.token(note))
		_ => Idle
	}
	for slot in List.repeat(0, Notes.slot_count).map_with_index(|_, i| i) {
		if Notes.request_at(board, slot) != want(slot) or Notes.lane_at(board, slot).request != want(slot) {
			return Err("lane ${slot.to_str()} asks ${Str.inspect(Notes.lane_at(board, slot).request)}, the head is ${Str.inspect(head)} (online ${Str.inspect(board.online)}, auto ${Str.inspect(board.auto)})")
		}
	}
	Ok({})
}

## One step, from three bytes.
step : Notes.Board, { op : U8, a : U8, b : U8, seed : U128 } -> Try(Notes.Board, Str)
step = |board, { op, a, b, seed }| {
	id = note_id(board, a)
	match op % 12 {
		0 => Ok(Notes.save_note(board, typed(a, b)))
		1 => {
			edited = Notes.edit_note(board, id, Notes.sanitize(typed(b, a)))
			outstanding(edited, id, "an edit")
		}
		2 => {
			retried = Notes.retry_note(board, id)
			outstanding(retried, id, "a retry")
		}
		3 => Ok(Notes.queue_note(board, id))
		4 => Ok(Notes.delete_note(board, id))
		5 => Ok(Notes.promote_note(board, id))
		6 => Ok(Notes.set_online(board, !board.online))
		7 => Ok(Notes.set_auto(board, !board.auto))
		10 => Ok(reloaded(board, seed))
		11 => {
			at_ms = a.to_i64() - b.to_i64()
			stamped = Notes.stamped(board, { id, at_ms })
			expected = board.notes.map(|note| if (note.id == id) { ..note, captured: At(at_ms) } else note)
			if stamped.notes != expected or { ..stamped, notes: board.notes } != board {
				Err("a timestamp changed another note or the board's generator or sync state")
			} else {
				Ok(stamped)
			}
		}
		_ => {
			slot = a.to_u64() % Notes.slot_count
			issue = Notes.issue_at(board, slot)
			if b % 3 == 2 {
				stale = { ..issue, generation: if (issue.generation == 0) 0 else issue.generation - 1 }
				answered = Notes.settle_send(board, slot, stale, b % 2 == 0)
				if issue.generation > 0 and answered != board {
					return Err("a stale answer for lane ${slot.to_str()} changed the board")
				}
				Ok(answered)
			} else {
				answered = Notes.settle_send(board, slot, issue, b % 2 == 0)
				others = List.repeat(0, Notes.slot_count).map_with_index(|_, i| i).keep_if(|i| i != slot)
				if others.any(|i| Notes.lane_at(answered, i).settled != Notes.lane_at(board, i).settled) {
					return Err("an answer for lane ${slot.to_str()} settled another lane")
				}
				Ok(answered)
			}
		}
	}
}

## The session a reload starts: the notes as stored, on a board that knows
## whether the browser is online. Its lanes have settled nothing, and it
## receives the next document seed for the ids it mints.
reloaded : Notes.Board, U128 -> Notes.Board
reloaded = |board, seed| Notes.seeded(Notes.initial(Notes.decode_notes(Notes.encode_notes(board.notes)), board.online), seed)

## After an edit or a retry, the note is no longer settled by its lane.
outstanding : Notes.Board, Str, Str -> Try(Notes.Board, Str)
outstanding = |board, id, what| match board.notes.find_first(|n| n.id == id) {
	Ok(note) if !Notes.is_outstanding(note, Notes.view_at(Notes.views(board), note.slot)) => Err("after ${what}, ${id} is still settled by its lane")
	_ => Ok(board)
}

## The whole session, or the first broken rule and the step that broke it.
check : Input -> Try({}, Str)
check = |bytes| {
	stored = [{ id: "n0", slot: 0, body: "Generator hours", queued: True, rev: "r7", captured: Unknown }, { id: "n1", slot: 1, body: "Fence line check", queued: False, rev: "r7", captured: Unknown }]
	var $seed = 7.U128
	var $board = Notes.seeded(Notes.initial(stored, Bool.True), $seed)
	rules($board).map_err(|why| "at mount: ${why}")?
	var $i = 0
	while $i + 2 < bytes.len() {
		op = bytes.get($i) ?? 0
		if op % 12 == 10 {
			$seed = $seed + 1
		}
		$board = step($board, { op, a: bytes.get($i + 1) ?? 0, b: bytes.get($i + 2) ?? 0, seed: $seed }).map_err(|why| "step ${($i // 3).to_str()} (op ${(op % 12).to_str()}): ${why}")?
		rules($board).map_err(|why| "after step ${($i // 3).to_str()} (op ${(op % 12).to_str()}): ${why}")?
		$i = $i + 3
	}
	rules(Notes.save_note(reloaded($board, $seed + 1), "Radio check")).map_err(|why| "after a reload and a save: ${why}")?
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "field-notes",
	examples: [
		# Save two notes, queue the first, answer its lane, edit it.
		ex("save-queue-sync-edit", [0, 0, 1, 0, 2, 7, 3, 2, 0, 8, 2, 0, 1, 2, 1]),
		# Separators typed into a draft and into an edit.
		ex("separators", [0, 2, 3, 1, 1, 3, 1, 2, 2]),
		# Offline, then online with a stale answer in between.
		ex("offline-stale", [6, 0, 0, 8, 0, 2, 6, 0, 0, 8, 0, 0, 8, 0, 2]),
		# Save one note, which the reload then finds under its generated id.
		ex("save-reload-save", [0, 0, 1]),
		# Edit a note, reload, answer its lane, edit it again: the note is
		# restored at the revision the first edit gave it.
		ex("edit-reload-sync-edit", [1, 0, 8, 10, 0, 0, 8, 0, 0, 1, 0, 8]),
		# The same after two edits, with two more while offline: the second
		# must not come back to the revision the lane settled.
		ex("edits-reload-sync-edits-offline", [1, 0, 8, 1, 0, 8, 10, 0, 0, 8, 0, 0, 6, 0, 0, 1, 0, 8, 1, 0, 8]),
		# Save, edit and queue a note, reload, let it sync, delete it, and
		# save and edit another: the new session mints a different id, and the
		# edit the same revision, in the lane that settled the first.
		ex("reload-sync-delete-save-edit", [0, 0, 8, 1, 2, 8, 3, 2, 0, 10, 0, 0, 8, 0, 0, 8, 2, 0, 4, 2, 0, 0, 0, 8, 1, 2, 8]),
		ex("stamp-backwards-reload", [0, 0, 8, 11, 2, 250, 10, 0, 0, 11, 0, 1]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 300),
	test!,
	show: Str.inspect,
})
