# `Ui.each` code-generation crashes

Roc `nightly-2026-09-09-7dadc35` crashes while generating code for several
otherwise-valid `Ui.each` applications. Roc `check` and `test` succeed. The
preceding `nightly-2026-09-04-c125b82` generates native artifacts from all
three cases.

The cases form a reduction ladder:

- `main.roc` is the original reduction: a recursive nominal tree whose row
  builder calls back into the group renderer.
- `simple-each.roc` removes recursive types, recursive calls, branches, and
  nested component scopes. It retains state, a derived `Rows` signal, and a
  row body containing a derived text signal.
- `compound-disposal.roc` removes state and derived row content as well. It
  retains only a constant two-item `Rows` signal and a static row body. It is
  the minimal shape extracted from the GUI compound-disposal failure.

This means the keyed-rows and compound-disposal failures belong to the same
broader `Ui.each`/monomorphization family as recursive rendering, but recursion
is not required to trigger it. The two small cases produce the same fault
address as their full applications on each host platform.

On Apple Silicon macOS:

```sh
GOOD=/path/to/roc_nightly-macos_apple_silicon-2026-09-04-c125b82/roc
BAD=/path/to/roc_nightly-macos_apple_silicon-2026-09-09-7dadc35/roc

"$BAD" check repro/recursive-each-codegen/simple-each.roc
"$BAD" build -j1 --target=arm64mac --opt=dev --no-cache \
  --output=/tmp/simple-each-bad \
  repro/recursive-each-codegen/simple-each.roc
"$BAD" build -j1 --target=arm64mac --opt=dev --no-cache \
  --output=/tmp/compound-disposal-bad \
  repro/recursive-each-codegen/compound-disposal.roc

"$GOOD" build -j1 --target=arm64mac --opt=dev --no-cache \
  --output=/tmp/simple-each-good \
  repro/recursive-each-codegen/simple-each.roc
"$GOOD" build -j1 --target=arm64mac --opt=dev --no-cache \
  --output=/tmp/compound-disposal-good \
  repro/recursive-each-codegen/compound-disposal.roc
```

Expected: each build produces the requested executable. Actual with the bad
nightly: both builds terminate with `SIGSEGV`, fault address `0x3f8`, before an
artifact is produced. On Linux x64, both full applications terminate at the
same stage with fault address `0x378`. The good-nightly commands generate both
executables; their only diagnostics are expected version-mismatch warnings
because the checked-in platform headers record the bad nightly.

The current debug compiler no longer faults at an unlabelled address. Both
small cases stop in `postcheck/monotype/lower.zig`, in
`mergeCheckedEvidenceContract`, while applying checked template interface
relations for the platform-required procedure:

```text
postcheck invariant violated: checked target contract differed from
substitution-derived evidence kind
```

The producer-authoritative `retain_constraint_relation` rule was incorrectly
nested under the derived target arm, so structural derived evidence reached
this invariant before the rule could apply. This confirms postcheck monotype
lowering and its checked-evidence merge as the compiler area. Replacing the
recursive row-builder call with a static element controls only the original
recursive case; the smaller controls show that recursion itself is not the root
requirement.
