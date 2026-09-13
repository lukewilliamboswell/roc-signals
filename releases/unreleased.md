# Unreleased

Record changes after 0.2.0-rc3 here, including migration requirements.

The browser runtime now rejects creation over a live DOM node id. Replacement
must remove the old node or its ancestor before reusing the id, so behaviour
cleanup and listeners remain attached to the correct lifetime. Existing engine
command streams already follow this order; no application migration or wire
version change is required.
