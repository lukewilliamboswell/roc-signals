# Unreleased

Record changes after 0.2.0-rc3 here, including migration requirements.

## Breaking: the GUI platform has moved to roc-gui

The native desktop GUI platform — the `platform-gui` package, its GPUI host,
the `Files`, `Http`, and `Env` native services, and the `examples-gui`
applications — has been removed from this repository. It is now developed in
[lukewilliamboswell/roc-gui](https://github.com/lukewilliamboswell/roc-gui).
Releases from this repository publish only the web platform package; the
combined release no longer contains a GUI archive.

Applications that import the GUI package URL from an earlier Roc Signals
release (such as 0.2.0-rc3) keep building against that immutable archive, but
receive no further updates from here. Move them to a roc-gui release to
continue. Web applications are unaffected apart from the removal of
native-only vocabulary that the browser host already rejected, such as
keyboard-shortcut chords and window-close declarations.

The browser runtime now rejects creation over a live DOM node id. Replacement
must remove the old node or its ancestor before reusing the id, so behaviour
cleanup and listeners remain attached to the correct lifetime. Existing engine
command streams already follow this order; no application migration or wire
version change is required.

Transaction preparation preserves settled signal caches and retained ownership,
while action continuations still receive fresh post-commit reads. Empty keyed
list registrations are released with their declaring scopes. Transaction-index
reset and nested row-mirror updates now follow touched entries rather than
retained table capacity or the complete row mirror.

The native allocation-failure campaign now retries refused fixture registration
and effect-result preparation without rerunning the effect that produced the
result.

Unexpected command execution failures after a DOM event now contain the mount,
detach listeners and behaviours, and reject later dispatch. Recovery requires
a fresh mount; a partially applied command batch is never retried and
already-applied DOM changes are not rolled back.
