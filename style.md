# Roc Style Notes

Small cleanup rules for Roc code in this repo:

- Omit type annotations for simple top-level constants when the value is an obvious string literal.
- Keep type annotations when they document public API shape, non-obvious records/lists, custom tags, or numeric intent.
- Prefer receiver/static-dispatch style when it reads naturally, such as `items.map(...)`, `items.keep_if(...)`, `items.len()`, and `items.fold(...)`.
- Avoid extra braces around a function body when the body is just one `match`, `if`, record update, or expression.
- Keep short pure helpers compact, but expand nested `if`/`match` branches when the inline version hurts scanning.
- Prefer named record-builder composition for multi-signal values, such as `{ first: first_signal, last: last_signal }.Signal`, instead of adding `Signal.map3+`.
- Remove incidental trailing whitespace while touching a file.
