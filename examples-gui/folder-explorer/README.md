# Folder Explorer

Browse a navigable sample workspace or choose a real folder on this
computer. Each view lists only direct children. Open folder rows, follow the
breadcrumbs, or use Back, Forward, Up, and Refresh. The two history stacks retain
at most 64 accepted locations each. Changing folders clears the filter;
refreshing preserves it. File selection survives filtering and refresh when its
path still exists.

Select a regular file to inspect its metadata. **Preview text** loads at most
64 KiB of strict UTF-8, with an explicit truncated label. Empty files produce a
successful empty preview; binary or invalid text returns a visible error.
**Open in app** requests the desktop's associated application: the Unix file
service — the one macOS builds also use — hands the path to `gio open`, and the
Windows service hands it to the shell through
`rundll32.exe url.dll,FileProtocolHandler`. Success confirms the launch, not the
external application's lifetime; a macOS machine without `gio` installed reports
a launcher failure rather than opening anything. Sample files have explicit
sample previews and cannot launch nonexistent local files.
Symbolic links and special files remain visible as metadata, without traversal.

The accepted folder, results, selection, preview, and navigation history remain
visible throughout loading, cancellation, or failure. A successful directory
result commits the destination and history together. **Retry** repeats the exact
failed destination or file operation. Late canceled results cannot replace a
newer request. A refresh updates selected metadata and clears an older preview.

Keyboard controls are Ctrl+O to choose a folder, Alt+Left/Right for history,
Alt+Up for the parent, F5 to refresh, and Escape to cancel pending work. Buttons
also work through ordinary Tab and Enter/Space navigation. The result list uses
44-pixel virtual rows and stable full-path keys; visible labels use file names.

The window bounds itself: the list and the inspector share the height left by
the header and footer bands and scroll their own overflow, so the preview, the
status line and any asset problem stay reachable at the smaller supported
sizes. The preview field is read-only rather than disabled — ordinary contrast,
in the tab order, selectable and copyable — because its text belongs to the
loaded preview and no keystroke may move it away from that.

Directory observations use the public `Files.list_directory` task and its
10,000-entry/four-MiB aggregate-path bounds. Concurrent filesystem changes can
refuse an entire listing. Preview and launch use separate typed `Files` tasks;
all cancellation and stale-result handling belongs to the shared engine. Launch
cancellation cannot undo a handoff already accepted by the desktop. The external
application subsequently resolves its pathname under its own access policy.

Filtering, ordering, and complete directory replacements are explicit operations
over the current dataset. Projected row/query/order signals keep selection-only
updates independent. The pure `Session` module owns accepted navigation,
64-location history bounds, pending work, retry, and preview state. The native
semantic specs use typed file-result fixtures and cover direct-child browsing,
breadcrumbs, keyboard history, refresh, failure/cancel/retry, preview contents,
associated launch outcomes, and stale result refusal.

Folder and file rows carry small generated glyph PNGs from `assets/` —
regenerate them and `assets/manifest.json` (real SHA-256 hashes) with
`python3 assets/generate.py`. The app ingests the manifest at compile time and
verifies it at startup through `Files.verify_assets`; a missing or altered
glyph is named in a danger-colored status line and its rows show neutral
placeholder boxes while browsing continues. When running the built binary
directly, pass `--assets-root examples-gui/folder-explorer/assets` (or set
`ROC_SIGNALS_ASSETS_ROOT`); image sources are always relative paths inside
that root.

Build and run with the GUI workflow in
[`contributing.md`](../../www/content/docs/contributing.md).
