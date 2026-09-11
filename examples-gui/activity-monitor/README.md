# Activity Monitor

Follow a UTF-8 plain-text log on this computer, or use the explicitly labeled
simulated replay to explore the interface without a file. Open log starts at
the beginning and drains existing data in sequential 64 KiB reads. Once caught
up, a scoped 500 ms timer polls for appended bytes. The log reader is this
app's own `LogReader` module: each read is one `Files.stat!` and one
`Files.read_bytes!`, a drain reads up to 64 consecutive chunks inside the
effect of the handler or timer tick that asked for it, and the cursor it keeps
carries the file's identity so a replaced or truncated file restarts history.
The polling timer exists only while the session waits on a caught-up file, so
pausing disposes it.

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
row includes the message and never wraps it; the feed clips what does not fit
and the scrollable inspector below it exposes the selected event's complete
text, wrapped. The inspector is a full-width shelf rather than a side column so
that a small window spends its width on messages instead of on chrome; it grows
only while an unterminated line needs the extra room. The virtual list lays out
only visible rows. Follow latest keeps the newest matching record visible; turn
it off to browse earlier events.

One toolbar carries the source choice, whichever source control is live, and
Clear history. Actions appear only in the phase that gives them meaning: Retry
read while a failed read offers an exact retry, Cancel operation while a choice
or a first read of a new file is in flight, and the replay controls only for the
simulated source. The banner beside the heading always states whether the feed
is the simulated replay or a real file, and the quiet lines underneath carry the
session notice and what history retains.

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
sequential reads, error retry, rotation and truncation. They stub the file
primitives underneath the log reader, so its rotation and truncation logic
runs for real under test; focused native file tests exercise actual IO and
the GPUI adapter tests exercise native interaction.
