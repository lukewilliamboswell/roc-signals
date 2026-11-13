# Copyright © 2026 Luke Boswell and subsequent authors.
# SPDX-License-Identifier: UPL-1.0
# Adapted from roc-automation/tools/roc-policy/src/Sha256.roc at
# 63066d143e409773529d610e1c90d7e44640f885 (UPL-1.0), itself adapted from
# roc-pdf/package/KernelSha256.roc at
# 7cdd4d12f78f3696046a0e3ee7bf3150e6d38dc4 (UPL-1.0).
# SHA-256 constants and round operations follow FIPS PUB 180-4.

ShaState : {
	a : U32,
	b : U32,
	c : U32,
	d : U32,
	e : U32,
	f : U32,
	g : U32,
	h : U32,
}

CompressResult : { schedule : List(U32), state : ShaState }

## Exact-byte SHA-256 for the mount fingerprint and independently rendered
## picture facts. Callers frame the domain and enforce their input-size bound.
## Browser measurement uses WebCrypto and checks this primitive independently.
PictureHash :: [].{

	## Hash already-framed bytes without interpreting any picture or engine data.
	digest : List(U8) -> List(U8)
	digest = digest_message

	## Render a digest for diagnostics and published SHA-256 test vectors.
	hex : List(U8) -> Str
	hex = |input| {
		hashed = digest_message(input)
		digits = "0123456789abcdef".to_utf8()
		var $encoded = List.with_capacity(64)
		for byte in hashed {
			$encoded = $encoded.append(byte_at(digits, byte.shr_wrap(4).to_u64()))
			$encoded = $encoded.append(byte_at(digits, byte.bitwise_and(15).to_u64()))
		}
		Str.from_utf8_lossy($encoded)
	}
}

digest_message : List(U8) -> List(U8)
digest_message = |input| {
	byte_length = input.len()
	if byte_length > 2305843009213693951 {
		crash "SHA-256 input exceeds representable bit length"
	} else {
		bit_length = byte_length * 8
		with_marker_and_length = byte_length + 9
		blocks = ceil_div_64(with_marker_and_length)
		constants = round_constants
		var $state = initial_state
		var $schedule = List.repeat(0, 64)
		var $block = 0
		while $block < blocks {
			compressed = compress_block({ state: $state, input, block: $block, blocks, bit_length, constants, schedule: $schedule })
			$state = compressed.state
			$schedule = compressed.schedule
			$block = $block + 1
		}
		state_bytes($state)
	}
}

initial_state : ShaState
initial_state = {
	a: 0x6a09e667,
	b: 0xbb67ae85,
	c: 0x3c6ef372,
	d: 0xa54ff53a,
	e: 0x510e527f,
	f: 0x9b05688c,
	g: 0x1f83d9ab,
	h: 0x5be0cd19,
}

round_constants : List(U32)
round_constants = [
	0x428a2f98,
	0x71374491,
	0xb5c0fbcf,
	0xe9b5dba5,
	0x3956c25b,
	0x59f111f1,
	0x923f82a4,
	0xab1c5ed5,
	0xd807aa98,
	0x12835b01,
	0x243185be,
	0x550c7dc3,
	0x72be5d74,
	0x80deb1fe,
	0x9bdc06a7,
	0xc19bf174,
	0xe49b69c1,
	0xefbe4786,
	0x0fc19dc6,
	0x240ca1cc,
	0x2de92c6f,
	0x4a7484aa,
	0x5cb0a9dc,
	0x76f988da,
	0x983e5152,
	0xa831c66d,
	0xb00327c8,
	0xbf597fc7,
	0xc6e00bf3,
	0xd5a79147,
	0x06ca6351,
	0x14292967,
	0x27b70a85,
	0x2e1b2138,
	0x4d2c6dfc,
	0x53380d13,
	0x650a7354,
	0x766a0abb,
	0x81c2c92e,
	0x92722c85,
	0xa2bfe8a1,
	0xa81a664b,
	0xc24b8b70,
	0xc76c51a3,
	0xd192e819,
	0xd6990624,
	0xf40e3585,
	0x106aa070,
	0x19a4c116,
	0x1e376c08,
	0x2748774c,
	0x34b0bcb5,
	0x391c0cb3,
	0x4ed8aa4a,
	0x5b9cca4f,
	0x682e6ff3,
	0x748f82ee,
	0x78a5636f,
	0x84c87814,
	0x8cc70208,
	0x90befffa,
	0xa4506ceb,
	0xbef9a3f7,
	0xc67178f2,
]

