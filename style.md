# Roc Style Notes

Small cleanup rules for Roc code.

## Types

- Add type annotations for top-level functions, including `main!` and small helpers. These are part of the reader-facing API of an example.
- Keep type annotations when they document public API shape, non-obvious records/lists, custom tags, or numeric intent.
- Omit type annotations for simple top-level constants when the value is an obvious literal, especially plain strings.
- Use `_` in an annotation only when spelling out the inferred type would expose distracting internal machinery or make an example harder to read.
- For example `main!` annotations, prefer a named error union when the error cases are part of the example. Use `_` when the row is just low-level plumbing from effects like stdin/stdout/file IO.
- Prefer named records over tuples when the fields have meaning. For example, headers should be `{ name : Str, value : Str }`, not `(Str, Str)`.
- Destructure records in function arguments when the fields are few and the meaning stays obvious.
- Model a closed set of values as a tag union, never as a `Str`, an integer code, or a combination of `Bool` fields. If a comment is needed to say what `2` means, or two `Bool`s exist that cannot both be true, it wants to be a tag.
- Parse at the edge: one `from_str` where external text arrives, one `to_str` where it leaves, tags everywhere in between.
- Derive each rendering of a value from the tag independently. Do not recover meaning by inspecting text that was just rendered, such as choosing a CSS class from the wording of a message.
- Group parameters of the same type into a record so call sites name them. Several adjacent `Str` arguments, or a bare `Bool` argument, are transposition hazards.

```roc
Header := { name : Str, value : Str }.{
	to_str : Header -> Str
	to_str = |{ name, value }| "${name}: ${value}"
}
```

```roc
Status := [Draft, Queued, Synced, Failed].{
	is_eq : _

	## The wire value, and the only place it is spelled.
	to_str : Status -> Str
	to_str = |status|
		match status {
			Draft => "draft"
			Queued => "queued"
			Synced => "synced"
			Failed => "failed"
		}

	## Tone is a second projection of the tag, not a reading of `to_str`.
	class : Status -> Str
	class = |status|
		match status {
			Failed => "badge badge-danger"
			Synced => "badge badge-ok"
			_ => "badge"
		}
}
```

## Function Shape

- Prefer receiver/static-dispatch style when it reads naturally, such as `items.map(...)`, `items.keep_if(...)`, `items.len()`, and `items.fold(...)`.
- When receiver-dispatching polymorphic signal helpers, add a local `Signal.Signal(...)` annotation if the same source signal maps to different output types. If that annotation would be noisier than the call, keep the explicit `Signal.map(...)` form.
- If a method-position call is rejected with a type mismatch whose two printed types look identical, that is a known compiler bug, not a modelling problem. Use the call form and leave a comment. See `UPSTREAM_COMPILER_BUGS.md`.
- Avoid extra braces around a function body when the body is just one `match`, `if`, record update, or expression.
- Keep short pure helpers compact, but expand nested `if`/`match` branches when the inline version hurts scanning.
- Prefer builder chains over numbered intermediate values.
- Prefer `with_headers([...])` when setting multiple headers at once. Use repeated `add_header(...)` when the step-by-step construction is the point of the example.

```roc
request =
	Request.from_method(POST)
		.with_uri("/widgets")
		.with_headers(
			[
				{ name: "Accept", value: "application/json" },
				{ name: "X-Trace-Id", value: "demo-123" },
			],
		)
```

## Static Dispatch Hooks

- Treat well-known static-dispatch methods as opt-in hooks for language syntax and builtin APIs. They are not dynamic interfaces; each use still resolves to a concrete implementation.
- Prefer well-known methods when they reduce consumer boilerplate without making behavior surprising.
- Use `to_inspect : T -> Str` for debug, logging, and test output through `Str.inspect(value)`.
- Use `to_str : T -> Str` only when the type has one clear user-facing string representation.
- Prefer explicitly named renderers when several string meanings exist, such as `to_debug_str`, `to_markdown`, `to_plain_text`, or `to_html`.
- Prefer `is_eq : _` to derive equality for a nominal type. Write `is_eq : T, T -> Bool` with a body only when equality should differ from the structural comparison.
- Never implement `is_eq` by encoding both sides to a `Str` or an integer code and comparing those. It allocates on the equality path and conflates values that happen to encode alike.
- If a type defines custom `is_eq` and will be used in hash-based APIs, also define `to_hash : T, Hasher -> Hasher` consistently. Equal values must hash the same way.
- Use ordering hooks (`is_lt`, `is_lte`, `is_gt`, `is_gte`) only when the type has one obvious ordering.
- Use arithmetic hooks (`plus`, `minus`, `times`, `div_by`, `div_trunc_by`, `rem_by`) only when the operation is obvious and unsurprising for the type.
- Use unary hooks (`negate`, `not`) only when unary `-` or `!` is the clearest spelling for the type's operation.
- Use `from_numeral : Num.Numeral -> Try(T, [InvalidNumeral(Str)])` only when plain numeric literals should construct the type.
- Use `from_quote : Str -> Try(T, [BadQuotedBytes(Str)])` only when quoted string literals should construct the type.
- Use `from_interpolation : Str, Iter((item, Str)) -> T` only when interpolation should construct the type.
- Prefer explicit constructors over literal hooks when the conversion is surprising, lossy, contextual, or one of several possible interpretations.
- Use `iter : T -> Iter(item)` for collection-like wrappers so `for` loops and lazy pipelines work naturally. Collection authors usually implement `iter`; iterator values provide `next`.
- Use `parser_for` and `encoder_for` for structured parse/encode behavior. Do not overload `to_str` as serialization.
- When delegating well-known methods to shared helpers, prefer an explicit wrapper body. This keeps the public method surface readable and avoids relying on bare alias compiler behavior.

