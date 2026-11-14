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

A literal has exactly one element root. The parser checks fixed syntax,
element and attribute names, fixed attribute values and nesting while the
literal compiles. A hole supplies text, either in text content or as the
whole quoted value of an attribute. Its future values are text too; they
are not reparsed as markup or checked against the fixed attribute grammar.
Use typed constructors when a value needs that validation.

Event-handler attributes and holes in Boolean attributes are refused. Use
ordinary handlers and `Html.boolean` or typed controls. A literal also
refuses an attribute claimed by an engine property on that element, such
as `input.value`, `input.checked` or `option.value`, even when its value is
fixed. Use `Engine.prop`, `Engine.prop_s` or a typed control on a constructor
to choose controlled behavior explicitly.

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
