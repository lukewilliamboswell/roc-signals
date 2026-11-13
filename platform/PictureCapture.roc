## Passive command boundaries retained only while a picture mount runs. Port
## bytes are inserted at the end of a turn; sealing rebases that turn once,
## without revisiting commands sealed by earlier follow-up turns.
PictureCapture :: [].{

	## A mount may capture at most this many commands, row holes and INST aliases.
	## Exhaustion refuses picture planning; it never truncates the ordinary batch.
	max_records : U64
	max_records = 262144

	## A command's original boundary and its fixed-prefix address. Opcode zero
	## denotes a secondary INST alias;255 describes a row hole without giving it
	## a new address. Both carry the INST boundary, hole index and exact kind.
	Frame : { at : U32, end : U32, opcode : U8, address : U32, slot : U32, kind : U8 }

	## Disabled mounts allocate no records. Refused drops every captured record
	## immediately, leaving application execution and command output untouched.
	Capture :: [Disabled, Collecting({ sealed : List(Frame), pending : List(Frame), limit : U64 }), Refused([CaptureLimit, InvalidBoundary])]

	## Ordinary mounts and every event have no picture collector.
	disabled : Capture
	disabled = Disabled

	## Enable a bounded collector for the one mount whose picture is being made
	## or checked. Its records contain no application value or reactive closure.
	Props := { max_records : U64 ?? 262144 }

	## Start collecting this mount only; invalid bounds cannot enable capture.
	start : Props -> Try(Capture, [InvalidCaptureLimit])
	start = |props| if props.max_records == 0 or props.max_records > PictureCapture.max_records {
		Err(InvalidCaptureLimit)
	} else {
		Ok(Collecting({ sealed: [], pending: [], limit: props.max_records }))
	}

	## Whether further command records can be retained. Once refused, no later
	## emitter allocates temporary alias or insertion records.
	is_collecting : Capture -> Bool
	is_collecting = |capture| match capture {
		Collecting(_) => True
		Disabled | Refused(_) => False
	}

	## The port writer bounds its temporary insertion list by the remaining
	## capture budget, before appending any insertion record.
	remaining : Capture -> U64
	remaining = |capture| match capture {
		Collecting({ sealed, pending, limit }) => limit - sealed.len() - pending.len()
		Disabled | Refused(_) => 0
	}

	## Refuse metadata allocation while leaving ordinary command writing active.
	refuse_limit : Capture -> Capture
	refuse_limit = |capture| match capture {
		Collecting(_) => Refused(CaptureLimit)
		Disabled | Refused(_) => capture
	}

	## Record a command after its bytes have been written. The caller supplies
	## the already-decided address, not a node found by inspecting application data.
	command : Capture, { at : U64, end : U64, opcode : U8, address : U32, slot : U32 } -> Capture
	command = |capture, emitted| match capture {
		Disabled | Refused(_) => capture
		Collecting(parts) => if emitted.at == 0 or emitted.end <= emitted.at or emitted.end > 4294967295 or emitted.opcode == 0 or emitted.opcode > 26 {
			Refused(InvalidBoundary)
		} else {
			append(Collecting(parts), { at: emitted.at.to_u32_wrap(), end: emitted.end.to_u32_wrap(), opcode: emitted.opcode, address: emitted.address, slot: emitted.slot, kind: 0 })
		}
	}

	## A row's bind/reference aliases are born by its INST, not by a later
	## command. Their shared birth offset keeps numeric address reuse unambiguous.
	alias : Capture, { at : U64, end : U64, address : U32, hole : U32, kind : U8 } -> Capture
	alias = |capture, birth| match capture {
		Disabled | Refused(_) => capture
		Collecting(parts) => if birth.at == 0 or birth.end <= birth.at or birth.end > 4294967295 or birth.address == 0 or (birth.kind != 4 and birth.kind != 5) {
			Refused(InvalidBoundary)
		} else {
			append(Collecting(parts), { at: birth.at.to_u32_wrap(), end: birth.end.to_u32_wrap(), opcode: 0, address: birth.address, slot: birth.hole, kind: birth.kind })
		}
	}

	## Every cached row hole belongs to its row birth, including attribute,
	## event and property holes which allocate no separate command address.
	## Recording the compiled kind lets Core validate claims without reparsing
	## templates or borrowing the row's values.
	hole : Capture, { at : U64, end : U64, row : U32, index : U32, kind : U8 } -> Capture
	hole = |capture, target| match capture {
		Disabled | Refused(_) => capture
		Collecting(parts) => if target.at == 0 or target.end <= target.at or target.end > 4294967295 or target.row == 0 or target.kind < 1 or target.kind > 6 {
			Refused(InvalidBoundary)
		} else {
			append(Collecting(parts), { at: target.at.to_u32_wrap(), end: target.end.to_u32_wrap(), opcode: 255, address: target.row, slot: target.index, kind: target.kind })
		}
	}

	## Port commands enter at positions in the turn's original byte buffer.
	## Equal positions retain request order; every position is a command boundary.
	Insertion : { at : U64, bytes : U64, opcode : U8 }

	## Seal only this turn's pending records. Merge inserted ports and rebase
	## offsets in one ordered pass, keeping earlier sealed records in place.
	seal : Capture, List(Insertion) -> Capture
	seal = |capture, insertions| match capture {
		Disabled | Refused(_) => capture
		Collecting({ sealed, pending, limit }) => {
			var $sealed = sealed
			var $insert = 0.U64
			var $shift = 0.U64
			var $last_end = match $sealed.last() {
				Ok(frame) => frame.end.to_u64()
				Err(_) => 1
			}
			var $previous_at = $last_end
			for frame in pending {
				at = frame.at.to_u64()
				if at < $previous_at {
					return Refused(InvalidBoundary)
				}
				while $insert < insertions.len() {
					insertion = insertions.get($insert) ?? crash "PictureCapture.seal: guarded insertion index"
					if insertion.at > at {
						break
					}
					if insertion.at != at or insertion.bytes == 0 or insertion.bytes > 4294967295 or (insertion.opcode != 13 and insertion.opcode != 19) {
						return Refused(InvalidBoundary)
					}
					end = insertion.at + $shift + insertion.bytes
					if end > 4294967295 {
						return Refused(InvalidBoundary)
					}
					if $sealed.len() >= limit {
						return Refused(CaptureLimit)
					}
					$sealed = $sealed.append({ at: (insertion.at + $shift).to_u32_wrap(), end: end.to_u32_wrap(), opcode: insertion.opcode, address: 0, slot: 0, kind: 0 })
					$shift = $shift + insertion.bytes
					$insert = $insert + 1
				}
				if frame.end.to_u64() + $shift > 4294967295 {
					return Refused(InvalidBoundary)
				}
				if $sealed.len() >= limit {
					return Refused(CaptureLimit)
				}
				$sealed = $sealed.append({ ..frame, at: (at + $shift).to_u32_wrap(), end: (frame.end.to_u64() + $shift).to_u32_wrap() })
				$previous_at = at
				$last_end = frame.end.to_u64()
			}
			while $insert < insertions.len() {
				insertion = insertions.get($insert) ?? crash "PictureCapture.seal: guarded trailing insertion"
				if insertion.at != $last_end or insertion.bytes == 0 or insertion.bytes > 4294967295 or (insertion.opcode != 13 and insertion.opcode != 19) {
					return Refused(InvalidBoundary)
				}
				end = insertion.at + $shift + insertion.bytes
				if end > 4294967295 {
					return Refused(InvalidBoundary)
				}
				if $sealed.len() >= limit {
					return Refused(CaptureLimit)
				}
				$sealed = $sealed.append({ at: (insertion.at + $shift).to_u32_wrap(), end: end.to_u32_wrap(), opcode: insertion.opcode, address: 0, slot: 0, kind: 0 })
				$shift = $shift + insertion.bytes
				$insert = $insert + 1
			}
			Collecting({ sealed: $sealed, pending: pending.clear(), limit })
		}
	}

	## Move the completed records out before returning the initialized App. A
	## disabled or refused capture cannot masquerade as an empty successful plan.
	finish : Capture -> Try(List(Frame), [NotCaptured, CaptureLimit, InvalidBoundary])
	finish = |capture| match PictureCapture.seal(capture, []) {
		Disabled => Err(NotCaptured)
		Refused(reason) => Err(reason)
		Collecting({ sealed, .. }) => Ok(sealed)
	}
}

