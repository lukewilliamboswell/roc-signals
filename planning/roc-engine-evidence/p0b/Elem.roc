import Node
import Val

## UI description in context `ctx` (`Ui.Root` outside any list,
## `Ui.Site(outer, item)` inside a row template).
##
## Static markup is polymorphic in `ctx`, so a helper that builds static or
## site-level structure can be used at any depth. Anything that reads a row
## value has the row's context in its type, so it cannot be placed outside that
## row: the static rule the old `each_template` enforced at runtime is a type.
##
## Typed sites erase exactly once: `Each`, `Switch` and `LocalState` hide their
## item/case/state type behind a small record of closures over the site's own
## typed storage (`ErasedSite`), built once per construction site, never per
## row. Sketch representation only.
Elem(ctx) :: [
	Element({ tag : Str, attrs : List(Node.Attr(ctx)), children : List(Elem(ctx)) }),
	Text(Str),
	TextVal(Val(ctx, Str)),
	Component(Box(Elem(ctx))),
	When({ condition : Val(ctx, Bool), when_true : Box((() -> Elem(ctx))), when_false : Box((() -> Elem(ctx))) }),
	Erased(ErasedSite(ctx)),
].{

	## One construction site's typed storage behind closures. The engine keeps a
	## site's rows as columns of the real item type inside these closures; the
	## engine core only sees these operations.
	ErasedSite(ctx) :: {
		kind : [Each, Switch, LocalState],
		## Mount every instance of the site for one enclosing context; returns
		## command bytes. Stub signature.
		mount : Box((ctx -> List(U8))),
		## Debug rendering of the site's template, built once per site.
		describe : Box((() -> Str)),
	}

	## A string literal in an element position is literal text.
	from_quote : Str -> Try(Elem(ctx), [BadQuotedBytes(Str)])
	from_quote = |value| Ok(Text(value))

	platform_element : Str, List(Node.Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	platform_element = |tag, attrs, children| Element({ tag, attrs, children })

	platform_text : Str -> Elem(ctx)
	platform_text = |value| Text(value)

	platform_text_val : Val(ctx, Str) -> Elem(ctx)
	platform_text_val = |value| TextVal(value)

	platform_component : Elem(ctx) -> Elem(ctx)
	platform_component = |child| Component(Box.box(child))

	platform_when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	platform_when = |condition, t, f| When({ condition, when_true: Box.box(t), when_false: Box.box(f) })

	platform_erased : [Each, Switch, LocalState], (ctx -> List(U8)), (() -> Str) -> Elem(ctx)
	platform_erased = |kind, mount, describe| Erased({ kind, mount: Box.box(mount), describe: Box.box(describe) })

	## Platform-private debug rendering, used by the sketch's `expect` tests to
	## show that each template is built once and holds holes, not rows.
	platform_describe : Elem(ctx) -> Str
	platform_describe = |elem|
		match elem {
			Element({ tag, attrs, children }) => {
				inner = Str.join_with(children.map(platform_describe), "")
				"<${tag}:${attrs.len().to_str()}>${inner}</${tag}>"
			}
			Text(value) => value
			TextVal(_) => "{val}"
			Component(child) => platform_describe(Box.unbox(child))
			When({ when_true, when_false, condition: _ }) => "{when ${platform_describe(Box.unbox(when_true)())} | ${platform_describe(Box.unbox(when_false)())}}"
			Erased(site) => Box.unbox(site.describe)()
		}
}
