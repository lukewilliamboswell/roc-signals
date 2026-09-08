# Activity Monitor

A deterministic operations replay with a scoped 500 ms producer, retained event
history, pause/resume, manual stepping, filtering, and a selection inspector.
The banner explicitly identifies the data as simulated; it does not inspect the
machine or claim to display live system telemetry.

Each fixed-height row shows the event identity, severity, and component. Select
it to read the complete message in the inspector; text filtering still searches
the message even though it is not repeated in the compact row.

History retains at most the newest 1,000 events and 4 MiB of message/component
text, evicting the oldest records first. The line assembler for incremental log
reads retains an incomplete final line and refuses lines larger than 16 KiB;
refusal leaves the caller free to retain its last accepted cursor. Clearing or evicting an event never
recycles its sequence identity. Pausing disposes the producer scope while the
parent owns the history. `State.update_cmd` appends to the latest settled history
without capturing an old snapshot in the timer callback.

Unfiltered appends publish keyed row edits. The optional case-sensitive text and
severity filter rebuilds a bounded projection of retained history; it is not an
incremental filter. Selection remains valid when a filter hides its row. If the
selected event is cleared or evicted, the inspector explains that it is gone.

Run the native semantic specs with `scripts/test.py gui` using the pinned Roc
compiler, as described in the contributor guide. The list lays out only visible fixed-height native rows. “Follow latest” keeps
the newest matching event visible; turn it off to browse earlier events.
