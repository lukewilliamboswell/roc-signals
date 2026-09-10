# Windows desktop evidence for the GUI examples backlog

[Current backlog](../../gui-examples-backlog.md), items GUI-25 onward plus the
Windows confirmations noted under GUI-03/04/05/14/15/22. This complements the
[Linux review](../2026-09-10/README.md) from the same day; it does not replace
it or approve any screenshot as a baseline.

## Build and verification

Source: `c5cc2188bc96ee037b868277b4aedfd43519e89e` (branch `gui-visual-refresh`,
clean). Compiler: `roc_nightly-windows_x86_64-2026-09-04-c125b82`, the pinned
GUI version. Host: the attested prebuilt `gui-host-x64mingw` from release
`deps-gui-host-20260910.1` (source `2ab48cf2`, archive SHA-256
`2b7d14f7…cee62f`), installed through `gui-host.lock.json`; no host or engine
source changed between that commit and HEAD. The local Windows GNU host builder
was not used: `scripts/windows_gnu_build.py` requires `pwsh`, which this
machine lacks (itself a contributor-experience gap; see GUI-31).

```powershell
$env:GUI_HOST_LOCK = "gui-host.lock.json"
python scripts/test.py gui --roc-bin C:\path\to\roc.exe --keep-output
```

All six apps and nine fixtures passed `roc check`, `roc test`, built with
`--target=x64mingw --opt=dev`, and passed all 42 maintained semantic specs on
Windows. The four Linux diagnostic specs fail identically on the Windows
executables (notes-open-lifetime, board-editor-lifetime, notes-windows-name,
explorer-windows-breadcrumbs). A green Windows suite is therefore not evidence
against anything below: every maintained spec injects `/tmp`-style paths.

## Capture conditions and limits

Windows 11 Pro 10.0.26200, one 1920×1080 display at 96 DPI (100 % scaling),
NVIDIA GPU, light system theme. Real framed windows on the user's desktop, not
a private compositor. Captures are unedited BitBlt copies of each window's DWM
frame rectangle (so they include the OS title bar and a 1-pixel border). Sizes
name the **outer** window rectangle requested through `SetWindowPos`; the
client area is 16 px narrower and 39 px shorter (1200×820 → 1184×781). Board
and Explorer were launched with `--host-assets-root` pointing at their `assets/`.

Input used `SendInput`; native Open/Save/Select Folder dialogs were driven by
typing a full path into the focused field and pressing Enter. The driver is
[tools/winshot.py](tools/winshot.py) (ctypes only, no Pillow); scenario scripts
are in [tools/](tools/) and expect the fixture files from
[tools/make_fixtures.py](tools/make_fixtures.py) under `tools/fixtures/`.
Scripts hard-code client coordinates for the 1200×820 layout and are
reproductions, not a maintained test.

Two environment details matter. The Git Bash used to launch most runs exports
`HOME`; the `*-nohome-*` captures were launched with `HOME` removed, which is
the normal state for a Windows app started from Explorer or a shortcut. The
user's OneDrive folder holds only `desktop.ini`, so cloud placeholder behavior
(reparse points) could not be exercised.

Not validated: DPI scaling other than 100 %, dark system theme, UNC/network
paths, OneDrive placeholders, screen readers, IME, touch, multiple monitors,
Windows on Arm, the optimized (`--opt`) application build, or a bundle install.

## Screenshot index

