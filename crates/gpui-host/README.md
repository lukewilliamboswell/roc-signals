# GPUI host

App-independent Rust static library for `platform-gui`, backed by the existing
Zig `Engine(NativeCtx)`. Cargo builds the host; Roc performs the final app link.
See [contributing](../../www/content/docs/contributing.md#native-gui-platform-spike)
for build and bundle commands. The workspace lockfile pins GPUI 0.2.2.

`examples-gui/counter` is the minimal app; `examples-gui/keyed-rows` exercises
row-local drafts, stable keys, conditional disposal, and a scoped clock.
The executable accepts `--run-spec-json path.scm` to use the shared native spec
runner without a display. `--smoke --smoke-click Increment --smoke-expect 'Count: 1'`
opens Counter briefly, dispatches through the normal adapter, and checks its
retained model after rendering. This is not an OS mouse/keyboard test.

## Boundary and ownership

Zig continues to own all retained Roc values and calls their existing
capabilities. Rust receives only copied UTF-8 strings, primitive fields, child
IDs, and event IDs. It never reads a Roc value or adjusts a Roc reference count.

The `Gpui` bridge in `native_host.zig` records exactly the touched
slots of each successfully committed `NativeRenderPublication`. IDs are
coalesced within one host call using a fixed bounded table. Rust copies the final
committed slots after the call returns, creates new GPUI identities first, and
then applies the engine-selected fields and queries indexed child ranges without another engine
turn interleaving. It does not diff app state or rediscover graph dependencies.
A removal drops the Rust registry's entity; committed parent orders detach it.

There is one mount on the UI thread. The bridge limits render IDs to 65,536,
preflights that limit before native publication, and reserves its entire ID
notification table statically. Input text is limited to 1 MiB. Each editor allows
one deferred edit callback at a time; saturation is an explicit fatal diagnostic.
Callbacks check the node and binding identity before dispatch, so a callback for
a disposed editor cannot affect a later lifetime. Rust entities reference the
runtime weakly. Engine-issued interval tokens own individual native timer tasks;
scope disposal cancels them, and queued stale callbacks are rejected before Roc
runs. Timer delivery uses the shared engine's indexed interval path. `Files`
provides bounded, cancellable chooser/read/write/scan operations through that same
propagation model; workers hold only copied primitive requests and results.

The command boundary is process-local and statically linked. Borrowed node data
expires at the next host operation and is copied before that operation. Rust
checks the native protocol version and exported C node-record size before mount to reject stale builds. Allocation
or unexpected boundary failure is process-fatal; this is not Wasm-style instance
containment. The native host's prepare/commit and teardown checks remain active.

## What transfers, and what does not yet

`Gui` provides typed rows, columns and panels; static and signal-backed native
presentation; headings/text; enabled action buttons; labeled single-line and
multiline editors; and controlled checkboxes. Selection and test identifiers are separate from
presentation. Style records cover logical-pixel sizing, gap/padding, growth,
colors, borders, radius, font size and overflow. The fixed-height `card` and
`gpui-row` convention have been replaced by ordinary styled panels.

The [native presentation protocol](../../docs/native-gui-protocol.md) defines
field IDs, strict versioned encoding, validation and the typed C record. The
browser host rejects these native fields; this is not an HTML/CSS implementation.
Native OS accessibility, general DOM policies, browser services, SVG, and native
menus/windows are not implemented. Semantic labels and keyboard/focus behavior
must not be mistaken for verified screen-reader integration.

The editor is adapted from GPUI's Apache-2.0 `examples/input.rs`; its attribution
and license are included. Composition preedit remains editor-local and committed
text enters Roc. Multiline editing preserves hard line breaks, selection, clipboard operations,
and a retained viewport; soft wrapping is not implemented. Focused GPUI tests
cover Unicode and IME range handling, and the browser's guarded external
`SetValue` policy remains a separate capability.

## Remaining work

Wide scrolling lists use `Gui.virtual_list` with an explicit fixed row height.
The live GUI boundary maintains a prepared indexed projection of child edits;
scalar updates no longer copy parent child lists, and viewport rendering queries
only visible ranks. Ordinary containers still enumerate direct children when
they render, so use the virtual-list API for wide collections. Reactive row
scopes remain mounted until ordinary collection or scope disposal removes them.

This Linux x64/Wayland prototype has no cross-platform distribution guarantee.
Bundled ELF link inputs retain system runtime dependencies through SONAMEs;
building a bundle on a newer glibc system sets a corresponding compatibility
floor. Release distribution needs an intentional sysroot, dependency/license
inventory, and platform-specific packaging. `roc build` produces an executable,
not a desktop installer or a macOS `.app` directory.

## Focused tests

`cargo test --locked -p signals-gpui-host --lib -j2` runs adapter tests using
GPUI's test platform without a display. It needs the xkbcommon-X11 development
link input (or `LIBRARY_PATH` pointing at the prepared GUI platform inputs).
These tests cover actual GPUI row layout, retained identity on reorder, removal,
checked-payload ingress, and disabled/stale dispatch. The focused Roc fixture in
`test/gui/presentation` covers the same shared-engine control workflow.
