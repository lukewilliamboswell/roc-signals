import Core

## Internal representation of public signals. App-facing aliases expose only
## Value and its pure combinators. Conversion to engine readers stays in this
## unexposed module namespace, outside the public type's members.
SignalCore := [].{
	Value(ctx, a) :: [Fixed(a), Varies(Core.Signal(ctx, a))].{

		## Transform a signal without changing its reads. A constant is mapped
		## once at construction; a varying input is mapped whenever it is read.
		map : Value(ctx, a), (a -> b) -> Value(ctx, b)
		map = |signal, f| match signal {
			Fixed(value) => Fixed(f(value))
			Varies(value) => Varies(value.map(f))
		}

		## Combine two readings, or map once when both inputs are constant.
		## One constant input preserves the other's keyed selection. Two varying
		## inputs read their union, as does the signal record builder.
		map2 : Value(ctx, a), Value(ctx, b), (a, b -> c) -> Value(ctx, c)
		map2 = |left, right, f| match (left, right) {
			(Fixed(a), Fixed(b)) => Fixed(f(a, b))
			(Fixed(a), Varies(b)) => Varies(b.map(|value| f(a, value)))
			(Varies(a), Fixed(b)) => Varies(a.map(|value| f(value, b)))
			(Varies(a), Varies(b)) => Varies(a.map2(b, f))
		}

		## Use this reading inside a nested state or derived layer, preserving
		## its dependencies. A constant needs no reader in either context.
		lift : Value(ctx, a) -> Value(Core.In(ctx, s), a)
		lift = |signal| match signal {
			Fixed(value) => Fixed(value)
			Varies(value) => Varies(value.lift())
		}

		## Use this reading inside a row, preserving its dependencies. A row key
		## remains varying even though it reads no layer.
		lift_row : Value(ctx, a) -> Value(Core.Row(ctx, item), a)
		lift_row = |signal| match signal {
			Fixed(value) => Fixed(value)
			Varies(value) => Varies(value.lift_row())
		}

		## A text literal is a constant signal. It can be used wherever a text
		## signal is expected, without wrapping the literal in Engine.const.
		from_quote : Str -> Try(Value(ctx, Str), [BadQuotedBytes(Str)])
		from_quote = |quoted| Ok(Fixed(quoted))

		## Join constant text and signal parts into one text reading. Fixed parts
		## are assembled at construction; varying parts share one reader. Parts
		## must provide to_text_signal, so a plain Str value is wrapped in const.
		from_interpolation : List(Str) -> Try((Iter(part) -> Value(ctx, Str)), [InvalidInterpolation(Str)])
			where [part.to_text_signal : part -> Value(ctx, Str)]
		from_interpolation = |segments| Ok(|parts| interpolate_text(segments, parts.map(|part| part.to_text_signal())))

		## Use a signal's user-facing text as an interpolation part. Convert
		## different part value types to text signals before combining them.
		to_text_signal : Value(ctx, a) -> Value(ctx, Str)
			where [a.to_str : a -> Str]
		to_text_signal = |signal| signal.map(|value| value.to_str())
	}

	## Keep constants distinct from a varying reader with an empty read set.
	fixed : a -> Value(ctx, a)
	fixed = |value| Fixed(value)

	## Wrap a platform-produced reader without sampling its environment.
	varying : Core.Signal(ctx, a) -> Value(ctx, a)
	varying = |value| Varies(value)

	## Inspect the representation at platform constructor boundaries only.
	representation : Value(ctx, a) -> [Constant(a), Reading(Core.Signal(ctx, a))]
	representation = |signal| match signal {
		Fixed(value) => Constant(value)
		Varies(value) => Reading(value)
	}

	## Constants acquire their ordinary reader only at an engine boundary.
	to_core : Value(ctx, a) -> Core.Signal(ctx, a)
	to_core = |signal| match signal {
		Fixed(value) => Core.const(value)
		Varies(value) => value
	}
}

interpolate_text : List(Str), Iter(SignalCore.Value(ctx, Str)) -> SignalCore.Value(ctx, Str)
interpolate_text = |segments, parts| {
	var $fixed = [segments.first() ?? crash "contract: Signal.from_interpolation needs an initial text segment"]
	var $varying = []
	var $index = 1.U64
	for part in parts {
		next = segments.get($index) ?? crash "contract: Signal.from_interpolation has more parts than text segments"
		match part {
			Fixed(value) => {
				$fixed = $fixed.append(value).append(next)
			}
			Varies(value) => {
				$varying = $varying.append({ prefix: Str.join_with($fixed, ""), value })
				$fixed = [next]
			}
		}
		$index = $index + 1
	}
	if $index != segments.len() {
		crash "contract: Signal.from_interpolation has fewer parts than text segments"
	}
	suffix = Str.join_with($fixed, "")
	if ($varying.is_empty()) Fixed(suffix) else Varies(Core.join_text($varying, suffix))
}
