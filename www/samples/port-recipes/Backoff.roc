## The app's reconnect policy: five bounded waits and a deterministic stream
## seeded from both halves of the document's boot seed. No browser clock is read.
Backoff := [].{
	seed : U128 -> U64
	seed = |value| value.to_u64_wrap().bitwise_xor(value.shr_zf_wrap(64).to_u64_wrap())

	next : U64 -> { state : U64, value : U64 }
	next = |state| {
		next_state = state.plus_wrap(11400714819323198485)
		a = next_state.bitwise_xor(next_state.shr_zf_wrap(30)).times_wrap(13787848793156543929)
		b = a.bitwise_xor(a.shr_zf_wrap(27)).times_wrap(10723151780598845931)
		{ state: next_state, value: b.bitwise_xor(b.shr_zf_wrap(31)) }
	}

	## Each retry doubles the base; jitter is from zero through a quarter of it.
	delay : { attempt : U32, random : U64 } -> U32
	delay = |{ attempt, random }| {
		base = match attempt {
			1 => 1000.U32
			2 => 2000
			3 => 4000
			4 => 8000
			5 => 16000
			_ => crash "Backoff.delay: attempt must be 1 through 5"
		}
		base + (random % ((base // 4) + 1).to_u64()).to_u32_wrap()
	}
}

## Every allowed wait has the stated base and at most a quarter in jitter.
expect [1.U32, 2, 3, 4, 5].map(|attempt| Backoff.delay({ attempt, random: 0 })) == [1000, 2000, 4000, 8000, 16000]

expect [0.U64, 1, 250, 251, 18446744073709551615].all(
	|random| [1.U32, 2, 3, 4, 5].all(
		|attempt| {
			base = Backoff.delay({ attempt, random: 0 })
			delay = Backoff.delay({ attempt, random })
			delay >= base and delay <= base + base // 4
		},
	),
)

expect Backoff.next(Backoff.seed(7)).value == 7191089600892374487
