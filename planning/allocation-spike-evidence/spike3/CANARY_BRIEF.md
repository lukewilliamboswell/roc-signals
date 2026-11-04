# Composition canary brief for `Ui.each_template`

For an author who did not implement the slice. Write the canary, then record what
was awkward. Stopping because something cannot be expressed is a result.

## Task

Write one packaged row component with:

1. independent inputs (a named record of separate signals, per `design.md`
   *Component boundaries*, plus at least one static value),
2. an action callback supplied by the caller,
3. a conditional child.

Use it inside a keyed list through `Ui.each_template`. Keep the component in its
own Roc module with a public signature, as a package would. If the template
vocabulary cannot express a requirement, try the nearest thing, keep the attempt,
and record exactly where it stopped and what you would have needed. Do not edit
the platform or engine, and do not reach for host ids, descriptor internals, or
`Elem`/`Node` constructors that the guide does not teach.

## Where

- Worktree: `/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a9954894a6aa838c9`
  (branch `spike/row-anatomy`, based on `ea1da63d`, uncommitted). Read only: copy
  a fixture elsewhere and do not change this tree.
- Compiler: `/home/lbw/roc_nightly-linux_x86_64-2026-11-01-48d3369/roc`
- Pinned Zig, Node, wasm-opt: `.blueprint/env/default/bin/` in that worktree.
- Working example: `examples-web/_fixtures/row-template/main.roc` and its specs.
- Public docs to rely on: `platform-shared/Ui.roc` (doc comments), `Html.roc`,
  `www/content/docs/dynamic-structure.md`, `www/content/docs/app-architecture.md`.
- Do not read `src/signals/` before writing the attempt: the point is whether the
  public surface is enough.

To build, point a copy's platform header at the worktree's
`platform-web/main.roc`, then:

    roc build --target=x64musl --opt=speed --no-cache --output=<out> <main.roc>
    <out> --host-run-spec-json <spec.scm>

The worktree's `platform-web/targets/` holds a ReleaseFast host; do not rebuild it.

## Documented surface (provisional names)

```roc
Ui.each_template : Signal(Rows(item)), (Ui.TemplateRow -> Elem) -> Elem

Ui.TemplateRow.key_text : Ui.TemplateRow -> Elem
Ui.TemplateRow.key_text_with : Ui.TemplateRow, { prefix : Str, suffix : Str } -> Elem
Ui.TemplateRow.keyed_attr : Ui.TemplateRow, Html.Attr -> Html.Attr
Ui.TemplateRow.keyed_attr_with : Ui.TemplateRow, Html.Attr, Str -> Html.Attr
```

- The builder runs once for the site, not once per row. It receives a symbolic
  row with no key and no item value.
- `row.key_text()` is a text node holding the row's exact key.
- `row.keyed_attr(Html.test_id("row-"))` turns a static text attribute into
  literal text followed by the key. Any `Html` static text attribute works.
  `_with` adds a literal suffix.
- Everything else in the template must be static: `Elem.Element`, `Html.text`,
  static attributes. Signals, events, `Ui.state`, `Ui.component`, cleanup,
  `Ui.when`, `Ui.switch` and nested `Ui.each` are contract errors raised at the
  row's collection, with a panic naming the rule. A non-text attribute passed to
  `keyed_attr` crashes in Roc.
- Rows keep ordinary keyed lifetime: each owns a scope, a reorder moves it, and
  removing the key disposes it. Rows, row keys and `Rows` edits behave as in
  `Ui.each`.

## Report back

- The attempt, verbatim, whether or not it compiled.
- What ran, what was rejected, and the exact message.
- What was awkward: concepts you had to learn, anything you worked around, and
  anything needing a host id, a hidden convention, or knowledge of `Elem` shape.
- Whether you think a fifth concept, such as a dynamic hole, would be needed, and
  why. That is an opinion, labelled as one.
