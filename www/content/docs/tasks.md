+++
title = "Tasks"
description = "Run a job in a worker that reads the files it is sent as much as it needs and writes new files, which come back to the page as handles: converting, appending, downloading into a file, saving."
weight = 11
template = "page.html"
+++

# Tasks

A **task** is a function that runs in a worker and acts on files. Where a
[worker program](@/docs/workers.md) is a pure calculation on the bytes it is
sent, a task's job receives files as *handles* and calls effects on them: it
reads the ranges it needs, a chunk at a time, and writes new files with a
*builder*. The files it returns reach the page as handles the page holds,
which the app can show, save, upload or send to another job. No file's bytes
pass through the page's memory on the way.

| You want to | Use |
|---|---|
| Compute a value from values, off the page's thread | A [program](@/docs/workers.md) (`Worker.program`, today `Worker.pure`) |
| Ask several questions of one expensive preparation | A [prepared program](@/docs/workers.md#prepared-programs-one-preparation-several-questions) |
| Read a file a chunk at a time, or produce a file | A task (`Worker.task`, `Worker.fallible_task`) |
| Upload, digest or preview a file without reading it | An [operation on the file](@/docs/files.md#acting-on-a-file-where-it-lives) |

A program can read a file too: its bytes are read into the worker before
it runs, all of them, and it returns values. Use a task when the file is
large, when only part of it matters, or when the answer is a file.

## A task

A task is a name and an effectful function, registered once. This one
converts a CSV file to TSV, 64 KiB at a time, so the job's memory holds one
chunk, never the whole file:

{{ sample(file="tasks/Convert.roc", region="transform") }}

`run!` reads with `source.read!(...)`, which brings a range of the file into
the job's memory, and writes with a builder: `File.build!` opens one,
`append!` copies bytes into it, and `finish!` turns it into a new, immutable
`File`. Reading and appending can fail in ways the app should hear about (a
file the user changed since choosing it is `Unreadable`, a builder over its
bound is `TooLarge`), so this task is a `fallible_task` and `?` passes
those errors on: its answer is `Ok(file)` or `Err(error)`, and a job that
gave no answer at all is a separate `Err` (below).

The name is namespaced and unversioned, as a program's is: every worker runs
the same compiled module, so a name means one function. Write `run!` as a
named top-level function, as here; with the pinned compiler an anonymous
function written inside the record is checked as a pure one and is refused.

## Asking for a job

Register the task beside your programs, in `with_workers`:

{{ sample(file="tasks/Convert.roc", region="register") }}

A task has `request` and `result`, so everything that takes a program takes
a task. Here `Worker.derive_when` follows the chosen file: when a file is
chosen it issues a job (the layer is *pending*, `running` is true), and when
the answer arrives the layer *resolves* to it. A newer file stops the job
for the older one.

{{ sample(file="tasks/Convert.roc", region="derive") }}

The converted file in the answer is a handle the page now holds. It stays
available while a value holds it, and is let go when nothing does.

## Handles and effects

A file crosses between the page and a job as a handle: the job's `File`
names the same browser file, through a handle of the worker's own. What the
job can do with one:

| Effect | What it does |
|---|---|
| `file.read!({ start, len })` | The range's bytes, copied once into the job's memory, or `Err(Unreadable)` |
| `file.contents!()`, `file.contents_utf8!()` | The whole file or range, as bytes or text (`InvalidUtf8` when it is not UTF-8) |
| `File.build!({ name, mime, start_from })` | A new builder; `mime` defaults to `Auto` (the type of the file it starts from), `start_from` to `Empty` |
| `builder.append!(bytes)` | Append a copy of `bytes`; `Err(TooLarge)` past the job's output bound |
| `builder.append_file!(file)` | Append a file the job holds, or a range of one, by reference: nothing is copied |
| `builder.finish!()` | The finished file, holding everything appended in order |

Effects exist only inside a task's job. Page code cannot call one (the
compiler refuses an effect in a pure function), and the platform refuses one
anywhere else: a pure program, a prepared program and the page all run
without them.

A builder belongs to the job that opened it. It cannot be sent to the page
or put in an answer (it is not `Wire.Sendable`, so that does not compile),
and appending to it after `finish!` is a contract error.

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

## Saving

`File.save(file, {})` is a command that saves the file as a download under
its own name, or another with `{ name: Named("report.tsv") }`. The browser
decides where it goes, usually the downloads folder without asking, and
nothing comes back.

{{ sample(file="tasks/Convert.roc", region="save") }}

Issue a save in the turn of the click that asked for it, as here: the click
writes what to save into state, and the `on_change` site issues the command
in that same turn, inside the browser's click listener, so the browser sees
the user's gesture. A save issued later, from a job's answer for example,
runs without one: Chrome starts the first such download but may hold back a
second one, or ask the user first. Let the user press a button when the file
is ready. Choosing where to save (a save dialog) is not built yet.

## Downloading into a file

`File.fetch({ url })` is an HTTP request whose response body becomes a file
the page holds. The body stays in the browser (a large one on disk) and never
enters the page's memory; read the answer with `Engine.fetched`, or match
`Fetched({ status, headers, body })` to read the status and headers. The
file is a file like any other, so a task can process it:

{{ sample(file="tasks/Convert.roc", region="fetch") }}

{{ sample(file="tasks/Convert.roc", region="measure") }}

A body larger than the `maxFileBytes` mount option (256 MiB by default) is
`Err(TooLarge)`. Like an HTTP request, a fetch is kept when its site is
disposed and answered to the nearest surviving ancestor.

## What a task cannot do

A task's effects are synchronous: each one returns before the job goes on,
and a job runs from start to answer without pausing. So a task cannot wait
for anything: there is no timer, interval, page event or network response it
can block on (that would need the browser to suspend WebAssembly, or a
cross-origin isolated page, and the platform asks for neither). Things that
are not there yet:

- an HTTP request from inside a task (download on the page with
  `File.fetch` and send the file to the task instead);
- progress reports while a job runs: a job says nothing until it answers;
- a file the app can change in place, kept between sessions (an
  origin-private file);
- output larger than the output bound, which a builder backed by such a
  file would allow;
- a save dialog.

## Lifetimes and cancellation

A job is stopped when the request that asked for it is cancelled: its site
is disposed, a `latest` or `derive` site moves on to a newer input, or its
deadline expires. A job still waiting for a worker is dropped; a running one
is stopped by ending its worker, and its builders and everything they held go
with it. A job that crashes is answered `Lost`, and one whose worker is lost
for any other reason too. In every one of these cases nothing the job wrote
can be seen: only a delivered answer puts a file on the page.

What disposing the site does is the task's choice, made when it is declared:

{{ sample(file="tasks/Convert.roc", region="policies") }}

`deadline: Ms(60000)` stops a job that has not answered after a minute (the
wait for a free worker counts) and answers `Timeout`. `on_dispose:
Keep` keeps a job running when its site goes, for a job whose result the
user asked for and must not lose when a panel closes; its answer then goes
to the nearest surviving site, as an HTTP request's does. The default is
`Stop`: a job nobody will read is only cost.

A task's result is `Ok(output)` for an answer, or why there was none, the
same `Worker.Error` a program's has: `Timeout`, `Refused` (the in-flight
bound), `Lost(fault)`, or `FileFailed(TooLarge)` when the answer holds more
files than a job may return or the page has room for.

