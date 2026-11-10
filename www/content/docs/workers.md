+++
title = "Workers"
description = "Run work off the page's thread: declare a task, register it, show its answer like a derived value, read and build files in its jobs, share a preparation between tasks, and handle the ways a job can fail."
weight = 10
template = "page.html"
+++

# Workers

When a calculation is slow enough that typing or clicking stutters, or a
file is too large to bring into the page, do the work in a worker. A worker
is a Web Worker running a second copy of your app's compiled module. You
declare a **task**, a named Roc function. The page asks for a **job** of it
with an input and goes on handling events, and the job's answer comes back
as an ordinary effect result. You write no JavaScript and no serialisation
code.

The samples on this page come from `www/samples/workers/`, a text box whose
analysis runs in workers; `www/samples/files/` and `www/samples/tasks/`,
which read and convert a file; `www/samples/prepared/`, a notes explorer;
and `www/samples/worker-lifetimes/`, a list of documents. All of them have
specs that run natively and in Chrome.

## A task

A task is a name and a function, `run!`, from an input to a `Try`: the
job's output, or the task's own error.

{{ sample(file="workers/Words.roc", region="tasks") }}

- `Worker.task` takes a props record. `name` and `run!` are required;
  `deadline`, `on_dispose` and `on_cancel` are optional (see
  [Lifetimes](#lifetimes)).
- Its type is `Worker.Task(input, output, error)`. The types of `run!` are
  the task's types, so a request can only send the input the task expects,
  and its answer already has the output type.
- `run!` always answers a `Try`. A calculation that cannot fail answers
  `Ok(...)` and names its error `Worker.Never`, a type with no values. (The
  empty union `[]` would say the same, but it cannot cross to a worker, so
  a task's error is never `[]`.) A task with an error of its own is under
  [Failures](#failures).
- `run!` is an effectful field (`=>`), because a job may call the
  platform's effects on files (see [What a task may do](#what-a-task-may-do)).
  A plain calculation is written as a lambda, which the compiler accepts
  there whatever its body: `run!: |text| Ok(Words.summarise(text))`. A named
  pure function cannot fill the field directly; that is a type mismatch on
  the props record.
- Annotate every task. A top-level value needs a concrete type. A `run!`
  that only answers `Ok` says nothing about its error type, so without the
  annotation the compiler reports that the type never resolved. One whose
  `run!` answers an error of a known type compiles unannotated, but the
  annotation is still where a reader finds the task's types.

Names are namespaced and unversioned, like `"example.org/words/summary"`.
The page and every worker run the same compiled module, so a name always
means the same function; there is nothing to keep in step between versions.

## Registering it

Declare tasks wherever they belong, as in the `Words` module above, and
register each one once in the program your app binds as `main`, with
`Program.with_workers` and the task's `registration()`:

{{ sample(file="workers/Editor.roc", region="register") }}

Use the same `Worker.Task` value for the registration and for every
request, so the two cannot disagree. An app registers at most 64 names; a
task, a [preparation](#a-preparation-and-its-tasks) and each of a
preparation's tasks count one each.

Mistakes in the catalogue stop the app with a contract error, the way a
duplicate list key does (see [Reference](@/docs/reference.md#errors)):

- Registering two tasks with one name, when the app mounts:
  `contract: worker task "example.org/words/summary" is registered twice in with_workers`.
- Registering more than 64 names, when the app mounts:
  `contract: with_workers registers more than 64 worker tasks (task "…" is over the bound)`.
- Asking for a job of a task that is not registered, when the site asks:
  `contract: worker task "example.org/words/summary" is not registered; add its registration to with_workers (site /3/0)`,
  naming the site that asked.

## Showing its answer

`Worker.derive(task, input, body)` is `Engine.derive` computed in a worker.
It gives `body` a value of type `Engine.Remote(output, Worker.Error(error))`:

{{ sample(file="workers/Editor.roc", region="derive") }}

- `request` is `Pending` while the answer for the current input is still
  wanted, and `Idle` otherwise.
- `answer` is `Unanswered` before the first answer, `Answered(output)` once
  there is one, or `Failed(error)` when the job gave no output. The error is
  a `Worker.Error(error)` (see [Failures](#failures)). These tasks cannot
  fail, so `problem` matches a `Worker.Error(Worker.Never)` and has no arm
  for a failure of the task's own.

What you see:

- The job for the first input starts when the site mounts.
- When the input changes to an unequal value, `request` becomes `Pending`
  in the same turn and `answer` keeps the previous answer, so the view can
  go on showing it, as `show_summary` does. As the user types, the summary
  keeps showing the last answer, marked as being updated, until the answer
  for the new text arrives.
- A newer input stops the job for the older one before it starts its own. An
  answer for an old input is never shown, and you keep no request number in
  your state.
- An equal input asks nothing.

The input is a snapshot: it is encoded when the job is asked for, and later
changes reach only the next job. The input, the output and the task's error
need equality, like the value of any `derive`.

A job reports nothing until it answers: there is no progress. Stopping a
job that has started ends its worker, and the next job starts a new one
(unless the task says otherwise; see [Lifetimes](#lifetimes)).

### An input that is sometimes not a question

`Worker.derive_when(task, input, body)` takes an input of type
`[Run(i), Skip]`. `Run(i)` asks for a job on `i`; `Skip` stops any job and
clears the answer, so `answer` is `Unanswered` and `request` is `Idle`. Use
it for an empty search box or a form that is not valid yet:

{{ sample(file="workers/Editor.roc", region="derive-when") }}

The search's input includes the text, so editing the text while a word is
in the box searches again.

A layer's body can be a named function, as `found` is. Give it a generic
context, `Val(ctx, Engine.Remote(…)) -> Elem(ctx)`, and it fits any site:
inside the layer the context is `In(Ctx, Engine.Remote(…))`, and a named
body never needs to write that out.

### Starting and cancelling from a button

When the user decides when a job runs, keep the request in state and use
`Engine.latest` (see
[Effects and the Browser](@/docs/effects-and-browser.md#superseding-sites)).
`task.request(input)` is the request for its plan, and `task.result(res)`
reads its result as `Try(output, Worker.Error(error))`:

{{ sample(file="workers/Editor.roc", region="model") }}

{{ sample(file="workers/Editor.roc", region="latest") }}

- "Count words" puts a new `Count` in state, and `latest` asks for a job on
  it. The press number makes each press a new value, so pressing again for
  the same text counts again.
- Pressing it while a count runs stops that job and starts a new one.
- "Cancel" puts `Idle` in state. Its plan is `[]`, so the change only stops
  the job that is in flight.
- Editing the text starts nothing: the site watches only `ask`.
- The answer is written to state by the reaction, so it stays after the job
  is over. `latest` never delivers an answer for a request it has stopped,
  so the reaction does not need to check which press it belongs to.

## What a task may do

Most tasks only calculate. A job receives its input and nothing else: it
cannot read the page's state, write it, or ask for the page's effects, and
it keeps nothing between jobs, so a job that runs in a worker that ran
other jobs before sees nothing of them.

What a job may also do is act on files. A `File` in a job's input is a
handle, not the file's bytes (see [Files](@/docs/files.md)), and the job
calls the platform's effects on it to read as much as it needs:

{{ sample(file="files/Upload.roc", region="task") }}

`file.contents_utf8!()` brings the whole file into the job's memory as
text; `file.contents!()` gives its bytes and `file.read!({ start, len })` a
range of them. A read can fail, because the user may have changed or
deleted the file since choosing it, so each effect answers a `Try`, and `?`
passes its error on as the task's own. Here that error is
`Engine.FileError`.

A job can also write. `File.build!` opens a builder, `append!` copies bytes
into it, and `finish!` turns it into a new, immutable `File` that the
answer may hold. This task converts a CSV file to TSV, 64 KiB at a time, so
the job's memory holds one chunk, never the whole file:

{{ sample(file="tasks/Convert.roc", region="transform") }}

The file in the answer reaches the page as a handle the page holds, which
the app can show, save, upload or send to another job. No file's bytes pass
through the page's memory on the way.
[Files in Tasks](@/docs/files-in-tasks.md) covers every effect, appending
to a file across jobs, saving, and downloading into a file.

Write a `run!` like `to_tsv!` as a named function annotated with `=>`, as
the sample does. With the current compiler, a lambda written in the props
record is rejected when its body uses `?` on a method of its own parameter
(`source.read!(...)?`) and then uses `?` again: the error is a type
mismatch on that method, as if it had to be pure and could not fail. The
same body as an annotated function compiles. A lambda with one `?`, like
`Upload.count`'s, is fine.

Effects exist only inside a job. Page code cannot call one, because the
compiler refuses an effect in a pure function, and the platform refuses one
anywhere else with a contract error.

A job's effects are synchronous: each one returns before the job goes on,
and a job runs from start to answer without pausing. So a task cannot wait
for anything. There is no timer, page event or network response it can
block on, and no HTTP request from inside a job: download on the page with
`File.fetch` and send the file to the task instead.

## A preparation and its tasks

Some apps ask several questions of one expensive intermediate result: an
explorer parses a document and then shows its outline, its search results
and its statistics. With separate tasks, each job parses the document
again. A **preparation** names that first step once. `Worker.prepared`
declares it: a function `prepare!` from its input to a `Try` of a state.
The state can be any type, since it never leaves the worker, and
`prepare!` may read the files its input holds:

{{ sample(file="prepared/Notes.roc", region="prepare") }}

Each question is a task of the preparation, made with the preparation's
`task`. Its `run!` receives the state beside the job's own input, and it
has its own name, input type and output type:

{{ sample(file="prepared/Notes.roc", region="tasks") }}

A preparation's tasks share its error type, the third parameter of
`Worker.Preparation(init, state, error)`. When `prepare!` answers
`Err(error)`, each job of its tasks answers `Failed(error)`, which the app
matches like any task's failure. Here a file that is not text fails every
tab with `Failed(InvalidUtf8)`.

The preparation is registered once, listing the registrations of its
tasks:

{{ sample(file="prepared/Notes.roc", region="register") }}

A preparation's task is used like any task: `Worker.derive`,
`Worker.derive_when`, or `request` and `result` in an `Engine.latest` site,
with the same `deadline`, `on_dispose` and `on_cancel`. What it is asked is
a `Worker.Question(init, query)`, the preparation's `input` and the task's
own `query`:

{{ sample(file="prepared/Notes.roc", region="asked") }}

**Answers never depend on whether the state was kept.** A job's answer is
exactly what preparing afresh and running the task would give. A worker
that prepared a state keeps it, and a later job over the same input runs on
that worker and costs the task instead of the preparation; the monitor
shows which jobs prepared and which reused (see
[Monitoring Workers](@/docs/worker-monitoring.md)). But keeping it is an
optimisation the platform may or may not achieve, never a promise: specs
see only answers, and the native spec runner prepares for every job.

- **The same input is the same bytes.** A worker reuses a state only for an
  input whose encoding is identical. Comparing costs the page time in
  proportion to the input on every job, so pass a large input as a `File`
  (or a slice of one): a file's identity is its handle and range, which
  cost nothing to compare, and `prepare!` reads its bytes once. A changed
  input prepares again, on another worker if one is free, so going back to
  an earlier input can still find its state.
- **One state per worker.** The pool's workers each keep at most one. A job
  waits for the worker that holds its state if that worker is busy; a new
  input prepares on a worker holding nothing, a new worker, or the idle one
  used least recently, whose state it replaces. A worker whose memory has
  grown past the `maxWorkerBytes` mount option (128 MiB by default) is ended
  after its job, its state with it.
- **Leave the state's type to inference if you like.** A task's type names
  the state and the error
  (`Worker.PreparedTask(File, List(Str), Str, List(U64), Engine.FileError)`),
  but `Worker.PreparedTask(File, _, Str, List(U64), _)` works too. Listing
  a task in another preparation's registration is a type error when the
  states' types differ (`Worker.PreparedTaskEntry(List(Str))` against
  `Worker.PreparedTaskEntry(U64)`). When they are the same type it
  compiles, and every job of that task is a contract error in its worker,
  answered `Lost(Contract)`.
- **A file's state goes with the file.** When the app lets go of a file,
  every state prepared from it is let go too.
- **Tasks only read the state.** A task cannot change it, so an answer never
  depends on which jobs ran before it on that worker, and a lost worker
  loses nothing an answer needs. A finished file may be kept in the state.
  A builder may not: one that `prepare!` opened is closed when `prepare!`
  returns, and a job that uses it is a contract error, answered
  `Lost(Contract)`.
- **A lost worker costs a preparation, never an answer.** A crash in
  `prepare!` or in a task ends that worker: the job answers `Lost(fault)`,
  the state is gone, and the next job prepares again elsewhere. A deadline
  counts the preparation's time.

**Tabs.** The sample's tasks live inside their tabs, so switching away
disposes a tab's site and coming back asks again. With separate tasks every
revisit pays the whole calculation; with a preparation it pays one task,
because the worker kept the lines:

{{ sample(file="prepared/Notes.roc", region="tabs") }}

That is usually enough. Hoist a site out of the tab, next to the state its
answer belongs with, when even the task is slow or the answer must survive
the tab: a hoisted site asks once per input and keeps its answer, but it
runs while its tab is hidden.

## Lifetimes

A job belongs to the site that asked for it, and what you see follows from
that. Three props of a task say how long its jobs live: `on_dispose`,
`deadline` and `on_cancel`.

**Leaving the screen stops the job.** When a site is disposed (its `when`
branch switched, its row left the list, its panel closed), its job is
stopped, and no answer arrives. That is `on_dispose: Stop`, the default: a
job nobody will read is only cost. The panel below shows its totals in a
`derive` that lives inside the panel, so closing the panel stops the
totals' job:

{{ sample(file="worker-lifetimes/Documents.roc", region="panel") }}

**A job that must outlive its site says so.** The panel's "Export" button
asks for a report, and the site that issues it is inside the panel too. Its
task is declared `on_dispose: Keep`:

{{ sample(file="worker-lifetimes/Documents.roc", region="keep") }}

Closing the panel while an export runs leaves the job running. When it
answers, the reaction its request was made with still runs, and its write
to the page's state shows the report. Write a kept job's answer into state
that outlives the site, as here: a write to a state that was disposed with
the site is skipped, and a `Worker.derive` layer goes with its site, so ask
for a kept job with `request` and `result`. The other way to let work
outlive a panel is to mount its site outside the panel, in the scope that
should own the work.

**Each row can have its own job.** A `derive` in an `each` row runs for that
row's value. Jobs finish in any order, and each row shows its own answer.
Removing a row stops its job:

{{ sample(file="worker-lifetimes/Documents.roc", region="rows") }}

**Jobs share the in-flight bound.** Worker jobs count against the same bound
as HTTP requests and timers: 32 awaited requests by default, set with
`max_inflight` in `Engine.program_boot`. A job beyond the bound is not
started; it answers `Refused` straight away, and the others go on. The
sample sets a bound of three so its spec can reach it:

{{ sample(file="worker-lifetimes/Documents.roc", region="bound") }}

A refused job is not retried. A `derive` asks again only when its input
changes, so tell the user, as the rows do, or ask again from a button.

Jobs beyond the number of workers wait for a free one. The pool's size is
the page's `maxWorkers` option (see [Serving the app](#serving-the-app)).

**A deadline stops a job that takes too long.** `deadline: Ms(ms)` stops a
job that has not answered `ms` milliseconds after it was asked for, and
answers `Timeout`:

{{ sample(file="workers/Words.roc", region="deadline") }}

- The time counts from when the job is asked for, so time spent waiting for
  a free worker and starting one counts too, and so does a preparation.
- Expiry stops the job: a job still waiting for a worker is dropped, and a
  running one ends its worker. The work does not finish in the background.
- `Unlimited`, the default, means no deadline. The longest deadline is ten
  minutes.

A job that never finishes holds its worker until its site stops it. Give a
task a deadline when its input can make it run for an unreasonable time.

**A cancelled job can be allowed to finish.** A job is cancelled when its
site is disposed (unless its task says `Keep`) or when a `latest` or
`derive` site moves on to a newer input. By default, `on_cancel: Stop`, a
cancelled job that is running ends its worker, and anything that worker
held goes with it, a prepared state included. A task declared
`on_cancel: Finish`, as `longest` is in the notes sample above, lets a
cancelled job complete and drops its answer, so its worker, and the state
it holds, is kept for the next job; the cost is a worker busy for the rest
of that job. Either way the app never sees a cancelled job's answer.
`Finish` suits a tab whose task the user often leaves mid-job, so the
worker is still warm when they come back. A deadline always ends the
worker.

Whatever stops a job, nothing it wrote can be seen: only a delivered
answer puts a file on the page.

## Failures

A job that gives no output has failed in one of two ways: the task chose
to answer an error, or there was no answer at all. `Worker.Error(error)`
tells them apart:

| Error | Cause |
|---|---|
| `Failed(error)` | The task answered `Err(error)`: a failure of its own, which it chose |
| `Timeout` | The job's deadline expired, and it was stopped |
| `Refused` | Too many requests were in flight; the job was never started |
| `Lost(fault)` | The job crashed, or no worker could run it |

**The task's own error.** A calculation that can fail on its input (text
that is not a number, a file that cannot be read) answers `Err` with an
error type of its choosing:

{{ sample(file="workers/Words.roc", region="failing") }}

With `derive`, that error is `Failed(Failed(NotANumber(word)))`: the
layer's `Failed`, holding the `Worker.Error`'s. Matching every arm gives
every case:

{{ sample(file="workers/Editor.roc", region="failing-view") }}

With `request` and `result`, the same cases are `Ok(value)`,
`Err(Failed(error))`, `Err(Timeout)`, `Err(Refused)` and
`Err(Lost(fault))`.

**A lost job.** Use the task's own error for failures you expect. A
`crash` in a job is not an error you chose: it is `Lost`. A job that fails
badly (a `crash`, running out of memory, a failed `expect` in a development
build) ends only its worker. The job answers `Lost(fault)` with the fault's
class, the diagnostic goes to the browser console, and the page keeps
working. The next job starts a new worker.

| Fault | Cause |
|---|---|
| `AppCrash`, `OutOfMemory`, `ExpectFailed` | The job crashed, ran out of memory, or failed an `expect` |
| `Contract` | The job broke a rule of the API: an answer holding more than 16 files, a payload nested too deep, a builder used after `finish!` |
| `ResourceLimit` | The job held more than 64 files and builders at once, or the page had no room for the files of its answer |
| `Unavailable` | No worker could run the job (below) |
| `Executor` | The worker script itself failed |

`Lost(Unavailable)` has two causes. In a browser without workers, every job
answers it. And with the `workers: "inline"` mount option jobs run on the
page's thread, where the effects on files do not exist: a job that reaches
none of them answers as it would in a worker, and a job that reaches one
answers `Lost(Unavailable)`, while the page and later jobs keep working.

The workers sample's specs show both kinds: a total whose own error
reaches the view, and a total whose job is lost (see [Testing](#testing)).

## What can cross

A task's input, output and error must be `Wire.Sendable`. Most types are,
with no code from you: numbers, `Bool`, `Str`, lists, sets, dictionaries,
records, tuples and tag unions of those, and `File`, which crosses as a
handle.

{{ sample(file="wire.roc", region="structural") }}

A nominal type crosses once it declares the codec hooks `parser_for : _` and
`encoder_for : _`. It is sent as the value it wraps:

{{ sample(file="wire.roc", region="nominal") }}

Functions, `State` handles, `Val`s, builders and nominal types without the
hooks do not cross. Using one is a compile error at the task's declaration,
naming the type that lacks the hooks. Here `Celsius` declares only `is_eq`:

```text
── ✗ missing method ────────────────────────────────────────────── main.roc:17:8

A where clause requires the encoder_for method here, but the type being used
doesn't have that method.

warm = Worker.task({ name: "example.org/weather/warm", run!: |c| Ok(c.degrees > 20) })
       ^^^^^^^^^^^

The value's type, which does not have a method named encoder_for, is:

    Celsius

Hint: For this to work, the type would need to have a method named encoder_for
associated with it in the type's declaration.
```

A second error says the same of `parser_for`.

The `Try` a job answers is the platform's to send. A `Try` inside a
payload does not cross: the compiler reports `Try(U64, [NotANumber])`
without `encoder_for` in the same way. (The one exception is a record field
of type `Try(a, [Missing])`, which the derivation treats as an optional
field.) Inside a payload, use a tag union of your own, such as
`[Parsed(U64), NotANumber(Str)]`.

For bulk bytes the page already holds, wrap the `List(U8)` in `Wire.Bytes`.
It is encoded exactly like the list but copied as one block rather than
byte by byte:

{{ sample(file="wire.roc", region="bytes") }}

Every payload is decoded strictly. A value nested more than 512 containers
deep cannot cross either way, and either way only the job is lost: an input
that deep fails to decode in the worker, and an answer that deep is refused
in the worker before it is sent, so the job is `Lost(Contract)` and the
console names the task and the bound. Keep payloads plain: each payload
type adds code to the module.

## When a worker is worth it

A worker is not free. Starting one loads the worker script and instantiates
the module in a new thread, and every job encodes its input on the page,
copies it to the worker, and copies and decodes the answer on the way back.
A job is also asynchronous: its answer arrives in a later turn, so the view
has to say what it shows meanwhile.

So keep cheap work on the page. Counting the words of a text box is quick, and
a `derive` gives its answer in the same turn as the keystroke:

{{ sample(file="workers/Editor.roc", region="cheap") }}

Move a calculation to a worker when you can feel it: when a keystroke or a
click visibly waits for it. To see where a job's time goes (waiting for a
worker, starting one, computing, copying), read the runtime's monitor; see
[Monitoring Workers](@/docs/worker-monitoring.md). A job whose time is mostly
copying and starting is better done on the page.

A job receives only its input, so data it needs every time, such as the
text it searches, is sent and copied with every job. When the cost is not
sending the data but preparing it (parsing a document, building an index),
a [preparation](#a-preparation-and-its-tasks) lets a worker keep the
prepared state between jobs without changing any answer. When the data is
a file, send its handle: nothing is copied until the job reads it.

The page and its workers run one module, so a task's code is part of the
module the page downloads and compiles, although the page never runs it. A
task that brings in a large library makes the app's module larger by about
that library's size, and its build longer. The types a task sends and
returns add code too, usually far less than the task itself.

## Serving the app

The runtime starts its workers from `worker.mjs`, which it loads from beside
`runtime.mjs`. Copy both from `platform/` and serve them together, from the
same origin as the page:

```sh
cp platform/runtime.mjs platform/worker.mjs my-site/
```

A worker receives the module the page already compiled, so `app.wasm` is not
fetched again. Your page only calls `mountRocEngineApp`; it never sees the
worker protocol. Its options for workers:

```js
await mountRocEngineApp({
  wasmUrl: "app.wasm",
  root: document.getElementById("app"),
  maxWorkers: 4,               // most workers at once; default min(cores, 8)
  workerUrl: "/js/worker.mjs", // when worker.mjs is not beside runtime.mjs
  workers: "inline",           // run jobs on the page's thread instead (below)
  maxWorkerBytes: 64 << 20,    // retire a worker grown past this; default 128 MiB
  maxOutputBytes: 64 << 20,    // most bytes a job appends to builders; default 256 MiB
  onWorkerFault: (f) => console.warn(f.task, f.class, f.message),
});
```

- `maxWorkers` bounds the workers alive at once. Each runs one job at a
  time; further jobs wait in order.
- `workerUrl` locates `worker.mjs` when you serve it elsewhere.
- `workers: "inline"` runs every job in a second instance of the module on
  the page's own thread, one at a time. A job that only calculates gives
  the same answer; a job that reads or builds a file answers
  `Lost(Unavailable)` (see [Failures](#failures)). The page waits while a
  job runs, and a deadline can only stop a job that has not started. It
  gives up what a worker is for; use it to measure or debug.
- `maxWorkerBytes` ends a worker whose memory has grown past it, after its
  job, since a worker's memory never shrinks.
- `maxOutputBytes` bounds what one job copies into its builders (see
  [Files in Tasks](@/docs/files-in-tasks.md#limits)).
- `onWorkerFault` receives `{ id, task, class, message }` when a job is
  `Lost`, in addition to the console message; `task` is the task's name.
  The diagnostic never reaches the app.

## Testing

Worker jobs are effects, and specs control them like HTTP requests and
timers (see [Testing](@/docs/testing.md#effects)):

- A job waits until `(run-effect N)` runs it, `N` being its place among the
  document's HTTP requests, timers and jobs in the order they were asked
  for. In Chrome it runs in a real worker; natively it runs in a child
  process of the spec runner, which serves the job's effects from the
  spec's files. The step waits for the answer. A task that crashes is
  `Lost` in both, and the next job works.
- `(expect-pending-effects N)` counts jobs still waiting, so a spec can see
  that a job was stopped. `(expect-pending-work "name" N)` counts only the
  jobs of one task, by its name.
- A job finishes when the spec runs it, so the order of `run-effect` steps
  is the order jobs finish. Running a later job first checks the app against
  an earlier, slower one.

{{ sample(file="workers/specs/find.scm", syntax="scheme") }}

Here the text and the word are both in the box, so editing the text asks for
the summary (job 5) and the search (job 6); the spec answers the search first.

A spec's time only moves when the spec says so, so a deadline never expires
by itself, however long the job takes. Two steps answer a waiting job
without running it:

- `(time-out-work N)` expires its deadline: the job answers `Timeout`. A
  job of a task without a deadline cannot time out, and the step fails.
- `(lose-work N FAULT)` answers `Lost(fault)`, as if its worker had
  crashed (`app_crash`), run out of memory (`out_of_memory`), or there were
  no worker at all (`unavailable`). See [Testing](@/docs/testing.md#effects)
  for every fault.

So the failure branches of a view have specs too:

{{ sample(file="workers/specs/failures.scm", syntax="scheme") }}

A kept job is still pending after its site is gone, so a spec can close the
panel and then run it:

{{ sample(file="worker-lifetimes/specs/panel.scm", syntax="scheme") }}

The work metrics count jobs with the other effects: `effects_issued` for
each job asked for, `effects_cancelled` for each one stopped,
`effects_delivered` for each answer, and `effects_refused` for each one
the in-flight bound turned away (see
[Work assertions](@/docs/testing.md#work-budgets)).

## Which tool

| You want | Use |
|---|---|
| A cheap value computed from state | `Engine.derive` |
| A slow value that follows its input | `Worker.derive` with a task |
| The same, when some inputs ask nothing | `Worker.derive_when` |
| A job the user starts and cancels, with its answer kept in state | `Engine.latest` with `request` and `result` |
| A task that cannot fail | `Worker.Never` as its error |
| A task that fails on some inputs | An error type of its own, answered `Err(error)` and read as `Failed(error)` |
| A job that reads a file, or part of one | `file.read!`, `file.contents!`, `file.contents_utf8!` in `run!` |
| A job that writes a new file | `File.build!` and a builder; see [Files in Tasks](@/docs/files-in-tasks.md) |
| Several tasks over one slow preparation | `Worker.prepared` and its `task` |
| A job that must not take too long | `deadline: Ms(ms)` |
| A job that must finish although its panel closed | `on_dispose: Keep`, and a reaction that writes to state outside the panel |
| A cancelled job that should keep its worker's prepared state | `on_cancel: Finish` |
| Bulk bytes in a payload | `Wire.Bytes` |
| Where a job's time goes | [Monitoring Workers](@/docs/worker-monitoring.md) |

## Compared with roc-gui

roc-gui's `Action.task({ pending, run, resolve })` takes `run` as a closure
written where the action is, which a thread sharing the UI's memory then
runs. Here a job runs in another instance of the module with memory of its
own, and a closure cannot cross to it. So a task is a named, registered
function whose context is its input, and its `pending` and `resolve` are
the sites that issue it and react to its answer (`Worker.derive`, `latest`,
`Engine.resource`). The handles are the same idea, and so are the `!`
effects on them; what is different is that a job's effects cannot wait, and
that a handle crosses to the job by token rather than being shared.
