+++
title = "Markup Literals"
description = "Checked HTML and SVG with ordinary signal holes."
weight = 8
template = "page.html"
+++

# Markup literals

Use `Html.Markup(ctx)` or `Svg.Markup(ctx)` for mostly fixed structure, such as
an article or a drawing. Call `to_elem()` to place it in a view. Constructors
attach handlers, compose components and choose dynamic structure around it.

{{ sample(file="markup.roc", region="literals") }}

The count in both literals is one ordinary text signal. Each hole keeps its
declared reads and equality pruning. Updating the count changes its text;
the engine does not parse the literal again. When a literal mixes signals
and plain values, lift the plain values with `Engine.const` first.

## What the compiler checks

A literal has exactly one element root. A table part can be that root: a
`tr` literal is a row a constructor places in a `tbody`, and a `td` literal a
cell of a `tr`. Where a root may stand is checked when the view is
constructed, so a `tr` literal placed in a `div` is a contract error naming
its site. The parser checks fixed syntax,
element and attribute names, fixed attribute values and nesting while the
literal compiles. A hole supplies text, either in text content or as the
whole quoted value of an attribute. Its future values are text too; they
are not reparsed as markup or checked against the fixed attribute grammar.
Use typed constructors when a value needs that validation.

Event-handler attributes and holes in Boolean attributes are refused in a
literal. Use ordinary handlers and `Html.boolean` or typed controls. The
constructors do not refuse them: `Engine.attr("onclick", text)` sets the
attribute as written. A literal also refuses an attribute claimed by an
engine property on that element, such as `input.value`, `input.checked` or
`option.value`, even when its value is fixed. Use `Engine.prop`,
`Engine.prop_s` or a typed control on a constructor to choose controlled
behavior explicitly.

Comments inside the root retain their data. Comments beside the root,
document declarations and processing instructions are refused. Indentation
made only of ASCII whitespace is omitted when it contains a carriage return
or newline. Inline spaces, nonbreaking spaces and mixed text remain. This
indentation rule also applies to whitespace-only `pre` content.

`Svg.Markup` accepts a standalone `svg` under HTML, or a fragment such as
`g` or `path` under an SVG parent. Expanded names retain namespace URI,
prefix, local name and case. A parsed XHTML `template` places its children
in the inert content fragment, for both HTML and XML literal syntax.
Ordinary `Engine.element` constructors keep ordinary children, including
when their tag is `template`.

Explicit calls to a format hook parse the arguments supplied to that call.
Constructing an element from the compiled literal plan and updating its
holes do not parse source.

## Attribute presence and typed values

A raw attribute value is literal text: both empty text and `"false"` mean
that the attribute is present. Only `Absent` removes it. `Html.boolean`
encodes a Boolean signal as absence or present-empty. `Html.flag` encodes
textual true/false tokens, such as ARIA values.

`Html.Hidden` distinguishes `Shown`, `Hidden` and `UntilFound`.
`Html.InputType` checks the parser's closed set of input keywords.
The raw `Engine.attr` constructor remains available for names and values
whose grammar the application chooses to validate itself.

## Compiler limitations

`roc check` does not check a literal in a view that nothing calls, or that
is bound and never used, until something calls it
([roc-lang/roc#13003](https://github.com/roc-lang/roc/issues/13003)). A
component library's view is checked once an app or a constant calls it.

## Imported HTML

`Html.unsafe_html(tag, attrs, html_signal)` asks the browser to parse a string
through `innerHTML`. It keeps a stable wrapper with ordinary attributes and
handlers. Equal strings emit nothing; a changed string replaces every imported
descendant. The wrapper has no engine-managed children.

{{ sample(file="unsafe-html.roc", region="example") }}

Contents receive no escaping, validation or sanitization. Your application owns
their safety. Browser insertion behavior applies: nested scripts are ordinarily
inert, while inline handlers, custom elements and embedded documents can execute
code. Raw destination attributes remain raw. Replacement and removal provide no
inferred Roc cleanup or cancellation for JavaScript started by those contents.

Imported descendants have no engine identity, references, handlers, state or
requests. Attributes resembling engine metadata remain HTML data. Both spec
runners exclude imported descendants from locators. Wrapper attributes remain
observable; imported text, names derived from that text and interaction requiring
those descendants fail explicitly. Test those browser behaviors directly in a
browser contract. Prerendered pictures refuse any unsafe-HTML wrapper, including
one whose initial string is empty; ordinary builds and mounting work normally.

String comparison costs the size of the strings. Browser parsing and replacement
cost the imported content. Engine updates never traverse imported descendants.

## Checked link destinations

`Html.link` requires `Web.Link`. A literal is checked during compilation;
`Web.Link.from_str` returns `Try` for computed text. Handle
`UnsupportedScheme(scheme)` explicitly. `Html.href` sets a checked destination
on a custom layout; `Html.href_s` takes `Absent` or `Present(Web.Link)`.
Choosing `Absent` removes an earlier destination; repeated absence prunes.
Extra attributes passed to `Html.link` cannot override its destination.

The policy accepts relative references and explicit HTTP, HTTPS, mailto and tel
schemes. It detects schemes after the browser's C0/space trimming, TAB/LF/CR
removal and ASCII case folding, and retains accepted authored text exactly.
This checks scheme policy, not hostname validity, reachability or destination
trustworthiness. Raw `Engine.attr`, computed markup APIs and unsafe HTML keep
their existing meanings. Image-source and exported-HTML policies belong to
the application.

`Engine.on_click` and button helpers receive `Engine.Click`: `ctrl`, `alt`,
`shift`, `meta`, and `link`, either `NoLink` or
`Link({ href, target, download })`. Link text is authored, never absolute-URL
resolved; `download` is attribute presence. Nested targets find the nearest HTML
or SVG anchor within the mount, with SVG href preceding qualified XLink href.
`Engine.on_click_with(policy, handler)` declares synchronous prevention and
propagation. The handler decides app navigation from those facts. Generic
`Engine.on("click", handler)` keeps its text payload.