append : PictureCapture.Capture, PictureCapture.Frame -> PictureCapture.Capture
append = |capture, frame| match capture {
	Collecting({ sealed, pending, limit }) => if sealed.len() + pending.len() >= limit {
		Refused(CaptureLimit)
	} else {
		Collecting({ sealed, pending: pending.append(frame), limit })
	}
	Disabled | Refused(_) => capture
}

## Inserting two ports before INST shifts its secondary alias by the same
## amount, while a port after it retains its own stream position.
expect {
	capture = PictureCapture.start({ max_records: 8 })?
	row = PictureCapture.command(capture, { at: 1, end: 18, opcode: 1, address: 3, slot: 7 })
	alias = PictureCapture.alias(row, { at: 1, end: 18, address: 4, hole: 2, kind: 5 })
	sealed = PictureCapture.seal(alias, [{ at: 1, bytes: 9, opcode: 19 }, { at: 1, bytes: 6, opcode: 13 }, { at: 18, bytes: 5, opcode: 19 }])
	PictureCapture.finish(sealed)? == [
		{ at: 1, end: 10, opcode: 19, address: 0, slot: 0, kind: 0 },
		{ at: 10, end: 16, opcode: 13, address: 0, slot: 0, kind: 0 },
		{ at: 16, end: 33, opcode: 1, address: 3, slot: 7, kind: 0 },
		{ at: 16, end: 33, opcode: 0, address: 4, slot: 2, kind: 5 },
		{ at: 33, end: 38, opcode: 19, address: 0, slot: 0, kind: 0 },
	]
}

