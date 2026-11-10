+++
title = "Workers"
description = "Run a slow pure calculation off the page's thread: declare it as a program, register it, and show its answer like a derived value."
weight = 10
template = "page.html"
+++

# Workers

When a calculation is slow enough that typing or clicking stutters, run it in
a worker. A worker is a Web Worker running a second copy of your app's
compiled module. You give it a pure Roc function and an input, the page goes
on handling events, and the answer comes back as an ordinary effect result.
You write no JavaScript and no serialisation code.

The samples on this page come from `www/samples/workers/`, a text box whose
analysis runs in workers, and `www/samples/worker-lifetimes/`, a list of
documents. Both have specs that run natively and in Chrome.

A complete use has three parts. A module declares the program, a name and a
function:

{{ sample(file="workers/Words.roc", region="programs") }}

The app registers it:

{{ sample(file="workers/Editor.roc", region="register") }}

And a site shows its answer for a value:

{{ sample(file="workers/Editor.roc", region="derive") }}

As the user types, the summary keeps showing the last answer, marked as being
updated, until the answer for the new text arrives.

## When a worker is worth it

A worker is not free. Starting one loads the worker script and instantiates
the module in a new thread, and every job encodes its input on the page,
copies it to the worker, and copies and decodes the answer on the way back.
A job is also
asynchronous: its answer arrives in a later turn, so the view has to say what
it shows meanwhile.

So keep cheap work on the page. Counting the words of a text box is quick, and
a `derive` gives its answer in the same turn as the keystroke:

{{ sample(file="workers/Editor.roc", region="cheap") }}

Move a calculation to a worker when you can feel it: when a keystroke or a
click visibly waits for it. To see where a job's time goes — waiting for a
worker, starting one, computing, copying — read the runtime's monitor; see
[Monitoring Workers](@/docs/worker-monitoring.md). A job whose time is mostly
copying and starting is better done on the page.

