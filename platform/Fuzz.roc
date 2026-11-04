import Arbitrary
import Binary
import Target

decode_input : Fuzz.Generator(a), List(U8) -> Try(a, [InvalidInput])
	where [a.Fuzz.Parseable(errs)]
decode_input = |generator, input|
	match Binary.form(input) {
		Ok(Entropy(bytes)) => Ok(generator(Arbitrary.new(bytes)).value)
		Ok(Encoded) => Binary.decode(input).map_err(|_| InvalidInput)
		Err(_) => Err(InvalidInput)
	}

# Sequence decoder ownership cleanup before the first scope effect. A pure
# decoder's cursor drops may otherwise move past scope_start! into the region.
prepare_input! : Fuzz.Generator(a), List(U8) => Try(a, [InvalidInput])
	where [a.Fuzz.Parseable(errs)]
prepare_input! = |generator, input| decode_input(generator, input)

## Define typed, deterministic inputs and the pure property that roc-fuzz tests.
##
## Most targets use [`target`](#Fuzz.target), return [`keep`](#Fuzz.keep) for useful
## inputs, and build their input generator from `u8`, `u64`, `str`, `bytes`,
## and `list`. Generators for record fields compose with Roc's `.Fuzz` record
## builder.
##
## ```roc
## Input := { bytes : List(U8), radix : U8 }.{
## 	parser_for : _
## 	encoder_for : _
##
## 	generator_for = |_| {
## 		{ bytes: Fuzz.bytes, radix: Fuzz.u8_in(2, 36) }.Fuzz
## 	}
## }
##
## target = Fuzz.target({
## 	examples: [],
## 	name: "decode",
## 	test: |input| if input.bytes.is_empty() Fuzz.reject else Fuzz.keep,
## 	show: Str.inspect,
## })
## ```
##
## Start with these typed combinators. [`target_with`](#Fuzz.target_with),
## [`from_bytes`](#Fuzz.from_bytes), and the `Arbitrary` module support advanced or
## migration use cases.
Fuzz := [].{

	## Whether a generated value belongs to the useful input domain.
	##
	## Return `Keep` after the property holds. Return `Reject` when a generated
	## value does not satisfy a precondition. A `crash` or failed `expect` is a
	## fuzz failure; `Reject` is not.
	Outcome := [Keep, Reject]

	## Mark a generated value as useful after the property has held.
	keep : Outcome
	keep = Keep

	## Total application allocations the platform has served this process so far.
	## Private measurement ownership containers are excluded from all counters.
	##
	## Read it before and after a region of code and subtract to count that
	## region's allocations. Counts every `roc_alloc` and `roc_realloc`; a
	## reallocation counts as one allocation.
	##
	## The absolute value is meaningless across runs -- the counter is
	## process-wide and the fuzzer reuses the process for millions of inputs --
	## so always assert on a difference, never on the raw number.
	alloc_count! : () => U64

	## Allocations served but not yet freed.
	##
	## A region that frees everything it allocates leaves this unchanged. Use
	## it to assert that a property does not leak; see
	## [`expect_no_leaks!`](#Fuzz.expect_no_leaks).
	live_alloc_count! : () => U64

	## `roc_realloc` calls the platform has served this process so far.
	##
	## Like [`alloc_count!`](#Fuzz.alloc_count), it is process-wide and never
	## reset, so only a difference across a region is meaningful.
	realloc_count! : () => U64

	## `roc_dealloc` calls the platform has served this process so far.
	##
	## A reallocation frees the block it replaces without counting a
	## deallocation. Only a difference across a region is meaningful.
	dealloc_count! : () => U64

	## Bytes requested from the platform's allocator this process so far.
	##
	## An allocation adds its requested length and a reallocation adds the full
	## new length it asks for, whether it grows or shrinks the block. A
	## deallocation adds nothing, and a zero-length request adds zero. This is
	## allocator traffic: it is not the heap still in use, the process's
	## resident memory, or the bytes a reallocation copies. A request the
	## allocator cannot serve ends the process, so every request a completed
	## region made is counted. Arithmetic overflow fails explicitly rather than
	## wrapping or saturating. Only a difference across a region is meaningful.
	requested_bytes! : () => U64

	## Inclusive allocator observations for one named region. Only Roc allocator
	## hooks count; private measurement containers and host bookkeeping are
	## excluded. Peaks include
	## entry-live memory and the actual old/new overlap during reallocations.
	Stats : { allocs : U64, reallocs : U64, deallocs : U64, requested_bytes : U64, entry_live_allocs : U64, entry_live_bytes : U64, exit_live_allocs : U64, exit_live_bytes : U64, peak_live_bytes : U64 }

	## Native scope engine entry point. Prefer start_measure! or measure!.
	scope_start! : Str => U64

	## Native scope engine completion. Invalid or out-of-order scopes fail.
	scope_finish! : U64 => Stats

	## Internal ownership fence preparation. The following return container is
	## platform bookkeeping and is excluded from every allocation observation.
	prepare_return_box! : () => {}

	## Complete a region while the opaque return container owns every returned
	## value. Transfers that container back unchanged; applications use measure!.
	scope_finish_return! : U64, Box(a) => { value : Box(a), stats : Stats }

	## An open named measurement and logical trace region. Finish exactly once.
	Measurement := { id : U64 }.{

		## Complete this measurement, retaining values alive at this boundary.
		finish! : Measurement => Stats
		finish! = |measurement| Fuzz.scope_finish!(measurement.id)
	}

	## Start a manual window using the same engine as measure!.
	start_measure! : Str => Measurement
	start_measure! = |label| Measurement.{ id: Fuzz.scope_start!(label) }

	## Run body! once and automatically record its named allocation statistics.
	## Nested windows are inclusive; the returned value is alive at the boundary.
	measure! : Str, (() => a) => { value : a, stats : Stats }
	measure! = |label, body!| {
		measurement = Fuzz.start_measure!(label)
		value = body!()
		# Opaque host ownership keeps every part of the return alive through
		# finish, including fields the caller discards. The container is marked
		# bookkeeping in every enclosing scope and in the allocator counters.
		Fuzz.prepare_return_box!()
		finished = Fuzz.scope_finish_return!(measurement.id, Box.box(value))
		{ value: Box.unbox(finished.value), stats: finished.stats }
	}

	## Record a direct event in the current logical trace region.
	mark! : Str => {}

	## Require both named events and every first occurrence before every second.
	## Register before any direct event or completed child region occurs.
	before! : Str, Str => {}

	## Require exactly count occurrences in the current region. Register first.
	count! : Str, U64 => {}

	## Forbid an event in the current region. Register before events begin.
	forbidden! : Str => {}

	## A source-declared rule over direct marks and completed child regions.
	TraceRule := [Before(Str, Str), Count(Str, U64), Forbidden(Str)]

	## Register all rules before emitting events. Validation is independent of
	## the bounded diagnostic trace, so truncation cannot hide a violation.
	trace_rules! : List(TraceRule) => {}
	trace_rules! = |rules| {
		for rule in rules {
			match rule {
				Before(first, second) => Fuzz.before!(first, second)
				Count(event, count) => Fuzz.count!(event, count)
				Forbidden(event) => Fuzz.forbidden!(event)
			}
		}
	}

	## Crash unless `body!` performs at most `limit` allocations.
	##
	## This is the allocation analogue of a property assertion: it turns a
	## silent performance regression, such as a builtin that stops mutating a
	## uniquely owned value in place, into a fuzz failure.
	expect_allocs_at_most! : U64, (() => a) => a
	expect_allocs_at_most! = |limit, body!| {
		before = Fuzz.alloc_count!()
		value = body!()
		allocations = Fuzz.alloc_count!() - before
		if allocations > limit {
			crash "expected at most ${limit.to_str()} allocations, but ${allocations.to_str()} were performed"
		}
		value
	}

	## Crash unless `body!` performs at least `limit` allocations.
	##
	## This is useful for copy-on-write invariants: an operation on shared
	## storage must allocate rather than mutate an alias in place.
	expect_allocs_at_least! : U64, (() => a) => a
	expect_allocs_at_least! = |limit, body!| {
		before = Fuzz.alloc_count!()
		value = body!()
		allocations = Fuzz.alloc_count!() - before
		if allocations < limit {
			crash "expected at least ${limit.to_str()} allocations, but ${allocations.to_str()} were performed"
		}
		value
	}

	## Crash unless `body!` frees everything it allocated.
	##
	## The result is dropped before the balance is read, so a value that is
	## still alive does not read as a leak.
	expect_no_leaks! : (() => a) => {}
	expect_no_leaks! = |body!| {
		before = Fuzz.live_alloc_count!()
		_ = body!()
		after = Fuzz.live_alloc_count!()
		if after > before {
			crash "expected no leaked allocations, but ${(after - before).to_str()} were still outstanding"
		}
		{}
	}

	## Discard a generated value that is outside the property's valid domain.
	##
	## Prefer generators that produce valid inputs directly. Use `reject` for
	## preconditions that are awkward or expensive to encode in a generator.
	reject : Outcome
	reject = Reject

	## A deterministic decoder from fuzzer bytes to a typed Roc value.
	##
	## Each generator returns the generated `value` and the unconsumed `state`, so
	## combinators can decode several values from one input. Most applications do
	## not need to inspect `Arbitrary` directly.
	Generator(a) : Arbitrary -> { value : a, state : Arbitrary }

	## Type-only name for the platform's binary codec marker. Roc resolves this
	## through encoder_for/parser_for derivation; applications need no codec value.
	InputFormat : Binary.Format

	## Type-only name for the bounded binary parser cursor. Normal inputs opt
	## in with parser_for : _ rather than constructing or manipulating a cursor.
	InputState : Binary.State

	## Requirement for types that can become source-authored corpus seeds.
	a.Encodable : where [a.encoder_for : Binary.Format -> (a, List(U8) -> Try(List(U8), []))]

	## Requirement for types that can decode mutated source-authored seeds.
	a.Parseable(errs) : where [a.parser_for : Binary.Format -> (Binary.State -> Try({ value : a, rest : Binary.State }, [MalformedInput, BudgetExceeded, ..errs]))]

	## Selects the generator used by a nominal type's `generator_for` method.
	##
	## `Default` is currently the only encoding. The marker gives static dispatch
	## the same shape as APIs such as `Json.parser_for` and leaves room for future
	## generation policies.
	FuzzEncoding := [Default]

	## A named input that always runs during checking, regardless of coverage.
	## Makers are called only while preparing corpus bytes; temporary typed
	## values are released before the property executes in a fresh process.
	Example(a) := [Typed({ name : Str, revision : Str, make : () -> a }), Saved({ name : Str, revision : Str, bytes : List(U8) })]

	## Declare a source-authored typed example. Use a zero-argument maker such
	## as `make: || Input.{ bytes: [], radix: 10 }` to avoid retaining fixtures.
	example : { name : Str, revision : Str, make : () -> a } -> Example(a)
	example = |config| Typed(config)

	## Declare a retained witness using its original bytes and recorded form.
	## Logical rendering never replaces entropy or storage-sensitive artifacts.
	saved : { name : Str, revision : Str, bytes : List(U8) } -> Example(a)
	saved = |config| Saved(config)

	## Encode a logical value as a mutable corpus seed using platform format v1.
	## Float encoding preserves signed zero, infinities and NaN equivalence; Roc
	## canonicalizes NaN payloads. Use integer bit inputs for payload assertions.
	## On nightly-2026-10-27-de79a0f, derived Dict keys containing records or
	## tuples require `--specialize=no` because the default compiler backend
	## crashes while specializing those codecs. Scalar and tag keys work with
	## the default backend.
	encode : a -> List(U8) where [a.Fuzz.Encodable]
	encode = |value| Binary.encode(value)

	## Frame generator entropy while preserving its storage-shape decisions.
	entropy : List(U8) -> List(U8)
	entropy = |bytes| Binary.entropy(bytes)

	## Build a fuzz target using the input type's statically dispatched generator.
	##
	## The input type must define `generator_for : FuzzEncoding -> Generator(a)`.
	## For each fuzzer input, `target` generates one value, calls `test`, and uses
	## `show` when a person asks the runner to render that saved input.
	target : { name : Str, examples : List(Example(a)), test : a -> Outcome, show : a -> Str } -> Target
		where [a.generator_for : FuzzEncoding -> Generator(a), a.Fuzz.Encodable, a.Fuzz.Parseable(errs)]
	target = |config| {
		Shape : a
		generator = Shape.generator_for(Default)
		Fuzz.target_with({
			name: config.name,
			examples: config.examples,
			generator,
			test: config.test,
			show: config.show,
		})
	}

	## Build a target from an explicit generator.
	##
	## This is useful for a one-off structural input that does not need a nominal
	## `generator_for` method. Prefer [`target`](#Fuzz.target) when the input type owns
	## its generation policy.
	target_with : { name : Str, examples : List(Example(a)), generator : Generator(a), test : a -> Outcome, show : a -> Str } -> Target
		where [a.Fuzz.Encodable, a.Fuzz.Parseable(errs)]
	target_with = |config| {
		property = config.test
		Fuzz.target_with!({
			name: config.name,
			examples: config.examples,
			generator: config.generator,
			test!: |value| property(value),
			show: config.show,
		})
	}

	## Effectful sibling of [`target_with`](#Fuzz.target_with).
	##
	## Use this when the property itself needs the platform's allocation
	## counters, for example to assert that a builtin mutates a uniquely owned
	## value in place instead of reallocating.
	target_with! : { name : Str, examples : List(Example(a)), generator : Generator(a), test! : a => Outcome, show : a -> Str } -> Target
		where [a.Fuzz.Encodable, a.Fuzz.Parseable(errs)]
	target_with! = |config| {
		# Capture only the values each callback needs. Capturing config itself
		# would retain saved fixture bytes in the property closure after decode.
		declared_examples = config.examples
		generator = config.generator
		property! = config.test!
		show_value = config.show
		Target.new({
			name: config.name,
			example_count: || declared_examples.len(),
			example: |index| match declared_examples.get(index) {
				Ok(Typed(declared)) => { name: declared.name, revision: declared.revision, bytes: Binary.encode((declared.make)()) }
				Ok(Saved(declared)) => declared
				Err(_) => crash "example index is outside the declared inventory"
			},
			run!: |input| {
				match prepare_input!(generator, input) {
					Ok(value) => {
						measured = Fuzz.measure!("$property", || property!(value))
						match measured.value {
							Keep => 0
							Reject => 1
						}
					}
					Err(_) => 1
				}
			},
			show: |input| {
				match decode_input(generator, input) {
					Ok(value) => show_value(value)
					Err(_) => "<rejected: malformed input or decoding budget exceeded>"
				}
			},
		})
	}

	## Effectful sibling of [`from_bytes`](#Fuzz.from_bytes).
	from_bytes! : { name : Str, examples : List(Example(List(U8))), test! : List(U8) => U8 } -> Target
	from_bytes! = |config| {
		property! = config.test!
		Fuzz.target_with!({
			name: config.name,
			examples: config.examples,
			generator: Fuzz.raw_bytes,
			test!: |input| {
				if (property!(input) == 0) Keep else Reject
			},
			show: |input| Str.inspect(input),
		})
	}

	## Adapt an existing `List(U8) -> U8` quality target.
	##
	## Zero keeps the input; a nonzero byte rejects it. A crash or failed expect
	## remains a failure. New targets usually prefer typed inputs and examples.
	from_bytes : { name : Str, examples : List(Example(List(U8))), test : List(U8) -> U8 } -> Target
	from_bytes = |config| {
		property = config.test
		Fuzz.target_with({
			name: config.name,
			examples: config.examples,
			generator: Fuzz.raw_bytes,
			test: |input| {
				if (property(input) == 0) Keep else Reject
			},
			show: |input| Str.inspect(input),
		})
	}

	## Generate the same value without consuming any input bytes.
	constant : a -> Generator(a)
	constant = |value| |state| { value, state }

	## Transform the value produced by a generator while preserving its state.
	map : Generator(a), (a -> b) -> Generator(b)
	map = |generator, transform| |state| {
		generated = generator(state)
		{ value: transform(generated.value), state: generated.state }
	}

	## Generate two values in sequence and combine them.
	##
	## Roc's `{ first: gen_a, second: gen_b }.Fuzz` record-builder syntax lowers
	## to this combinator and chains it for larger records. Calling `map2`
	## directly is useful for tuples and custom constructors.
	map2 : Generator(a), Generator(b), (a, b -> c) -> Generator(c)
	map2 = |first, second, combine| |state| {
		left = first(state)
		right = second(left.state)
		{ value: combine(left.value, right.value), state: right.state }
	}

	## Generate any `U8` value.
	u8 : Generator(U8)
	u8 = |state| {
		generated = state.u64_in_inclusive_range(0, 255)
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	## Generate a `U8` in the inclusive range from `low` through `high`.
	##
	## The generator crashes if `low` is greater than `high`.
	u8_in : U8, U8 -> Generator(U8)
	u8_in = |low, high| |state| {
		generated = state.u64_in_inclusive_range(U8.to_u64(low), U8.to_u64(high))
		{ value: U64.to_u8_wrap(generated.value), state: generated.state }
	}

	## Generate any `U64` value.
	u64 : Generator(U64)
	u64 = |state| state.u64_in_inclusive_range(0, U64.highest)

	## Generate a `U64` in the inclusive range from `low` through `high`.
	##
	## The generator crashes if `low` is greater than `high`.
	u64_in : U64, U64 -> Generator(U64)
	u64_in = |low, high| |state| state.u64_in_inclusive_range(low, high)

	## Generate an `F32`, biased toward the values that break float code.
	##
	## About half of all generated values come from a fixed table of boundary
	## values: quiet, negative, and signalling `NaN`; positive and negative
	## infinity; positive and negative zero; the smallest and largest subnormals;
	## the smallest normal; `1.0` and `-1.0`; the machine epsilon; `F32.highest`
	## and `F32.lowest`; and `2^24`, the first magnitude at which consecutive
	## integers stop being representable. The other half are arbitrary IEEE 754
	## bit patterns, which are almost always huge or tiny magnitudes.
	##
	## The generator always consumes five bytes, so composing it into a record
	## does not shift the input bytes that later fields decode. Exhausted input
	## produces `0.0`. Use [`f32_in`](#Fuzz.f32_in) when the target needs a finite
	## value within known bounds.
	f32 : Generator(F32)
	f32 = |state| {
		pattern = state.u64_in_inclusive_range(0, 4294967295)
		selection = pattern.state.u64_in_inclusive_range(0, 31)
		value = match selection.value {
			0 => F32.from_bits(0x00000000) # positive zero
			1 => F32.from_bits(0x80000000) # negative zero
			2 => F32.from_bits(0x7FC00000) # quiet NaN
			3 => F32.from_bits(0xFFC00000) # negative quiet NaN
			4 => F32.from_bits(0x7F800001) # signalling NaN
			5 => F32.from_bits(0x7F800000) # positive infinity
			6 => F32.from_bits(0xFF800000) # negative infinity
			7 => F32.from_bits(0x00000001) # smallest positive subnormal
			8 => F32.from_bits(0x007FFFFF) # largest subnormal
			9 => F32.from_bits(0x00800000) # smallest positive normal
			10 => F32.from_bits(0x3F800000) # 1.0
			11 => F32.from_bits(0xBF800000) # -1.0
			12 => F32.from_bits(0x34000000) # machine epsilon
			13 => F32.from_bits(0x7F7FFFFF) # F32.highest
			14 => F32.from_bits(0xFF7FFFFF) # F32.lowest
			15 => F32.from_bits(0x4B800000) # 2^24
			_ => F32.from_bits(U64.to_u32_wrap(pattern.value))
		}

		{ value, state: selection.state }
	}

	## Generate a finite `F32` in the inclusive range from `low` through `high`.
	##
	## Both endpoints are reachable. Unlike [`f32`](#Fuzz.f32), this generator
	## never produces `NaN` or an infinity. It crashes if either bound is not
	## finite or if `low` is greater than `high`.
	f32_in : F32, F32 -> Generator(F32)
	f32_in = |low, high| |state| {
		if !F32.is_finite(low) or !F32.is_finite(high) {
			crash "f32_in requires finite bounds"
		}

		if low > high {
			crash "f32_in requires low to be less than or equal to high"
		}

		# 2^24 - 1 is the largest integer whose successor an F32 can still
		# represent, so this fraction covers [0, 1] without repeating a value.
		choice = state.u64_in_inclusive_range(0, 16777215)
		fraction = U64.to_f32(choice.value) / 16777215.0

		# Interpolating as a weighted average keeps every intermediate product
		# finite even when the bounds span the whole F32 range.
		blended = low * (1.0 - fraction) + high * fraction
		{ value: F32.max(low, F32.min(high, blended)), state: choice.state }
	}

	## Generate an `F64`, biased toward the values that break float code.
	##
	## About half of all generated values come from a fixed table of boundary
	## values: quiet, negative, and signalling `NaN`; positive and negative
	## infinity; positive and negative zero; the smallest and largest subnormals;
	## the smallest normal; `1.0` and `-1.0`; the machine epsilon; `F64.highest`
	## and `F64.lowest`; and `2^53`, the first magnitude at which consecutive
	## integers stop being representable. The other half are arbitrary IEEE 754
	## bit patterns, which are almost always huge or tiny magnitudes.
	##
	## The generator always consumes nine bytes, so composing it into a record
	## does not shift the input bytes that later fields decode. Exhausted input
	## produces `0.0`. Use [`f64_in`](#Fuzz.f64_in) when the target needs a finite
	## value within known bounds.
	f64 : Generator(F64)
	f64 = |state| {
		pattern = state.u64_in_inclusive_range(0, U64.highest)
		selection = pattern.state.u64_in_inclusive_range(0, 31)
		value = match selection.value {
			0 => F64.from_bits(0x0000000000000000) # positive zero
			1 => F64.from_bits(0x8000000000000000) # negative zero
			2 => F64.from_bits(0x7FF8000000000000) # quiet NaN
			3 => F64.from_bits(0xFFF8000000000000) # negative quiet NaN
			4 => F64.from_bits(0x7FF0000000000001) # signalling NaN
			5 => F64.from_bits(0x7FF0000000000000) # positive infinity
			6 => F64.from_bits(0xFFF0000000000000) # negative infinity
			7 => F64.from_bits(0x0000000000000001) # smallest positive subnormal
			8 => F64.from_bits(0x000FFFFFFFFFFFFF) # largest subnormal
			9 => F64.from_bits(0x0010000000000000) # smallest positive normal
			10 => F64.from_bits(0x3FF0000000000000) # 1.0
			11 => F64.from_bits(0xBFF0000000000000) # -1.0
			12 => F64.from_bits(0x3CB0000000000000) # machine epsilon
			13 => F64.from_bits(0x7FEFFFFFFFFFFFFF) # F64.highest
			14 => F64.from_bits(0xFFEFFFFFFFFFFFFF) # F64.lowest
			15 => F64.from_bits(0x4340000000000000) # 2^53
			_ => F64.from_bits(pattern.value)
		}

		{ value, state: selection.state }
	}

	## Generate a finite `F64` in the inclusive range from `low` through `high`.
	##
	## Both endpoints are reachable. Unlike [`f64`](#Fuzz.f64), this generator
	## never produces `NaN` or an infinity. It crashes if either bound is not
	## finite or if `low` is greater than `high`.
	f64_in : F64, F64 -> Generator(F64)
	f64_in = |low, high| |state| {
		if !F64.is_finite(low) or !F64.is_finite(high) {
			crash "f64_in requires finite bounds"
		}

		if low > high {
			crash "f64_in requires low to be less than or equal to high"
		}

		choice = state.u64_in_inclusive_range(0, U64.highest)
		fraction = U64.to_f64(choice.value) / U64.to_f64(U64.highest)

		# Interpolating as a weighted average keeps every intermediate product
		# finite even when the bounds span the whole F64 range.
		blended = low * (1.0 - fraction) + high * fraction
		{ value: F64.max(low, F64.min(high, blended)), state: choice.state }
	}

	## Generate a byte list with a length and allocation shape chosen from input.
	##
	## Use [`raw_bytes`](#Fuzz.raw_bytes) when the target must receive every fuzzer
	## byte unchanged.
	bytes : Generator(List(U8))
	bytes = |state| state.arbitrary_list_u8()

	## Generate the complete fuzzer input as one byte list without decoding it.
	##
	## This is mainly useful for migration and byte-format targets. Typed targets
	## usually get better mutations and clearer properties from smaller
	## generators composed into their real input shape.
	raw_bytes : Generator(List(U8))
	raw_bytes = |state| {
		value: state.remaining(),
		state: Arbitrary.new([]),
	}

	## Generate a valid UTF-8 `Str` with varied length and allocation shape.
	str : Generator(Str)
	str = |state| state.arbitrary_str()

	## Generate a list containing at most `max_len` values.
	##
	## Lengths range from zero through `max_len`, inclusive. `max_len` limits the
	## decoded list length; the runner's maximum raw input size is configured
	## separately.
	list : Generator(a), U64 -> Generator(List(a))
	list = |item_generator, max_len| |initial_state| {
		length_choice = initial_state.u64_in_inclusive_range(0, max_len)
		var $state = length_choice.state
		var $items = []
		var $index = 0

		while $index < length_choice.value {
			generated = item_generator($state)
			$items = List.append($items, generated.value)
			$state = generated.state
			$index = $index + 1
		}

		{ value: $items, state: $state }
	}
}

# Float generator layout: `u64_in_inclusive_range` consumes entropy from the
# end of the input, most significant byte last. A nine-byte input for `f64` is
# therefore `[selector, b0, b1, b2, b3, b4, b5, b6, b7]`, and a five-byte input
# for `f32` is `[selector, b0, b1, b2, b3]`.

# Exhausted input produces positive zero rather than a NaN.
expect F64.to_bits(Fuzz.f64(Arbitrary.new([])).value) == 0
expect F32.to_bits(Fuzz.f32(Arbitrary.new([])).value) == 0

# Consumption is constant, so later fields of a record decode the same bytes
# whichever branch the float generator takes.
expect Fuzz.f64(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])).state.len() == 3
expect Fuzz.f32(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8])).state.len() == 3

