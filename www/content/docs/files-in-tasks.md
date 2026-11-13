+++
title = "Files in Tasks"
description = "What a worker task's job can do with files: read the ranges it needs, build new files that come back to the page as handles, append to a file across jobs, download into a file, and save."
weight = 14
template = "page.html"
+++

# Files in Tasks

A [task](@/docs/workers.md)'s job receives the files in its input as
*handles* and calls effects on them: it reads the ranges it needs, a chunk
at a time, and writes new files with a *builder*. The files it answers with
reach the page as handles the page holds, which the app can show, save,
upload or send to another job. No file's bytes pass through the page's
memory on the way.

This page is about those effects and what the page does with the files.
[Workers](@/docs/workers.md) explains tasks themselves: declaring and
registering one, showing its answer, lifetimes and failures.
[Files](@/docs/files.md) explains how the app is given a file. The samples
come from `www/samples/tasks/`.

## A job that builds a file

This task converts a CSV file to TSV, 64 KiB at a time, so the job's memory
holds one chunk, never the whole file:

{{ sample(file="tasks/Convert.roc", region="transform") }}

`run!` reads with `source.read!(...)`, which brings a range of the file into
the job's memory, and writes with a builder: `Files.build!` (from the
platform's `Files` module, `import pf.Files`) opens one,
`append!` copies bytes into it, and `finish!` turns it into a new, immutable
`File`. Reading and appending can fail in ways the app should hear about (a
file the user changed since choosing it is `Unreadable`, a builder over its
bound is `TooLarge`), so both answer a `Try` whose error names only what
can happen, and `?` widens it into the task's own: the job answers
`Ok(file)` or `Err(error)`, and the page reads the error as
`Failed(error)`.