compress_block : { state : ShaState, input : List(U8), block : U64, blocks : U64, bit_length : U64, constants : List(U32), schedule : List(U32) } -> CompressResult
compress_block = |{ state, input, block, blocks, bit_length, constants, schedule }| {
	block_start = block * 64
	var $schedule = schedule
	var $word = 0
	while $word < 16 {
		byte_start = block_start + $word * 4
		value = padded_byte(input, { index: byte_start, blocks, bit_length }).to_u32().shl_wrap(24)
			.bitwise_or(padded_byte(input, { index: byte_start + 1, blocks, bit_length }).to_u32().shl_wrap(16))
			.bitwise_or(padded_byte(input, { index: byte_start + 2, blocks, bit_length }).to_u32().shl_wrap(8))
			.bitwise_or(padded_byte(input, { index: byte_start + 3, blocks, bit_length }).to_u32())
		$schedule = $schedule.set($word, value) ?? crash "PictureHash: schedule has every round word"
		$word = $word + 1
	}
	while $word < 64 {
		before_15 = word_at($schedule, $word - 15)
		before_2 = word_at($schedule, $word - 2)
		small_0 = rotate_right(before_15, 7).bitwise_xor(rotate_right(before_15, 18)).bitwise_xor(before_15.shr_wrap(3))
		small_1 = rotate_right(before_2, 17).bitwise_xor(rotate_right(before_2, 19)).bitwise_xor(before_2.shr_wrap(10))
		value = word_at($schedule, $word - 16).plus_wrap(small_0).plus_wrap(word_at($schedule, $word - 7)).plus_wrap(small_1)
		$schedule = $schedule.set($word, value) ?? crash "PictureHash: schedule has every round word"
		$word = $word + 1
	}

	var $working = state
	var $round = 0
	while $round < 64 {
		big_1 = rotate_right($working.e, 6).bitwise_xor(rotate_right($working.e, 11)).bitwise_xor(rotate_right($working.e, 25))
		choice = $working.e.bitwise_and($working.f).bitwise_xor($working.e.bitwise_xor(0xffffffff).bitwise_and($working.g))
		temporary_1 = $working.h.plus_wrap(big_1).plus_wrap(choice).plus_wrap(word_at(constants, $round)).plus_wrap(word_at($schedule, $round))
		big_0 = rotate_right($working.a, 2).bitwise_xor(rotate_right($working.a, 13)).bitwise_xor(rotate_right($working.a, 22))
		majority = $working.a.bitwise_and($working.b).bitwise_xor($working.a.bitwise_and($working.c)).bitwise_xor($working.b.bitwise_and($working.c))
		temporary_2 = U32.plus_wrap(big_0, majority)
		$working = {
			a: U32.plus_wrap(temporary_1, temporary_2),
			b: $working.a,
			c: $working.b,
			d: $working.c,
			e: U32.plus_wrap($working.d, temporary_1),
			f: $working.e,
			g: $working.f,
			h: $working.g,
		}
		$round = $round + 1
	}

	{
		schedule: $schedule,
		state: {
			a: U32.plus_wrap(state.a, $working.a),
			b: U32.plus_wrap(state.b, $working.b),
			c: U32.plus_wrap(state.c, $working.c),
			d: U32.plus_wrap(state.d, $working.d),
			e: U32.plus_wrap(state.e, $working.e),
			f: U32.plus_wrap(state.f, $working.f),
			g: U32.plus_wrap(state.g, $working.g),
			h: U32.plus_wrap(state.h, $working.h),
		},
	}
}

padded_byte : List(U8), { index : U64, blocks : U64, bit_length : U64 } -> U8
padded_byte = |input, { index, blocks, bit_length }| {
	input_length = input.len()
	total_length = blocks * 64
	if index < input_length {
		byte_at(input, index)
	} else if index == input_length {
		128
	} else if index >= total_length - 8 {
		shift = ((total_length - 1 - index) * 8).to_u8_wrap()
		bit_length.shr_wrap(shift).to_u8_wrap()
	} else {
		0
	}
}

rotate_right : U32, U8 -> U32
rotate_right = |value, bits| value.shr_wrap(bits).bitwise_or(value.shl_wrap(32 - bits))

ceil_div_64 : U64 -> U64
ceil_div_64 = |value| U64.div_by(value, 64) + (if (U64.mod_by(value, 64) == 0) 0 else 1)

state_bytes : ShaState -> List(U8)
state_bytes = |state| {
	var $bytes = List.with_capacity(32)
	$bytes = append_word($bytes, state.a)
	$bytes = append_word($bytes, state.b)
	$bytes = append_word($bytes, state.c)
	$bytes = append_word($bytes, state.d)
	$bytes = append_word($bytes, state.e)
	$bytes = append_word($bytes, state.f)
	$bytes = append_word($bytes, state.g)
	append_word($bytes, state.h)
}

append_word : List(U8), U32 -> List(U8)
append_word = |output, word| output
	.append(word.shr_wrap(24).to_u8_wrap())
	.append(word.shr_wrap(16).to_u8_wrap())
	.append(word.shr_wrap(8).to_u8_wrap())
	.append(word.to_u8_wrap())

word_at : List(U32), U64 -> U32
word_at = |words, index| match words.get(index) {
	Ok(word) => word
	Err(OutOfBounds) => {
		crash "SHA-256 schedule invariant failed"
	}
}

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| match bytes.get(index) {
	Ok(byte) => byte
	Err(OutOfBounds) => {
		crash "SHA-256 input invariant failed"
	}
}

## SHA-256 agrees with published empty and abc vectors and independently
## generated vectors around both padding boundaries and multiple blocks.
expect {
	actual = ["", "abc", Str.repeat("a", 55), Str.repeat("a", 56), Str.repeat("a", 63), Str.repeat("a", 64), Str.repeat("a", 65), Str.repeat("a", 1000)].map(|text| PictureHash.hex(text.to_utf8()))
	actual == [
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
		"b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
		"7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
		"ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
		"635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
		"41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
	]
}

## Binary inputs retain every byte, including NUL and non-UTF-8 sequences.
expect {
	var $input = []
	for value in 0.U16..<256 {
		$input = $input.append(value.to_u8_wrap())
	}
	input = $input
	PictureHash.hex(input) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"
}