## A later turn reuses an address after removal. Its insertions never move
## the earlier birth; the two incarnations remain distinct by offset.
expect {
	start = PictureCapture.start({ max_records: 8 })?
	first = PictureCapture.command(start, { at: 1, end: 10, opcode: 10, address: 2, slot: 0 })
	removed = PictureCapture.command(first, { at: 10, end: 15, opcode: 5, address: 2, slot: 0 })
	sealed = PictureCapture.seal(removed, [])
	second = PictureCapture.command(sealed, { at: 15, end: 24, opcode: 10, address: 2, slot: 0 })
	finished = PictureCapture.finish(PictureCapture.seal(second, [{ at: 15, bytes: 6, opcode: 19 }]))?
	finished.map(|frame| { at: frame.at, end: frame.end, opcode: frame.opcode, address: frame.address }) == [
		{ at: 1, end: 10, opcode: 10, address: 2 },
		{ at: 10, end: 15, opcode: 5, address: 2 },
		{ at: 15, end: 21, opcode: 19, address: 0 },
		{ at: 21, end: 30, opcode: 10, address: 2 },
	]
}

## A port-only turn has a real command even when no ordinary emitter ran.
expect {
	capture = PictureCapture.start({ max_records: 1 })?
	PictureCapture.finish(PictureCapture.seal(capture, [{ at: 1, bytes: 12, opcode: 19 }]))? == [
		{ at: 1, end: 13, opcode: 19, address: 0, slot: 0, kind: 0 },
	]
}

## Exhaustion, including insertion during sealing, refuses the whole capture.
## A disabled collector cannot allocate or turn itself into an enabled one.
expect {
	start = PictureCapture.start({ max_records: 1 })?
	first = PictureCapture.command(start, { at: 1, end: 6, opcode: 5, address: 1, slot: 0 })
	over = PictureCapture.command(first, { at: 6, end: 11, opcode: 5, address: 2, slot: 0 })
	inserted = PictureCapture.seal(first, [{ at: 6, bytes: 9, opcode: 19 }])
	disabled = PictureCapture.command(PictureCapture.disabled, { at: 1, end: 6, opcode: 5, address: 1, slot: 0 })
	PictureCapture.finish(over) == Err(CaptureLimit) and PictureCapture.finish(inserted) == Err(CaptureLimit) and PictureCapture.finish(disabled) == Err(NotCaptured)
}

## Unknown commands, out-of-range offsets and insertions inside a command
## refuse capture rather than producing a partial or ambiguous plan.
expect {
	start = PictureCapture.start({ max_records: 8 })?
	first = PictureCapture.command(start, { at: 1, end: 10, opcode: 10, address: 1, slot: 0 })
	cases = [
		PictureCapture.command(start, { at: 0, end: 1, opcode: 5, address: 1, slot: 0 }),
		PictureCapture.command(start, { at: 1, end: 1, opcode: 5, address: 1, slot: 0 }),
		PictureCapture.command(start, { at: 1, end: 4294967296, opcode: 5, address: 1, slot: 0 }),
		PictureCapture.command(start, { at: 1, end: 2, opcode: 27, address: 1, slot: 0 }),
		PictureCapture.seal(first, [{ at: 4, bytes: 9, opcode: 19 }]),
		PictureCapture.alias(first, { at: 1, end: 10, address: 2, hole: 1, kind: 1 }),
	]
	cases.all(|capture| PictureCapture.finish(capture) == Err(InvalidBoundary)) and PictureCapture.start({ max_records: 0 }).is_err() and PictureCapture.start({ max_records: PictureCapture.max_records + 1 }).is_err()
}

## Hole facts are not births. Every compiled kind retains its row, index and
## shared INST boundary when a port shifts the command before sealing.
expect {
	start = PictureCapture.start({ max_records: 8 })?
	row = PictureCapture.command(start, { at: 1, end: 24, opcode: 1, address: 7, slot: 3 })
	var $capture = row
	for kind in 1.U8..=6 {
		$capture = PictureCapture.hole($capture, { at: 1, end: 24, row: 7, index: (kind - 1).to_u32(), kind })
	}
	frames = PictureCapture.finish(PictureCapture.seal($capture, [{ at: 1, bytes: 9, opcode: 19 }]))?
	facts = frames.keep_if(|frame| frame.opcode == 255)
	facts.len() == 6 and facts.map(|frame| frame.kind) == [1, 2, 3, 4, 5, 6] and facts.all(|frame| frame.at == 10 and frame.end == 33 and frame.address == 7 and frame.slot == (frame.kind - 1).to_u32())
}