```roc
Markdown := [...].{
	to_inspect : Markdown -> Str
	to_inspect = |node| inspect_markdown(node)

	is_eq : Markdown, Markdown -> Bool
	is_eq = |left, right| markdown_is_eq(left, right)

	to_debug_str : Markdown -> Str
	to_debug_str = |node| inspect_markdown(node)
}
```

```roc
Port := U16.{
	from_numeral : Num.Numeral -> Try(Port, [InvalidNumeral(Str)])
	from_numeral = |numeral| parse_port_numeral(numeral)
}

port : Port
port = 8080
```

## Records And Builders

- Prefer named record-builder composition for multi-signal values, such as `{ first: first_signal, last: last_signal }.Signal`, instead of adding `Signal.map3+`.
- Keep record fields explicit when the names communicate domain meaning.
- Let record types document parse targets and response bodies in examples.

## Error Handling

- Use postfix `?` to propagate a `Try` in a function or `expect`.
- Use infix `?` to map low-level errors into domain errors before propagating.
- Use `??` only at a real boundary where a fallback value is appropriate. Avoid using it in parsing paths where it would hide invalid input.
- Prefer a fallible internal function plus a small boundary wrapper for workflows that need a fallback response.
- Do not ignore effect results with `_ = effect!()` or `match effect!() { _ => {} }`. Use postfix `?`, infix `?`, an explicit `match`, or `??` at a boundary.
- Avoid manual `Ok(value) = result` unwrapping in example code. Prefer `?` or an explicit `match` when handling the error is meaningful.

```roc
main! : List(Str) => Try({}, _)
main! = |_args| {
	data = Stdin.bytes!()?
	Stdout.write_bytes!(data)?
	Ok({})
}

parse_widget_request : Request -> Try(CreateWidget, WidgetRequestError)
parse_widget_request = |request| {
	body = Str.from_utf8(request.body()) ? |_| BadBodyUtf8
	widget = Json.parse(body) ? BadBodyJson
	Ok(widget)
}

route : Request -> Response
route = |request| route_result(request) ?? internal_error_response()
```

## CLI Example Error Boundaries

Small CLI examples should usually let structured errors bubble to `main!`.

The platform boundary can render unexpected failures with `Str.inspect`, so examples do not need to convert every failure into `Exit(1)` or a `Str`.

- Prefer tags, with payloads when useful, over stringly errors. This keeps failures inspectable, composable, and easier to refine later.
- Use infix `?` to name the operation that failed when the low-level error alone would lose useful context.
- Use a render helper only at a true boundary where custom human-facing text is part of the example.
- Keep that rendering in one place instead of scattering one-off print-and-exit branches through the workflow.
- For cleanup-sensitive workflows, capture the fallible result, perform cleanup, then rethrow with `?`.

```roc
main! : List(Str) => Try({}, _)
main! = |_args| run!()

run! : () => Try({}, _)
run! = || {
	response = Http.send!(request) ? |err| SendFailed(err)
	decoded = Http.decode_json_response(response) ? |err| DecodeResponseFailed(err)
	Stdout.line!("received: ${Str.inspect(decoded)}")?
	Ok({})
}
```

```roc
main! : List(Str) => Try({}, _)
main! = |args| {
	Tty.enable_raw_mode!()
	result = game_loop!(args)
	Tty.disable_raw_mode!()
	result?
	Ok({})
}
```

## Strings And Bytes

- Use `Str.inspect` for debug output of byte lists, records, tags, and booleans instead of writing one-off `bytes_to_str` or `headers_to_str` helpers.
- For nominal types, implement `to_inspect` when the default `Str.inspect` representation is not the useful debug representation.
- Use `Str.from_utf8(...) ? ...` when invalid UTF-8 should be treated as an error.
- Use `Str.from_utf8(...) ?? fallback` only for display or boundary fallbacks.
- Use `Str.from_utf8_lossy` sparingly, when lossy display is explicitly the desired behavior.

## Tests

- Prefer top-level `expect` tests for small packages and examples.
- Put a short doc comment immediately before every top-level `expect`. Roc includes that text in failure output.
- Use postfix `?` inside `expect` blocks for setup that should fail the test immediately.
- Compare decoded values directly instead of comparing `Try` values on the happy path.
- Keep simple tests as direct comparisons.
- Avoid long chained `and` expressions when checking several related facts.
- For multi-signal behavior, build a labeled `actual` report string and compare it to a labeled multiline `expected` string.
- Use `Str.inspect(...)` in report strings for booleans, tags, records, and nested values.
- Multiline string lines start with `\\`. A `#` inside one is literal text, not a comment.
- Include negative parse tests for important parser behavior.
- CI should run `roc test` for every example so top-level expects in examples are exercised.

```roc
## Inline debug helpers expose inspect and equality behavior.
expect {
	inline : Markdown.Inline
	inline = Strong([Text("Roc")])

	actual =
		\\inline inspect: ${Str.inspect(inline)}
		\\inline debug: ${Markdown.inline_to_debug_str(inline)}
		\\inline eq same: ${Str.inspect(inline == Strong([Text("Roc")]))}
		\\inline eq different: ${Str.inspect(inline == Emphasis([Text("Roc")]))}

	expected =
		\\inline inspect: Strong([Text("Roc")])
		\\inline debug: Strong([Text("Roc")])
		\\inline eq same: True
		\\inline eq different: False

	actual == expected
}
```
