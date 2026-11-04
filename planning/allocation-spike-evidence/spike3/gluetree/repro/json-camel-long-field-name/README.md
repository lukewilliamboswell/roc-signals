# `Json.parser_camel()` corrupts long field names on wasm32

## Summary

On `wasm32`, `Json.parser_camel()` reads one byte of the field name it is
looking for out of uninitialised memory. Any record field whose **camelCase
form is longer than 10 bytes** can therefore never be matched, and the parse
fails with `MissingRequiredField` naming a mangled field.

The corrupted byte is always at **index 4** of the name, and its value varies
between runs and between call sites — the signature of a read of memory that
was never written.

Native (`x64musl`) is unaffected: the whole native spec suite passes against
the same data. This only reproduces through the wasm host.

## Reproduce

`app.roc` fetches four one-field JSON documents and parses each into a record
with the matching snake_case field. Serve it with the example host and open it:

```sh
roc build --target=wasm32 --opt=dev --output=dist/probe/app.wasm repro/json-camel-long-field-name/app.roc
```

Observed:

```
{"abcdefgHij":1}    -> ok                          # camel name 10 bytes
{"abcdefghIjk":1}   -> Missing 'abcdffghIjk'       # 11 bytes, index 4 e -> f
{"abcdefghiJkl":1}  -> Missing 'abcdffghiJkl'      # 12 bytes
{"abcdefghijKlm":1} -> Missing 'abcdffghijKlm'     # 13 bytes
```

Expected: all four parse.

The threshold sits exactly where Roc stops storing a `Str` inline and moves it
to the heap, so the likely cause is the camelCase name being read through the
small-string representation after it has become heap-allocated — index 4 on
wasm32 is the first byte of the second word of the string struct.

## Impact

This is what breaks the Conduit example's article feed in the browser. The
RealWorld API's article payload carries `favoritesCount` (14 bytes), so
`favorites_count` never matches and the feed renders
"Response was not valid JSON" on every load, while `/api/tags` — whose only
field is `tags` — works fine.

Field names in that payload sort neatly either side of the threshold, which is
why the bug looked data-dependent at first:

| camel name       | bytes | result |
| ---------------- | ----- | ------ |
| `tags`           | 4     | ok |
| `tagList`        | 7     | ok |
| `createdAt`      | 9     | ok |
| `articlesCount`  | 13    | corrupt |
| `favoritesCount` | 14    | corrupt |