## Limits

| Limit | Default | Beyond it |
|---|---|---|
| Bytes a job appends to its builders | `maxOutputBytes`, 256 MiB | `append!` answers `Err(TooLarge)`; the job decides |
| Files in one answer | 16, and room on the page (64 files at once) | `FileFailed(TooLarge)`; nothing is delivered |
| Files and builders a job holds at once | 64 | The job is `Lost(ResourceLimit)` |
| A fetched body | `maxFileBytes`, 256 MiB | `Err(TooLarge)` |

Bytes appended with `append_file!` do not count against `maxOutputBytes`:
they are referenced, not copied. The bound exists because a builder's parts
are held in memory, and the browser does not move a large one to disk.

With the `workers: "inline"` mount option jobs run on the page's thread,
where a task's effects do not exist: a task is answered
`Lost(Unavailable)`, and programs keep working.

## Testing

A task's job is a worker job in a spec: `run-effect` runs it, in Chrome in a
real worker and natively in a child process whose effects read the spec's
files, and `lose-work`, `time-out-work` and `expect-pending-work` apply to it.
The files of its answer hold the bytes the job built in both runners, so a
later read, digest or save gives the same bytes. `(max-output-bytes N)` in a
spec's setup sets the output bound, a `File.fetch` takes the staged
`stub-http` answer as its body, and `expect-saved` asserts a save's name and
contents (neither runner downloads anything):

{{ sample(file="tasks/specs/convert.scm", syntax="scheme") }}

## Compared with roc-gui

roc-gui's `Action.task({ pending, run, resolve })` takes `run` as a closure
written where the action is, which a thread sharing the UI's memory then
runs. Here the job runs in another instance of the module with memory of its
own, and a closure cannot cross to it, so a task is a named, registered
function whose context is its input, and its `pending` and `resolve` are the
sites that issue it and react to its answer (`Worker.derive`, `latest`). The
handles are the same idea, and so are the `!` effects on them; what is
different is that a task's effects cannot wait, and that a handle crosses to
the job by token rather than being shared.