# Every entry of the F64 boundary table lands in the class it was chosen for.
expect F64.to_bits(Fuzz.f64(Arbitrary.new([0, 0, 0, 0, 0, 0, 0, 0, 0])).value) == 0
expect F64.to_bits(Fuzz.f64(Arbitrary.new([1, 0, 0, 0, 0, 0, 0, 0, 0])).value) == 0x8000000000000000
expect F64.is_nan(Fuzz.f64(Arbitrary.new([2, 0, 0, 0, 0, 0, 0, 0, 0])).value)
expect F64.is_nan(Fuzz.f64(Arbitrary.new([3, 0, 0, 0, 0, 0, 0, 0, 0])).value)
expect F64.is_nan(Fuzz.f64(Arbitrary.new([4, 0, 0, 0, 0, 0, 0, 0, 0])).value)
expect Fuzz.f64(Arbitrary.new([5, 0, 0, 0, 0, 0, 0, 0, 0])).value == F64.infinity
expect Fuzz.f64(Arbitrary.new([6, 0, 0, 0, 0, 0, 0, 0, 0])).value == F64.infinity.negate()
expect F64.to_bits(Fuzz.f64(Arbitrary.new([7, 0, 0, 0, 0, 0, 0, 0, 0])).value) == 1
expect F64.to_bits(Fuzz.f64(Arbitrary.new([8, 0, 0, 0, 0, 0, 0, 0, 0])).value) == 0x000FFFFFFFFFFFFF
expect F64.to_bits(Fuzz.f64(Arbitrary.new([9, 0, 0, 0, 0, 0, 0, 0, 0])).value) == 0x0010000000000000
expect Fuzz.f64(Arbitrary.new([10, 0, 0, 0, 0, 0, 0, 0, 0])).value == 1.0
expect Fuzz.f64(Arbitrary.new([11, 0, 0, 0, 0, 0, 0, 0, 0])).value == -1.0
expect Fuzz.f64(Arbitrary.new([13, 0, 0, 0, 0, 0, 0, 0, 0])).value == F64.highest
expect Fuzz.f64(Arbitrary.new([14, 0, 0, 0, 0, 0, 0, 0, 0])).value == F64.lowest
expect Fuzz.f64(Arbitrary.new([15, 0, 0, 0, 0, 0, 0, 0, 0])).value == 9007199254740992.0

