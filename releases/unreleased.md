# Unreleased

## Breaking changes and migration: 0.1.1 → unreleased

This upgrade changes keyed collections and branch construction. Upgrade the
Roc compiler, platform archive, and browser runtime together. Use the compiler
pin recorded with your platform release; a recent but different nightly is not
a compatibility guarantee.

### Keyed lists

Replace `Ui.each_str(items, key_of, row)` with `Ui.each(rows, row)`. The collection
now owns and validates its key function:

```roc
import pf.Rows

rows = Rows.from_list(items, |item| item.id)?
```

Handle the `Try` where the collection is constructed. Duplicate keys, missing
keys, and invalid edit ranges are structured errors, not aliases or silent
fallbacks. For a static list, pass `Signal.const(rows)` to `Ui.each`; for a
changing collection, retain `Rows` in state and edit it with `Rows.apply`.

The row callback now receives one live `Ui.Row(item)`:

```roc
Ui.each(
    rows_signal,
    |row| Html.paragraph_s(row.map(|item| item.title)),
)
```

Use `row.key()` for identity and `row.signal()` or `row.map(...)` for changing
content. Do not encode labels or serialized items in the key. A same-key item
update preserves its row scope; removal ends that scope. Reintroducing a key
after a committed removal creates fresh local state.

Use `Rows.replace_all` when a complete replacement is the input you have.
Direct edits with `Rows.apply` carry the change description and avoid requiring
the engine to inspect every item in a fresh snapshot.

### Lazy branches

`Ui.when` retains its two builders and invokes only the selected one. Code in an
inactive builder no longer runs eagerly. Use `Ui.switch(case_signal, build)` for
more than two cases. A case change disposes the old branch, including its local
state and tasks; own persistent drafts outside the branch.

### Task constructors

Use `Http` helpers for HTTP tasks and `Signal.fake_task` for deterministic task
fixtures. Earlier reference pages listed `task_source` and
`task_source_with_eq`; those are internal platform plumbing, not supported
application extension points.

### Browser deployment

Rebuild the app's Wasm and replace all runtime modules from the same compatible
platform revision. This release adds `signals-browser.zip`; extract its files
alongside the app, preserving relative paths. Deploy the Wasm and runtime
together so the browser's protocol check does not encounter mixed versions.

For local platform development, build the platform archive with
`scripts/bundle.sh` and its browser companion with
`python3 scripts/bundle_browser.py`. The site build compiles examples against
its freshly built archive and points downloadable sources at that same archive
under the site's `platform/` directory unless a platform URL is explicitly
overridden.

See [Getting Started](https://lukewilliamboswell.github.io/roc-signals/docs/getting-started/#mount-it-in-your-own-page)
for the mount code and [Contributing](https://lukewilliamboswell.github.io/roc-signals/docs/contributing/#bundles)
for bundle testing.
