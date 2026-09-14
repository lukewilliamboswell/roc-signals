# Unreleased

Record changes after 0.2.0-rc3 here, including migration requirements.

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

Native effect workers reserve admission storage before taking pending ownership.
The native allocation-failure campaign now retries refused fixture registration
and effect-result preparation without rerunning the effect that produced the
result. The counter example also keeps its controls visible at the minimum
window size when native client-side decorations are present.

Unexpected command execution failures after a DOM event now contain the mount,
detach listeners and behaviours, and reject later dispatch. Recovery requires
a fresh mount; a partially applied command batch is never retried and
already-applied DOM changes are not rolled back.
