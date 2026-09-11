import pf.Files

## Follows a UTF-8 log through the platform's file primitives. Each read takes
## a caller-owned position and returns at most 64 KiB with the cursor to
## continue from. The cursor carries the file's identity: a path that now
## names a different file restarts as `Rotated`, and a file shorter than the
## cursor restarts as `Truncated`. Only complete UTF-8 is consumed, so a code
## point cut by the chunk bound is retried from the returned offset.
LogReader := [].{
	Cursor : { device : U64, inode : U64, offset : U64 }
	Position := [Start, End, After(Cursor)].{
		is_eq : _
	}
	Change := [Initial, Continued, Rotated, Truncated].{
		is_eq : _
	}
	State := [More, AtEnd, PartialUtf8].{
		is_eq : _
	}
	Chunk : { path : Str, text : Str, cursor : Cursor, change : Change, state : State }
	Request : { path : Str, position : Position }

	chunk_bytes = 65536

	read! : Request => Try(Chunk, Files.Error)
	read! = |request| match Files.stat!(request.path) {
		Err(error) => Err(error)
		Ok(meta) => {
			if meta.kind != File {
				return Err(InvalidPath(request.path))
			}
			start = match request.position {
				Start => { offset: 0, change: Initial }
				End => { offset: meta.bytes, change: Initial }
				After(cursor) => if cursor.device != meta.device or cursor.inode != meta.inode {
					{ offset: 0, change: Rotated }
				} else if cursor.offset > meta.bytes {
					{ offset: 0, change: Truncated }
				} else {
					{ offset: cursor.offset, change: Continued }
				}
			}
			match Files.read_bytes!({ path: request.path, offset: start.offset, max_bytes: chunk_bytes }) {
				Err(error) => Err(error)
				Ok(read) => match complete_utf8(read.bytes) {
					Err(_) => Err(InvalidUtf8(request.path))
					Ok(text) => {
						consumed = text.to_utf8().len()
						held_back = read.bytes.len() - consumed
						end = start.offset + read.bytes.len()
						state = if end < read.size {
							More
						} else if held_back > 0 {
							PartialUtf8
						} else {
							AtEnd
						}
						Ok({
							path: request.path,
							text,
							cursor: { device: meta.device, inode: meta.inode, offset: start.offset + consumed },
							change: start.change,
							state,
						})
					}
				}
			}
		}
	}

	## The longest prefix that is complete UTF-8; an incomplete final code
	## point of up to three bytes is held back, and invalid bytes are refused.
	complete_utf8 : List(U8) -> Try(Str, [InvalidUtf8])
	complete_utf8 = |bytes| complete_from(bytes, 0)

	complete_from : List(U8), U64 -> Try(Str, [InvalidUtf8])
	complete_from = |bytes, dropped| match Str.from_utf8(bytes) {
		Ok(text) => Ok(text)
		Err(_) => match bytes.last() {
			# Only a continuation or lead byte at the end can be an incomplete
			# code point; anything else is invalid content.
			Ok(byte) if ((byte >= 128 and byte <= 191) or (byte >= 194 and byte <= 244)) and dropped < 3 => complete_from(bytes.take_first(bytes.len() - 1), dropped + 1)
			_ => Err(InvalidUtf8)
		}
	}
}

expect LogReader.complete_utf8("ab".to_utf8()) == Ok("ab")
expect LogReader.complete_utf8("aλ".to_utf8().take_first(2)) == Ok("a")
expect LogReader.complete_utf8([0xff]) == Err(InvalidUtf8)
