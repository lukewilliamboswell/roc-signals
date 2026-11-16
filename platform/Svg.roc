import Engine
import MarkupLiteral

## Checked SVG fragments lowered to the ordinary engine element vocabulary.
## A standalone svg root may open an SVG boundary; a fragment root such as
## path or g belongs under an SVG parent, checked at its construction site.
Svg := [].{

	## One SVG element root with homogeneous text signals in text or whole
	## quoted attribute values. Namespace, spelling and static values are checked.
	## Explicit format-hook calls parse their arguments; ordinary literal binding
	## and later updates use the already compiled plan.
	Markup(ctx) :: { plan : MarkupLiteral.Plan, parts : List(Engine.Signal(ctx, Str)) }.{

		## Check a fixed SVG fragment while compiling, preserving its exact names,
		## expanded namespaces and comment data inside the single element root.
		from_quote : Str -> Try(Markup(ctx), [BadQuotedBytes(Str)])
		from_quote = |source| MarkupLiteral.compile([source], SvgFragment)
			.map_ok(|plan| Markup.({ plan, parts: [] }))
			.map_err(|BadLiteral(note)| BadQuotedBytes(note))

		## Parse static segments once. Each bound part keeps its declared reads
		## and constant mark; its future text is never treated as source syntax.
		from_interpolation : List(Str) -> Try((Iter(part) -> Markup(ctx)), [InvalidInterpolation(Str)])
			where [part.to_text_signal : part -> Engine.Signal(ctx, Str)]
		from_interpolation = |segments| {
			plan = MarkupLiteral.compile(segments, SvgFragment).map_err(|BadLiteral(note)| InvalidInterpolation(note))?
			Ok(|parts| Markup.({ plan, parts: MarkupLiteral.bind(plan, parts.map(|part| part.to_text_signal())) }))
		}

		## Build ordinary nodes and holes, retaining explicit namespaces. The
		## engine checks fragment placement using its finite enclosing context.
		to_elem : Markup(ctx) -> Engine.Elem(ctx)
		to_elem = |Markup.(bound)| MarkupLiteral.render(bound.plan, bound.parts)
	}
}
