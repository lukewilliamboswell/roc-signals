## Transport framing for engine-only picture facts. The claim codec validates
## the envelope separately; this module owns only presence, lengths and bounds.
PictureBoot :: [].{

	## A protocol ceiling; a deployment may impose a smaller picture-byte limit.
	max_bytes : U64
	max_bytes = 16_777_216

	## A measured digest accompanies the exact producer envelope. Neither is
	## application Boot or retained application state.
	Input :: [Absent, Present({ measured : List(U8), envelope : List(U8) })]

	## No picture facts were supplied. Normal mounting needs no measurement.
	absent : Input
	absent = Absent

	## Check transport bounds before encoding or staging the picture section.
	present : { measured : List(U8), envelope : List(U8) } -> Try(Input, [BadPictureBoot(Str)])
	present = |facts| {
		if facts.measured.len() != 32 {
			return Err(BadPictureBoot("picture measurement must contain 32 bytes"))
		}
		if facts.envelope.is_empty() {
			return Err(BadPictureBoot("picture envelope must not be empty"))
		}
		if facts.envelope.len() > PictureBoot.max_bytes - 37 {
			return Err(BadPictureBoot("picture facts exceed the protocol byte limit"))
		}
		Ok(Present(facts))
	}

	## Decode a bounded section body, consuming every byte. Envelope syntax and
	## the measured tree's meaning are the claim codec and engine's responsibility.
	read : List(U8) -> Try(Input, [BadPictureBoot(Str)])
	read = |bytes| {
		if bytes.len() > PictureBoot.max_bytes {
			return Err(BadPictureBoot("picture facts exceed the protocol byte limit"))
		}
		match bytes {
			[0] => Ok(Absent)
			[1, ..] if bytes.len() >= 37 => {
				count = (bytes.get(33) ?? crash "PictureBoot: guarded length includes count").to_u32()
					.bitwise_or((bytes.get(34) ?? crash "PictureBoot: guarded length includes count").to_u32().shl_wrap(8))
					.bitwise_or((bytes.get(35) ?? crash "PictureBoot: guarded length includes count").to_u32().shl_wrap(16))
					.bitwise_or((bytes.get(36) ?? crash "PictureBoot: guarded length includes count").to_u32().shl_wrap(24))
				if count.to_u64() != bytes.len() - 37 {
					return Err(BadPictureBoot("picture envelope length does not consume the section"))
				}
				PictureBoot.present({ measured: bytes.sublist({ start: 1, len: 32 }), envelope: bytes.drop_first(37) })
			}
			_ => Err(BadPictureBoot("invalid or truncated picture facts"))
		}
	}

	## Write the one canonical transport representation of checked facts.
	write : Input -> List(U8)
	write = |input| match input {
		Absent => [0]
		Present(facts) => {
			count = facts.envelope.len().to_u32_wrap()
			[1].concat(facts.measured)
				.append(count.to_u8_wrap())
				.append(count.shr_wrap(8).to_u8_wrap())
				.append(count.shr_wrap(16).to_u8_wrap())
				.append(count.shr_wrap(24).to_u8_wrap())
				.concat(facts.envelope)
		}
	}

	## Hand checked facts to the engine's claim decoder without decoding twice.
	parts : Input -> [Absent, Present({ measured : List(U8), envelope : List(U8) })]
	parts = |input| match input {
		Absent => Absent
		Present(value) => Present(value)
	}
}

## Presence is explicit; a digest and arbitrary binary envelope survive framing.
expect {
	input = PictureBoot.present({ measured: List.repeat(0x80, 32), envelope: [83, 80, 67, 49, 0, 255] })?
	decoded = PictureBoot.read(PictureBoot.write(input))?
	PictureBoot.parts(decoded) == PictureBoot.parts(input) and PictureBoot.write(PictureBoot.absent) == [0]
}

## Missing bytes, unknown presence, oversized lengths and trailing bytes cannot
## become an absent picture or a partially accepted measurement.
expect {
	valid = PictureBoot.write(PictureBoot.present({ measured: List.repeat(0, 32), envelope: [83] })?)
	cases = [[], [2], [0, 0], [1], [1].concat(List.repeat(0, 32)), valid.drop_last(1), valid.append(0), [1].concat(List.repeat(0, 32)).concat([255, 255, 255, 255])]
	cases.all(|bytes| PictureBoot.read(bytes).is_err()) and PictureBoot.present({ measured: [], envelope: [83] }).is_err() and PictureBoot.present({ measured: List.repeat(0, 32), envelope: [] }).is_err()
}