`to_tsv!` is a named function annotated with `=>`, not a lambda in the
props record. With the current compiler it has to be: see
[What a task may do](@/docs/workers.md#what-a-task-may-do).

## Holding the answer's file

The task is registered once and used like any other. Here a resource follows
the chosen file: when a file is chosen it asks for a job, and a newer file
stops the job for the older one.

{{ sample(file="tasks/Convert.roc", region="derive") }}

The converted file in the answer is a handle the page now holds. It is a
file like any other: it stays available while a value holds it, and is let
go when nothing does (see [Files](@/docs/files.md#how-long-a-file-lasts)).
The "Save TSV" button reads it out of the resource and keeps it in state to
save.

## Handles and effects

A file crosses between the page and a job as a handle: the job's `File`
names the same browser file, through a handle of the worker's own. What a
job can do with one:

| Effect | What it does |
|---|---|
| `file.read!({ start, len })` | The range's bytes, copied once into the job's memory, or `Err(Unreadable)` |
| `file.contents!()`, `file.contents_utf8!()` | The whole file or range, as bytes or text; `Err(Unreadable)`, or `Err(InvalidUtf8)` when text was asked for and it is not UTF-8 |
| `Files.build!({ name, mime, start_from })` | A new builder; `mime` defaults to `Auto` (the type of the file it starts from, or none), `start_from` to `Empty` |
| `builder.append!(bytes)` | Append a copy of `bytes`; `Err(TooLarge)` past the job's output bound |
| `builder.append_file!(file)` | Append a file the job holds, or a range of one, by reference: nothing is copied |
| `builder.finish!()` | The finished file, holding everything appended in order |

`file.name()`, `file.size()`, `file.mime()` and `file.slice(...)` are plain
functions and work in a job as they do on the page.

Effects exist only inside a job: a task's `run!`, or a preparation's
`prepare!` and its tasks. Page code cannot call one (the compiler refuses
an effect in a pure function), and the platform refuses one anywhere else
with a contract error.

A builder belongs to the call that opened it. It cannot be sent to the page
or put in an answer (it is not `Wire.Sendable`, so that does not compile),
appending to it after `finish!` is a contract error, and so is using one
after the call that opened it has returned, which only a builder kept in a
[preparation](@/docs/workers.md#a-preparation-and-its-tasks)'s state can
reach. Keep the finished file instead.

## Appending across jobs

To add to a file an earlier job built, start the new builder from it:

{{ sample(file="tasks/Convert.roc", region="append") }}

`start_from: From(previous)` puts the previous file first, by reference, so
the new file is the old one followed by what this job appends, and building
it copies only the new line. The old file is unchanged: the new one replaces
it in state only when the answer is delivered, so a job that is stopped or
fails leaves the log as it was. The page side asks for one job per click:

{{ sample(file="tasks/Convert.roc", region="log") }}

A request's input is a snapshot, held while the request is in state. Here
`logging` holds the old log until the answer arrives; setting it back to
`Idle` then lets the old file go.

## Composing files built by other jobs

`append_file!` takes a range of a file as readily as a whole one, so a job
can put together files that other jobs built without reading them: the
[Worker Lab](@/examples/worker-lab.md) draws a picture as strips, each
strip's job building a small image file of its own that the page shows as
it arrives, and a last job writes one picture from them, its own header
followed by each strip's pixels, `strip.slice({ start, len })` past the
strip's header, appended by reference. That job copies the header and
nothing else. Every strip it is sent is a file it holds, so a composition
of more than 63 files meets the bound of 64 files and builders a job holds.

## Saving

`File.save(file, {})` is a command that saves the file as a download under
its own name, or another with `{ name: Named("report.tsv") }`. The browser
decides where it goes, usually the downloads folder without asking, and
nothing comes back.

{{ sample(file="tasks/Convert.roc", region="save") }}

Issue a save in the turn of the click that asked for it, as here: the click
posts the file to an outbox in the state, and the `on_post` site issues the
command in that same turn, inside the browser's click listener, so the browser sees
the user's gesture. A save issued later, from a job's answer for example,
runs without one: Chrome starts the first such download but may hold back a
second one, or ask the user first. Let the user press a button when the file
is ready. Choosing where to save (a save dialog) is not built yet.

## Downloading into a file

`File.fetch({ url })` is an HTTP request whose response body becomes a file
the page holds. Ordinarily the body stays in the browser (a large one on
disk) and never enters Wasm memory; read the answer with `Engine.fetched`, or match
`Fetched({ status, headers, body })` to read the status and headers. The
file is a file like any other, so a task can process it:

{{ sample(file="tasks/Convert.roc", region="fetch") }}

{{ sample(file="tasks/Convert.roc", region="measure") }}

`File.FetchProps` also accepts `cache` (`Default` unless specified) and
`credentials` (`SameOrigin` or `Include`). Attach a
[progress handler](@/docs/effects-and-browser.md#transfer-progress) to follow
receiving counts. Default-cache downloads use XHR for progress; a non-default
cache mode with progress uses a fetch stream and holds the body in JavaScript
memory up to `maxFileBytes`. A mount's own `fetch` is always used when supplied
and has the same stream cost for progress.

A body larger than the page's `maxFileBytes` mount option (256 MiB by
default) is `Err(TooLarge)`. Like an HTTP request, a fetch is kept when its
site is disposed and answered to the nearest surviving ancestor.

## Limits

| Limit | Default | Beyond it |
|---|---|---|
| Bytes a job appends to its builders | `maxOutputBytes`, 256 MiB | `append!` answers `Err(TooLarge)`; the job decides |
| Files in one answer | 16 | The job is `Lost(Contract)`; nothing is delivered |
| Room on the page for an answer's files | 64 files held at once | The job is `Lost(ResourceLimit)`; nothing is delivered |
| Files and builders a job holds at once | 64 | The job is `Lost(ResourceLimit)` |
| A fetched body | `maxFileBytes`, 256 MiB | `Err(TooLarge)` |

Bytes appended with `append_file!` do not count against `maxOutputBytes`:
they are referenced, not copied. The bound exists because a builder's parts
are held in memory, and the browser does not move a large one to disk.

The platform sets no bound on how much of a file a job reads:
`maxFileBytes` limits what the page reads, digests and downloads, not a
job. Each read is copied into the worker's memory, which only grows, so
read a large file in chunks, as the conversion does.

With the `workers: "inline"` mount option jobs run on the page's thread,
where these effects do not exist: a job that reaches one is answered
`Lost(Unavailable)` (see [Workers](@/docs/workers.md#failures)).

## Not built yet

These are not built yet:

- an HTTP request from inside a job (download on the page with `File.fetch`
  and send the file to the task instead);
- progress reports while a job runs: a job cannot await anything, so it
  says nothing until it answers;
- a file the app can change in place, kept between sessions (an
  origin-private file);
- output larger than the output bound, which a builder backed by such a
  file would allow;
- a save dialog.

## Testing

A job that reads and builds files is a worker job in a spec: `run-effect`
runs it, in Chrome in a real worker and natively in a child process whose
effects read the spec's files, and `lose-work`, `time-out-work` and
`expect-pending-work` apply to it (see
[Workers](@/docs/workers.md#testing)). The files of its answer hold the
bytes the job built in both runners, so a later read, digest or save gives
the same bytes. `(max-output-bytes N)` in a spec's setup sets the output
bound, a `File.fetch` takes the staged `stub-http` answer as its body, and
`expect-saved` asserts a save's name and contents (neither runner downloads
anything):

{{ sample(file="tasks/specs/convert.scm", syntax="scheme") }}