| App/state | Screenshot | Items |
| --- | --- | --- |
| Counter 1200×820 / 800×600 / 360×600 | [wide](counter-1200x820.png), [800](counter-800x600.png), [narrow](counter-360x600.png) | GUI-14, GUI-25, GUI-26 |
| Keyed Rows 1200×820 / 800×600 / 360×600 | [wide](keyed-rows-1200x820.png), [800](keyed-rows-800x600.png), [narrow](keyed-rows-360x600.png) | GUI-14, GUI-25, GUI-26 |
| Notes initial 1200×820 / 800×600 / 360×600 | [wide](notes-editor-1200x820.png), [800](notes-editor-800x600.png), [narrow](notes-editor-360x600.png) | GUI-25, GUI-26 |
| Notes native Open dialog | [dialog](notes-win-open-dialog.png) | GUI-30 |
| Notes after opening `…\fixtures\Ideas.txt` | [full path as title](notes-win-opened-windows-path.png) | GUI-05, GUI-27 |
| Notes after typing a line and Ctrl+S | [saved](notes-win-after-ctrl-s.png) | GUI-28 |
| Notes Save As after a Windows open | [Invalid path: /](notes-win-after-save-as-click.png) | GUI-05 |
| Notes Save As on an untitled note (HOME set) | [dialog](notes-win-save-as-untitled.png) | GUI-30 |
| Notes Save As on an untitled note, HOME unset | [service unavailable](notes-save-as-nohome-after-click.png) | GUI-27 |
| Notes discard dialog at 376×600 | [clipped](notes-win-discard-dialog-360.png) | GUI-04 |
| Notes close dialog | [dialog](notes-win-close-dialog.png) | GUI-04 |
| Notes BOM file, Ctrl+Home, Right, `X` | [caret](notes-win-bom-caret-after-one-right.png) | GUI-28 |
| Notes Ctrl+End, Ctrl+Left, `Y` | [no word motion](notes-win-ctrl-left.png) | GUI-20 |
| Activity initial 1200×820 / 800×600 / 360×600 | [wide](activity-monitor-1200x820.png), [800](activity-monitor-800x600.png), [narrow](activity-monitor-360x600.png) | GUI-12, GUI-25, GUI-26 |
| Activity following `app.log` | [opened](activity-win-log-opened.png), [after append](activity-win-log-appended.png), [after Cancel click](activity-win-after-cancel.png) | GUI-29 (working case) |
| Activity close crash | [WinDbg stack](activity-close-crash-windbg.txt) | GUI-29 |
| Board initial 1200×820 / 800×600 / 360×600 | [wide](task-board-1200x820.png), [800](task-board-800x600.png), [narrow](task-board-360x600.png) | GUI-03, GUI-25, GUI-26 |
| Board Save As dialog (HOME set) | [dialog](board-win-save-as-dialog.png) | GUI-30 |
| Board after Save As to a Windows path | [full path as name](board-win-after-save-as.png) | GUI-05 |
| Board Save As with HOME unset | [service unavailable](board-save-as-nohome-after-click.png) | GUI-27 |
| Board close dialog 1200×820 / 376×600 | [wide](board-win-close-dialog.png), [clipped](board-win-close-dialog-360.png) | GUI-04 |
| Board drag hover and drop into Complete | [hover](board-win-drag-hover-complete.png), [dropped](board-win-after-drag-settled.png) | GUI-23 (ghost shows `task-1`) |
| Explorer initial 1200×820 / 800×600 / 360×600 | [wide](folder-explorer-1200x820.png), [800](folder-explorer-800x600.png), [narrow](folder-explorer-360x600.png) | GUI-10, GUI-25, GUI-26 |
| Explorer Select Folder dialog | [dialog](explorer-win-choose-folder-dialog.png) | GUI-30 |
| Explorer real folder `…\fixtures\Project` | [breadcrumbs and rows](explorer-win-project-folder.png) | GUI-05, GUI-27 |
| Explorer Up from a real subfolder | [Invalid path](explorer-win-up.png) | GUI-05 |
| Explorer at `C:\` and Up from it | [root](explorer-win-drive-root.png), [Up](explorer-win-drive-root-up.png) | GUI-05 |
| Explorer `…\fixtures` listing | [unreadable labels](explorer-win-fixtures.png) | GUI-27 |
| Explorer README.txt selected / Preview text clicked (1200×1040) | [selected](explorer-win-tall-readme-selected.png), [after click](explorer-win-tall-readme-preview.png) | GUI-32 |
| Explorer sample README.md previewed (1200×1040) | [sample preview](explorer-win-sample-readme-preview.png) | GUI-11, GUI-32 (control) |
| Explorer real README.txt, Preview text clicked again | [no change](explorer-win-real-readme-preview-2.png) | GUI-32 |
| Explorer short real path `…\skills\windows-debugging\SKILL.md`, selected / Preview text clicked | [selected](explorer-win-short-path-selected.png), [after click](explorer-win-short-path-preview.png) | GUI-32 (no overflow) |

## Reproductions

**GUI-29 close crash.** Launch Activity Monitor, Open log…, choose any small
UTF-8 log (the fixture `app.log`), wait at least 3.5 s while "Following file;
caught up." is shown, then close the window. Exit code `0xC0000005`.
Observed 6 of 6 times with dwell ≥ 3.5 s, 0 of 3 with dwell ≤ 2.5 s, 0 of 1
after Pause following, 0 of 1 with simulated replay running for 6 s.
[tools/scn_round3.py](tools/scn_round3.py) part (a) is the timing sweep and
[tools/dbg_crash.py](tools/dbg_crash.py) runs it under WinDbgX. The captured
stack is on the main thread inside a window procedure dispatched from
`DispatchMessageWorker` (the close path), reading a byte at `[r8+0F8h]` from
freed heap memory. The release host has no symbols, so frames are module
offsets (`activity_monitor+0x6037ab` top frame, image base `0x7ff6b7ad0000`).

**GUI-27 HOME.** Start `task-board.exe` from PowerShell or Explorer (no `HOME`),
click Save As…: red status `Native service unavailable: HOME is missing or is
not UTF-8`, no dialog. Same for Notes' first Save As. With Git Bash's `HOME`
the dialog opens in the profile root, not Documents.

**GUI-05 on real Windows.** Notes: Open… `Ideas.txt` → title shows the full
path; Save As… → `Invalid path: /`, no dialog. Explorer: Choose folder → any
real folder → breadcrumbs `/` + whole path; Up → `Invalid path:` and a Retry
button; the same at `C:\`. Row labels are full paths wrapped and clipped.

**GUI-28 line endings.** Open the CRLF `Ideas.txt`, press Ctrl+End, type a new
line, Ctrl+S. File bytes afterward:
`First idea\r\nSecond idea with CRLF endings\r\n\nThird idea typed on Windows`.
Open `bom.txt`, Ctrl+Home, Right, type `X`: the editor shows `XBOM line one`
because the caret moved past the invisible U+FEFF, which also counts as a
character in the footer.

**GUI-32 preview.** Choose a real folder, select a file, click Preview text or
Open in app. Neither the notice line nor the button focus changes, with a deep
path that overflows the window and with a 47-character path that does not; in
the sample workspace the same click previews immediately and the button takes
focus. No external application started (no Notepad process after Open in app).
[tools/scn_round6.py](tools/scn_round6.py) is the short-path run.

## Host flags in these tools

The captures were taken before every host-owned flag gained its `--host-`
prefix. The scripts here have been updated to the current spelling so they can
be re-run; the images themselves are unchanged and still show the pre-fix
behaviour.

## Diagnostic specs

The four diagnostics this review shipped were replayed against the Windows
executables with `--host-run-spec-json --host-entropy-seed 0` and failed
identically. No new Windows spec could be written at the time: the fixture guard
(`src/spec/file_fixtures.zig`) rejected any path that did not begin with `/`, so
the typed fixtures could not express `C:\…`.

Both of those statements describe the state at capture time. The diagnostics have
since been fixed and their cases moved into the maintained suites, and the guard
now accepts drive, UNC and POSIX spellings, so a Windows path *is* expressible in
an ordinary spec. None of that has been re-run on Windows; GUI-34 in the backlog
tracks doing so.
