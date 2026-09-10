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
pauses reading with a visible error and an explicit retry action. The line
bound excludes the line separator; the partial buffer may retain one extra
terminal CR while waiting to determine whether it belongs to CRLF.

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

The event feed rows and inspector detail render in Source Code Pro, an
OFL-licensed monospace face embedded into the binary at compile time with
`import "….ttf" as source_code_pro : List(U8)`, registered at startup through
`Gui.embedded_fonts`, and applied with `Gui.font_family`. The font, its SIL Open
Font License 1.1 text, and provenance notes live beside the app in `assets/`.
The release example archive therefore carries everything needed to compile the
example without making the font a platform asset.

Run `scripts/test.py gui` with the pinned Roc compiler, as described in the
contributor guide. The semantic journeys exercise replay, chunk assembly,
sequential reads, cancellation and stale results, error retry, rotation and
truncation. They simulate Files results; focused native file tests exercise
actual IO and the GPUI adapter tests exercise native interaction.
