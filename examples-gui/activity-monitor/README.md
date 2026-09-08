# Activity Monitor

Follow a UTF-8 plain-text log on this computer, or use the explicitly labeled
simulated replay to explore the interface without a file. Open log starts at
the beginning and drains existing data in sequential 64 KiB reads. Once caught
up, a scoped 500 ms timer polls for appended bytes. There is at most one read
in flight; pausing cancels that work and disposes the polling timer.

Each newline-delimited record gets a monotonic sequence identity. Plain text
uses the `TEXT` label, without guessing severity from message contents; the
Errors only control applies to the replay's explicitly typed severities.
CRLF is accepted, and incomplete final lines appear separately in the inspector
until their newline arrives. An incomplete UTF-8 character remains unread
until its remaining bytes arrive. Invalid UTF-8 or a line larger than 16 KiB
pauses reading with a visible error and an explicit retry action.

History retains at most the newest 1,000 events and 4 MiB of message/component
text, evicting the oldest records first and showing the eviction count.
Clearing or evicting an event never recycles its identity. Each fixed-height
row includes the message; the scrollable inspector exposes its complete text.
The virtual list lays out only visible rows. Follow latest keeps the newest
matching record visible; turn it off to browse earlier events.

File cursor, partial line and history commit as one application state. A failed
or refused read preserves the last accepted state. A new file replaces history
only after its first accepted read. Replaced files and observed truncation
restart history and discard the old partial line, with an explicit notice.
Like the underlying stateless Files API, the app cannot detect a same-inode
truncate-and-regrow that completes between observations. The app owns no file
handle; the next read reopens the path through the bounded native service.

Unfiltered appends publish keyed row edits. The optional case-sensitive search
rebuilds a bounded projection of retained history; it is not an incremental
filter. Selection remains valid when a filter hides its row. If the selected
event is cleared or evicted, the inspector explains that it is gone.

Run `scripts/test.py gui` with the pinned Roc compiler, as described in the
contributor guide. The semantic journeys exercise replay, chunk assembly,
sequential reads, cancellation and stale results, error retry, rotation and
truncation. They simulate Files results; focused native file tests exercise
actual IO and the GPUI adapter tests exercise native interaction.