A program receives only its input. It keeps nothing between jobs, so data it
needs every time, such as the text it searches, is sent and copied with every
job. When the cost is not sending the data but preparing it (parsing a
document, building an index), a [prepared program](#prepared-programs-one-preparation-several-questions)
lets a worker keep the prepared state between jobs without changing any
answer.

The page and its workers run one module, so a program's code is part of the
module the page downloads and compiles, although the page never runs it. A
program that brings in a large library makes the app's module larger by
about that library's size, and its build longer. The types a program sends
and returns add code too, usually far less than the program itself.

## Programs and registration

A program is a `Worker.Program(input, output)`: a name and a pure function.
Make one with `Worker.program({ name, run })`, a props record: `name` and
`run` are required, and `deadline` (below) is optional. The types of `run`
are the program's types, so a request can only send the input it expects and
its answer is already of the output type.

Names are namespaced and unversioned, like `"example.org/words/summary"`.
The page and every worker run the same compiled module, so a name always
means the same function; there is nothing to keep in step between versions.

Declare programs wherever they belong, as in the `Words` module above, and
register each one once in the program your app binds as `main`, with
`Program.with_workers` and `registration()`. Use the same `Worker.Program`
value for the registration and every request, so the two cannot disagree.
An app has at most 64 programs.

Mistakes in the catalogue stop the app with a contract error, the way a
duplicate list key does (see [Reference](@/docs/reference.md#errors)):

- Registering two programs with one name, when the app mounts:
  `contract: worker program "example.org/words/summary" is registered twice in with_workers`.
- Registering more than 64, when the app mounts:
  `contract: with_workers registers more than 64 worker programs (program "…" is over the bound)`.
- Asking for a job of a program that is not registered, when the site asks:
  `contract: worker program "example.org/words/summary" is not registered; add its registration to with_workers (site /3/0)`,
  naming the site that asked.

## Showing a computed value

`Worker.derive(program, input, body)` is `Engine.derive` computed in a worker.
It gives `body` a value of type `Engine.Remote(output, Worker.Error)`:

- `request` is `Pending` while the answer for the current input is still
  wanted, and `Idle` otherwise;
- `answer` is `Unanswered` before the first answer, `Answered(output)` once
  there is one, or `Failed(error)` when a job produced no answer (see
  [Calculations that can fail](#calculations-that-can-fail)).

What you see:

- The job for the first input starts when the site mounts.
- When the input changes to an unequal value, `request` becomes `Pending` in the
  same turn and `answer` keeps the previous answer, so the view can go on
  showing it, as `show_summary` does.
- A newer input stops the job for the older one before it starts its own. An
  answer for an old input is never shown, and you keep no request number in
  your state.
- An equal input asks nothing.

The input is a snapshot: it is encoded when the job is asked for, and later
changes reach only the next job. Both the input and the output need equality,
like any `derive`.

Stopping a job that has started ends its worker; the next job starts a new
one. A job cannot be stopped and its worker kept (except a prepared program's
query, below). A job reports nothing until
it answers: there is no progress.

## An input that is sometimes not a question

`Worker.derive_when(program, input, body)` takes an input of type
`[Run(i), Skip]`. `Run(i)` asks for a job on `i`; `Skip` stops any job and
clears the answer, so `answer` is `Unanswered` and `request` is `Idle`. Use it for
an empty search box or a form that is not valid yet:

{{ sample(file="workers/Editor.roc", region="derive-when") }}

The search's input includes the text, so editing the text while a word is
in the box runs the search again.

A layer's body can be a named function, as `found` is. Give it a generic
context, `Val(ctx, Engine.Remote(…)) -> Elem(ctx)`, and it fits any site:
inside the layer the context is `In(Ctx, Engine.Remote(…))`, and a named
body never needs to write that out.

## Starting and cancelling from a button

When the user decides when a calculation runs, keep the request in state and
use `Engine.latest` (see
[Effects and the Browser](@/docs/effects-and-browser.md#superseding-sites)).
`program.request(input)` is the request for its plan, and
`program.result(res)` reads its result as `Try(output, Worker.Error)`:

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

## Calculations that can fail

There are two kinds of failure, and they arrive in different places.

**The program's own error.** A calculation that can fail on its input — text
that is not a number — returns a `Try`. Declare it with `Worker.fallible`; its
output is that `Try`:

{{ sample(file="workers/Words.roc", region="fallible") }}

**No answer at all.** `Worker.Error` says why a job produced no output:

| Error | Cause |
|---|---|
| `Timeout` | The job's deadline expired, and it was stopped |
| `Refused` | Too many requests were in flight; the job was never started |
| `Lost(fault)` | The job crashed, or no worker could run it (see [Programs are pure](#programs-are-pure)) |
| `FileFailed(error)` | The files its input holds could not be read into the worker, so it never started (see [Files](@/docs/files.md)) |

With `derive`, a program's own error is an answer, `Answered(Err(...))`, and a
missing answer is `Failed(...)`. Matching both gives every case:

{{ sample(file="workers/Editor.roc", region="fallible-view") }}

With `request` and `result`, the same cases are `Ok(Ok(value))`,
`Ok(Err(error))` and `Err(Timeout)`, `Err(Refused)`, `Err(Lost(fault))` or
`Err(FileFailed(error))`.

Use the program's own error for failures you expect. A `crash` in a program
is not an error you chose: it is `Lost`. The sample's specs show both: a
total whose own error is an answer, and a total whose job is lost (see
[Testing](#testing)).

## Deadlines

A program's `deadline: Ms(ms)` stops a job that has not answered `ms`
milliseconds after it was asked for, and answers `Timeout`:

{{ sample(file="workers/Words.roc", region="deadline") }}

- The time counts from when the job is asked for, so time spent waiting for
  a free worker and starting one counts too.
- Expiry stops the job: a job still waiting for a worker is dropped, and a
  running one ends its worker. The calculation does not finish in the
  background.
- `Unlimited`, the default, means no deadline. The longest deadline is ten
  minutes.

A program that never finishes holds its worker until its site stops it. Give
a program a deadline when its input can make it run for an unreasonable time.
A spec expires a deadline with `time-out-work` (see [Testing](#testing)).

## What can cross

A program's input and output must be `Wire.Sendable`. Most types are, with no
code from you: numbers, `Bool`, `Str`, lists, sets, dictionaries, records,
tuples and tag unions of those.

{{ sample(file="wire.roc", region="structural") }}

A nominal type crosses once it declares the codec hooks `parser_for : _` and
`encoder_for : _`. It is sent as the value it wraps:

{{ sample(file="wire.roc", region="nominal") }}

Functions, `State` handles, `Val`s and nominal types without the hooks do not
cross. Using one is a compile error at the program's declaration, naming the
type that lacks the hooks. Here `Celsius` declares only `is_eq`:

```text
── ✗ missing method ─────────────────────────────────────────────── main.roc:9:8

A where clause requires the encoder_for method here, but the type being used
doesn't have that method.

warm = Worker.program({ name: "example.org/weather/warm", run: |c| c.degrees > 20 })
       ^^^^^^^^^^^^^^

The value's type, which does not have a method named encoder_for, is:

    Celsius

Hint: For this to work, the type would need to have a method named encoder_for
associated with it in the type's declaration.
```

A second error says the same of `parser_for`.

`Try` does not cross either, whether it is the whole output or an item
inside it; the compiler reports `Try(U64, [NotANumber])` without
`encoder_for` in the same way. (The one exception is a record field of type
`Try(a, [Missing])`, which the derivation treats as an optional field.) A
calculation whose result is a `Try` is what `Worker.fallible` is for. Inside a
larger payload, use a tag union of your own, such as
`[Parsed(U64), NotANumber(Str)]`.

For bulk bytes — a file, an image — wrap the `List(U8)` in `Wire.Bytes`. It
is encoded exactly like the list but copied as one block rather than byte by
byte:

{{ sample(file="wire.roc", region="bytes") }}

Every payload is decoded strictly. A value nested more than 512 containers
deep cannot cross either way, and either way only the job is lost: an input
that deep fails to decode in the worker, and an output that deep is refused
in the worker before it is sent, so the job is `Lost(Contract)` and the
console names the program and the bound. Keep payloads plain: each payload type adds
code to the module.

## Lifetimes

A job belongs to the site that asked for it, and what you see follows from
that.

**Leaving the screen stops the job.** When a site is disposed — its `when`
branch switched, its row left the list, its panel closed — its job is
stopped, and no answer arrives. The panel below runs its totals in a
`derive` that lives inside the panel:

{{ sample(file="worker-lifetimes/Documents.roc", region="panel") }}

Closing the panel stops the totals' job.

**A result that must outlive a panel** needs a site that outlives it. The
"Export" button above is inside the panel, but it only writes a request into
state; the `latest` site that runs the export is mounted outside the panel
and writes the report into state. Closing the panel while an export runs
leaves the export running, and the report appears when it is done. Put such
a site in the scope that should own the work, usually next to the state its
answer goes into.

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
the page's `maxWorkers` option (below).

## Prepared programs: one preparation, several questions

Some apps ask several questions of one expensive intermediate result: an
explorer parses a document and then shows its outline, its search results and
its statistics. With plain programs each question parses the document again.
A **prepared program** names that first step once. `Worker.prepared` declares
the preparation, a pure function from its input to a state; the state can be
any type, since it never leaves the worker:

{{ sample(file="prepared/Notes.roc", region="prepare") }}

Each question is a typed **query** over the state, with its own name, input
type and output type, so no request or reply union with impossible arms is
needed:

{{ sample(file="prepared/Notes.roc", region="queries") }}

The preparation is registered once, listing the registrations of the
queries it answers:

{{ sample(file="prepared/Notes.roc", region="register") }}

A query is used like a program: `Worker.derive`, `Worker.derive_when`, or
`request` and `result` in an `Engine.latest` site. What it is asked is a
`Worker.Question(init, q)`, the preparation's `input` and the query's own
`query`:

{{ sample(file="prepared/Notes.roc", region="asked") }}

**Answers never depend on whether the state was kept.** A query's answer is
exactly what preparing afresh and asking would give. A worker that prepared a
state keeps it, and a later query over the same input runs on that worker and
costs a query instead of the preparation; the monitor shows which jobs
prepared and which reused (see [Monitoring Workers](@/docs/worker-monitoring.md)).
But keeping it is an optimisation the platform may or may not achieve, never
a promise: specs see only answers, and the native spec runner prepares every
time.

- **The same input is the same bytes.** A worker reuses a state only for an
  input whose encoding is identical. Comparing costs the page time in
  proportion to the input on every query, so pass a large input as a
  `File` (or a slice of one): a file's identity is its handle and range,
  which cost nothing to compare, and the worker reads its bytes once, when it
  prepares. A changed input prepares again, on another worker if one is
  free, so going back to an earlier input can still find its state.
- **One state per worker.** The pool's workers each keep at most one. A query
  waits for the worker that holds its state if that worker is busy; a new
  input prepares on a worker holding nothing, a new worker, or the one used
  least recently, whose state it replaces. A worker whose memory has grown
  past the `maxWorkerBytes` mount option (128 MiB by default) is ended after
  its job, its state with it. A job of an ordinary program that reads files
  on a worker holding a state lets the state go first, since the state may
  keep file buffers the job needs; a query may carry files of its own and
  still reuse the state it asks.
- **Leave the state's type to inference if you like.** A query's type names
  the state (`Worker.Query(File, List(Str), Str, List(U64))`), but
  `Worker.Query(File, _, Str, List(U64))` works too. Listing a query in
  another preparation's registration is a type error when the states'
  types differ (`Worker.QueryRegistration(List(Str))` against
  `Worker.QueryRegistration(U64)`).
  When they are the same type it compiles, and every job of that query is
  a contract error in its worker, answered `Lost(Contract)`.
- **A file's state goes with the file.** When the app lets go of a file, every
  state prepared from it is let go too.
- **Queries are read-only.** A query cannot change the state, so an answer
  never depends on which queries ran before it on that worker, and a lost
  worker loses nothing an answer needs.
- **Failure costs a preparation, never an answer.** A crash in the
  preparation or a query ends that worker: the query answers `Lost(fault)`,
  the state is gone, and the next query prepares again elsewhere. A deadline
  counts the preparation's time.
- **Cancelling.** By default a query stopped while it runs ends its worker,
  as any job does, and its state goes with it (`Stop`). A query declared
  `on_cancel: Finish` lets a stopped job complete and drops its answer, so
  its worker keeps the state for the next question; the cost is a worker busy
  for the rest of that job. A deadline always ends the worker.

**Tabs.** The sample's queries live inside their tabs, so switching away
disposes a tab's site and coming back asks again. With plain programs every
revisit pays the whole calculation; with a prepared program it pays one query,
because the worker kept the lines:

{{ sample(file="prepared/Notes.roc", region="tabs") }}

That is usually enough. Hoist a site out of the tab, next to the state its
answer belongs with, when even the query is slow or the answer must survive
the tab: a hoisted site asks once per input and keeps its answer, but it runs
while its tab is hidden. `Finish` suits a tab whose query the user often
leaves mid-job, so the worker is still warm when they come back.

## Programs are pure

A program shares nothing with the page. It receives its input and returns
its output; it cannot read the page's state, write it or ask for effects, and
Roc's types already rule that out. A job that needs to read a file in
chunks, or to write a file, is a [task](@/docs/tasks.md) instead: a
registered function that may call the platform's effects on the files it is
sent. A program may run in a worker that ran other
jobs before, and nothing from those jobs is visible to it.

A program that fails badly — a `crash`, running out of memory, a failed
`expect` in a development build — ends only its worker. The job answers
`Lost(fault)`, with the fault's class (`AppCrash`, `OutOfMemory`,
`ExpectFailed`, …), the diagnostic goes to the browser console, and the page
keeps working. The next job starts a new worker. In a browser without
workers, every job answers `Lost(Unavailable)`.

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
  maxWorkers: 4,            // most workers at once; default min(cores, 8)
  workerUrl: "/js/worker.mjs", // when worker.mjs is not beside runtime.mjs
  workers: "inline",        // run jobs on the page's thread instead (below)
  maxFileBytes: 64 << 20,   // most bytes of files one job reads; default 256 MiB
  onWorkerFault: (f) => console.warn(f.program, f.class, f.message),
});
```

- `maxWorkers` bounds the workers alive at once. Each runs one program at a
  time; further jobs wait in order.
- `workerUrl` locates `worker.mjs` when you serve it elsewhere.
- `maxFileBytes` bounds the bytes of [files](@/docs/files.md) one job reads
  into its worker; a job over it fails unread.
- `workers: "inline"` runs every job in a second instance of the module on
  the page's own thread, one at a time, with the same answers. The page
  waits while a job runs, and a deadline can only stop a job that has not
  started. It gives up what a worker is for; use it to measure or debug.
- `onWorkerFault` receives `{ id, program, class, message }` when a job is
  `Lost`, in addition to the console message. The diagnostic never reaches
  the app.

## Testing

Worker jobs are effects, and specs control them like HTTP requests and
timers (see [Testing](@/docs/testing.md#effects)):

- A job waits until `(run-effect N)` runs it, `N` being its place among the
  document's HTTP requests, timers and jobs in the order they were asked
  for. Natively the program runs in a child process of the spec runner; in
  Chrome it runs in a real worker, and the step waits for its answer. A
  program that crashes is `Lost` in both, and the next job works.
- `(expect-pending-effects N)` counts jobs still waiting, so a spec can see
  that a job was stopped. `(expect-pending-work "name" N)` counts only the
  jobs of one program, by its name.
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
  program without a deadline cannot time out, and the step fails.
- `(lose-work N FAULT)` answers `Lost(fault)`, as if its worker had
  crashed (`app_crash`), run out of memory (`out_of_memory`), or there were
  no worker at all (`unavailable`). See [Testing](@/docs/testing.md#effects)
  for every fault.

So the failure branches of a view have specs too:

{{ sample(file="workers/specs/failures.scm", syntax="scheme") }}

The work metrics count jobs with the other effects: `effects_issued` for
each job asked for, `effects_cancelled` for each one stopped,
`effects_delivered` for each answer, and `effects_refused` for each one
the in-flight bound turned away (see
[Work assertions](@/docs/testing.md#work-budgets)).

## Which tool

| You want | Use |
|---|---|
| A cheap value computed from state | `Engine.derive` |
| A slow value that follows its input | `Worker.derive` |
| The same, when some inputs ask nothing | `Worker.derive_when` |
| A job the user starts and cancels, with its answer kept in state | `Engine.latest` with `request` and `result` |
| A calculation that fails on some inputs | `Worker.fallible` |
| A job that must not take too long | `deadline: Ms(ms)` |
| Bulk bytes in a payload | `Wire.Bytes` |
| A result that survives the panel that asked for it | A site in a longer-lived scope |
| Several questions over one slow preparation | `Worker.prepared` and its queries |
| A job that reads a file a chunk at a time or writes a new file | A [task](@/docs/tasks.md) |
| A cancelled query that should keep its worker's state | `on_cancel: Finish` |
| Where a job's time goes | [Monitoring Workers](@/docs/worker-monitoring.md) |