# Every entry of the F32 boundary table lands in the class it was chosen for.
expect F32.to_bits(Fuzz.f32(Arbitrary.new([0, 0, 0, 0, 0])).value) == 0
expect F32.to_bits(Fuzz.f32(Arbitrary.new([1, 0, 0, 0, 0])).value) == 0x80000000
expect F32.is_nan(Fuzz.f32(Arbitrary.new([2, 0, 0, 0, 0])).value)
expect F32.is_nan(Fuzz.f32(Arbitrary.new([3, 0, 0, 0, 0])).value)
expect F32.is_nan(Fuzz.f32(Arbitrary.new([4, 0, 0, 0, 0])).value)
expect Fuzz.f32(Arbitrary.new([5, 0, 0, 0, 0])).value == F32.infinity
expect Fuzz.f32(Arbitrary.new([6, 0, 0, 0, 0])).value == F32.infinity.negate()
expect F32.to_bits(Fuzz.f32(Arbitrary.new([7, 0, 0, 0, 0])).value) == 1
expect F32.to_bits(Fuzz.f32(Arbitrary.new([8, 0, 0, 0, 0])).value) == 0x007FFFFF
expect F32.to_bits(Fuzz.f32(Arbitrary.new([9, 0, 0, 0, 0])).value) == 0x00800000
expect Fuzz.f32(Arbitrary.new([10, 0, 0, 0, 0])).value == 1.0
expect Fuzz.f32(Arbitrary.new([11, 0, 0, 0, 0])).value == -1.0
expect Fuzz.f32(Arbitrary.new([13, 0, 0, 0, 0])).value == F32.highest
expect Fuzz.f32(Arbitrary.new([14, 0, 0, 0, 0])).value == F32.lowest
expect Fuzz.f32(Arbitrary.new([15, 0, 0, 0, 0])).value == 16777216.0

