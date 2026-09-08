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

The worktree-only `Gpui` bridge in `native_host.zig` records exactly the touched
slots of each successfully committed `NativeRenderPublication`. IDs are
coalesced within one host call using a fixed bounded table. Rust copies the final
committed slots after the call returns, creates new GPUI identities first, and
then applies the engine-selected child lists and fields without another engine
turn interleaving. It does not diff app state or rediscover graph dependencies.
A removal drops the Rust registry's entity; updated parent lists detach it.

There is one mount on the UI thread. The bridge limits render IDs to 65,536,
preflights that limit before native publication, and reserves its entire ID
notification table statically. Input text is limited to 1 MiB. Each editor allows
one deferred edit callback at a time; saturation is an explicit fatal diagnostic.
Callbacks check the node and binding identity before dispatch, so a callback for
a disposed editor cannot affect a later lifetime. Rust entities reference the
runtime weakly; the scope clock uses one mount-owned GPUI task, and its ticks
enter the engine's ordinary scoped interval path. This spike supports only the
sample's 1-second clock, not a general timer/task transport.

The command boundary is process-local and statically linked. Borrowed node data
expires at the next host operation and is copied before that operation. Rust
checks the exported C node-record size before mount to reject stale builds. Allocation
or unexpected boundary failure is process-fatal; this is not Wasm-style instance
containment. The native host's prepare/commit and teardown checks remain active.

## What transfers, and what does not yet

The experiment deliberately uses the existing Roc UI API with a small render
subset: root/container, headings, paragraph/text, button, and text input.
`gpui-row` is the sample's explicit style class: a full-width, 170px-high cached
row with padding and a border. Test IDs are locators, not identities or a layout
protocol. This is not an HTML/CSS implementation. Accessibility, general DOM
event policies, browser services, SVG, arbitrary styling, native menus/windows,
are not implemented. The small `Gui` API deliberately exposes only the supported primitives.

The editor is adapted from GPUI's Apache-2.0 `examples/input.rs`; its attribution
and license are included. Composition preedit remains editor-local and committed
text enters Roc. The sample proves echoing edits and preserving focus on a move;
it does not establish production IME, selection normalization, accessibility, or
the browser's guarded external `SetValue` policy.

## Remaining work

The full O(changed) rendering contract is not yet satisfied: parent child-list
copying on reorder and GPUI parent child enumeration are linear. Earlier keyed
row measurements found 13 settled edit renders but 1,035 child handles visited
with 1,024 rows. Those measurements came from the original spike harness, not
the generic Counter smoke check. First focus can invalidate the whole tree.

This Linux x64/Wayland prototype has no cross-platform distribution guarantee.
Bundled ELF link inputs retain system runtime dependencies through SONAMEs;
building a bundle on a newer glibc system sets a corresponding compatibility
floor. Release distribution needs an intentional sysroot, dependency/license
inventory, and platform-specific packaging. `roc build` produces an executable,
not a desktop installer or a macOS `.app` directory.
