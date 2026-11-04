# Draft upstream issue (not filed): `roc test --opt=dev` spins on a top-level Rows value

Compiler: nightly-2026-11-01-48d3369.

`examples-web/_fixtures/row-template/main.roc` on `spike/row-anatomy` with a
top-level constant:

    initial : Model
    initial = { rows: Rows.from_list([...], |item| item.id) ?? crash "...", mounted: True }

`roc check` passes in under a second and `roc build` succeeds, but `roc test
--opt=dev` ran at 100% CPU for over 7 minutes before being stopped. Changing the
constant to a function, `initial : {} -> Model`, makes `roc test` finish
immediately (34 tests, 32 ms).

Not minimized further. The likely shape is compile-time evaluation of a top-level
value that captures a closure and builds a persistent structure.