# Selectors past the table reinterpret the drawn bits directly.
expect Fuzz.f64(Arbitrary.new([16, 0, 0, 0, 0, 0, 0, 240, 63])).value == 1.0
expect Fuzz.f32(Arbitrary.new([16, 0, 0, 128, 63])).value == 1.0

# Both endpoints of a bounded range are reachable, and a degenerate range
# returns its single value without needing input.
expect Fuzz.f64_in(-5.0, 5.0)(Arbitrary.new([0, 0, 0, 0, 0, 0, 0, 0])).value == -5.0
expect Fuzz.f64_in(-5.0, 5.0)(Arbitrary.new([255, 255, 255, 255, 255, 255, 255, 255])).value == 5.0
expect Fuzz.f64_in(1.5, 1.5)(Arbitrary.new([])).value == 1.5
expect Fuzz.f32_in(-5.0, 5.0)(Arbitrary.new([0, 0, 0])).value == -5.0
expect Fuzz.f32_in(-5.0, 5.0)(Arbitrary.new([255, 255, 255])).value == 5.0
expect Fuzz.f32_in(1.5, 1.5)(Arbitrary.new([])).value == 1.5

# Bounded generation stays inside its bounds and stays finite even when the
# range spans every representable value.
expect Fuzz.f64_in(-5.0, 5.0)(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8])).value >= -5.0
expect Fuzz.f64_in(-5.0, 5.0)(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8])).value <= 5.0
expect F64.is_finite(Fuzz.f64_in(F64.lowest, F64.highest)(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8])).value)
expect F64.is_finite(Fuzz.f64_in(F64.lowest, F64.highest)(Arbitrary.new([255, 255, 255, 255, 255, 255, 255, 255])).value)
expect F32.is_finite(Fuzz.f32_in(F32.lowest, F32.highest)(Arbitrary.new([1, 2, 3])).value)
expect F32.is_finite(Fuzz.f32_in(F32.lowest, F32.highest)(Arbitrary.new([255, 255, 255])).value)

# Bounded generation consumes a constant number of bytes.
expect Fuzz.f64_in(0.0, 1.0)(Arbitrary.new([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])).state.len() == 2
expect Fuzz.f32_in(0.0, 1.0)(Arbitrary.new([1, 2, 3, 4, 5])).state.len() == 2
