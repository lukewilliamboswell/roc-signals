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
the module in a new thread, and every run encodes its input on the page,
copies it to the worker, and copies and decodes the answer on the way back.
A run is also
asynchronous: its answer arrives in a later turn, so the view has to say what
it shows meanwhile.

So keep cheap work on the page. Counting the words of a text box is quick, and
a `derive` gives its answer in the same turn as the keystroke:

{{ sample(file="workers/Editor.roc", region="cheap") }}

Move a calculation to a worker when you can feel it: when a keystroke or a
click visibly waits for it. To see where a run's time goes — waiting for a
worker, starting one, computing, copying — read the runtime's monitor; see
[Monitoring Workers](@/docs/worker-monitoring.md). A run whose time is mostly
copying and starting is better done on the page.

A program receives only its input. It keeps nothing between runs, so data it
needs every time, such as the text it searches, is sent and copied with every
run. There is no long-lived worker that holds data between requests.

## Programs and registration

A program is a `Worker.Program(input, output)`: a name and a pure function.
Make one with `Worker.pure(name, function)`. The types of the function are the
program's types, so a request can only send the input it expects and its
answer is already of the output type.

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
- Asking for a run of a program that is not registered, when the site asks:
  `contract: worker program "example.org/words/summary" is not registered; add its registration to with_workers (site /3/0)`,
  naming the site that asked.

## Showing a computed value

`Worker.derive(program, input, body)` is `Engine.derive` computed in a worker.
It gives `body` a value of type `Worker.Remote(output)`:

- `running` is true while the answer for the current input is still wanted;
- `answer` is `Nothing` before the first answer, `Done(output)` once there
  is one, or `Failed(error)` when a run produced no answer (see
  [Calculations that can fail](#calculations-that-can-fail)).

What you see:

- The run for the first input starts when the site mounts.
- When the input changes to an unequal value, `running` becomes true in the
  same turn and `answer` keeps the previous answer, so the view can go on
  showing it, as `show_summary` does.
- A newer input stops the run for the older one before it starts its own. An
  answer for an old input is never shown, and you keep no request number in
  your state.
- An equal input asks nothing.

The input is a snapshot: it is encoded when the run is asked for, and later
changes reach only the next run. Both the input and the output need equality,
like any `derive`.

Stopping a run that has started ends its worker; the next run starts a new
one. A run cannot be stopped and its worker kept. A run reports nothing until
it answers: there is no progress.

## An input that is sometimes not a question

`Worker.derive_when(program, input, body)` takes an input of type
`[Run(i), Skip]`. `Run(i)` asks for a run on `i`; `Skip` stops any run and
clears the answer, so `answer` is `Nothing` and `running` is false. Use it for
an empty search box or a form that is not valid yet:

{{ sample(file="workers/Editor.roc", region="derive-when") }}

The search's input includes the text, so editing the text while a word is
in the box runs the search again.

## Starting and cancelling from a button

When the user decides when a calculation runs, keep the request in state and
use `Engine.latest` (see
[Effects and the Browser](@/docs/effects-and-browser.md#superseding-sites)).
`program.request(input)` is the request for its plan, and
`program.result(res)` reads its result as `Try(output, Worker.Error)`:

{{ sample(file="workers/Editor.roc", region="model") }}

{{ sample(file="workers/Editor.roc", region="latest") }}

- "Count words" puts a new `Count` in state, and `latest` asks for a run on
  it. The press number makes each press a new value, so pressing again for
  the same text counts again.
- Pressing it while a count runs stops that run and starts a new one.
- "Cancel" puts `Idle` in state. Its plan is `[]`, so the change only stops
  the run that is in flight.
- Editing the text starts nothing: the site watches only `ask`.
- The answer is written to state by the reaction, so it stays after the run
  is over. `latest` never delivers an answer for a request it has stopped,
  so the reaction does not need to check which press it belongs to.

## Calculations that can fail

There are two kinds of failure, and they arrive in different places.

**The program's own error.** A calculation that can fail on its input — text
that is not a number — returns a `Try`. Declare it with `Worker.fallible`; its
output is that `Try`:

{{ sample(file="workers/Words.roc", region="fallible") }}

**No answer at all.** `Worker.Error` says why a run produced no output:

| Error | Cause |
|---|---|
| `Timeout` | The run's deadline expired, and it was stopped |
| `Refused` | Too many requests were in flight; the run was never started |
| `Lost(fault)` | The run crashed, or no worker could run it (see [Programs are pure](#programs-are-pure)) |

With `derive`, a program's own error is an answer, `Done(Err(...))`, and a
missing answer is `Failed(...)`. Matching both gives every case:

{{ sample(file="workers/Editor.roc", region="fallible-view") }}

With `request` and `result`, the same cases are `Ok(Ok(value))`,
`Ok(Err(error))` and `Err(Timeout)`, `Err(Refused)` or `Err(Lost(fault))`.

Use the program's own error for failures you expect. A `crash` in a program
is not an error you chose: it is `Lost`. The sample's specs show both: a
total whose own error is an answer, and a total whose run is lost (see
[Testing](#testing)).

## Deadlines

`program.with_deadline_ms(ms)` stops a run that has not answered `ms`
milliseconds after it was asked for, and answers `Timeout`:

{{ sample(file="workers/Words.roc", region="deadline") }}

- The time counts from when the run is asked for, so time spent waiting for
  a free worker and starting one counts too.
- Expiry stops the run: a run still waiting for a worker is dropped, and a
  running one ends its worker. The calculation does not finish in the
  background.
- `0`, the default, means no deadline. The longest deadline is ten minutes.

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
── ✗ missing method ───────────────────────────────────────────── main.roc:12:52

A where clause requires the encoder_for method here, but the type being used
doesn't have that method.

warm = Worker.pure("example.org/weather/warm", |c| c.degrees > 20)
                                                   ^^^^^^^^^

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
deep cannot be decoded: as an input its run is `Lost`; as an output it stops
the app with a contract error. Keep payloads plain: each payload type adds
code to the module.

## Lifetimes

A run belongs to the site that asked for it, and what you see follows from
that.

**Leaving the screen stops the run.** When a site is disposed — its `when`
branch switched, its row left the list, its panel closed — its run is
stopped, and no answer arrives. The panel below runs its totals in a
`derive` that lives inside the panel:

{{ sample(file="worker-lifetimes/Documents.roc", region="panel") }}

Closing the panel stops the totals' run.

**A result that must outlive a panel** needs a site that outlives it. The
"Export" button above is inside the panel, but it only writes a request into
state; the `latest` site that runs the export is mounted outside the panel
and writes the report into state. Closing the panel while an export runs
leaves the export running, and the report appears when it is done. Put such
a site in the scope that should own the work, usually next to the state its
answer goes into.

**Each row can have its own run.** A `derive` in an `each` row runs for that
row's value. Runs finish in any order, and each row shows its own answer.
Removing a row stops its run:

{{ sample(file="worker-lifetimes/Documents.roc", region="rows") }}

**Runs share the in-flight bound.** Worker runs count against the same bound
as HTTP requests and timers: 32 awaited requests by default, set with
`max_inflight` in `Engine.program_boot`. A run beyond the bound is not
started; it answers `Refused` straight away, and the others go on. The
sample sets a bound of three so its spec can reach it:

{{ sample(file="worker-lifetimes/Documents.roc", region="bound") }}

A refused run is not retried. A `derive` asks again only when its input
changes, so tell the user, as the rows do, or ask again from a button.

Runs beyond the number of workers wait for a free one. The pool's size is
the page's `maxWorkers` option (below).

## Programs are pure

A program shares nothing with the page. It receives its input and returns
its output; it cannot read the page's state, write it or ask for effects, and
Roc's types already rule that out. It may run in a worker that ran other
runs before, and nothing from those runs is visible to it.

A program that fails badly — a `crash`, running out of memory, a failed
`expect` in a development build — ends only its worker. The run answers
`Lost(fault)`, with the fault's class (`AppCrash`, `OutOfMemory`,
`ExpectFailed`, …), the diagnostic goes to the browser console, and the page
keeps working. The next run starts a new worker. In a browser without
workers, every run answers `Lost(Unavailable)`.

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
  onWorkerFault: (f) => console.warn(f.program, f.class, f.message),
});
```

- `maxWorkers` bounds the workers alive at once. Each runs one program at a
  time; further runs wait in order.
- `workerUrl` locates `worker.mjs` when you serve it elsewhere.
- `workers: "inline"` runs every job in a second instance of the module on
  the page's own thread, one at a time, with the same answers. The page
  waits while a job runs, and a deadline can only stop a job that has not
  started. It gives up what a worker is for; use it to measure or debug.
- `onWorkerFault` receives `{ id, program, class, message }` when a run is
  `Lost`, in addition to the console message. The diagnostic never reaches
  the app.

## Testing

Worker runs are effects, and specs control them like HTTP requests and
timers (see [Testing](@/docs/testing.md#effects)):

- A run waits until `(run-effect N)` runs it, `N` being its place among the
  document's HTTP requests, timers and runs in the order they were asked
  for. Natively the program runs in a child process of the spec runner; in
  Chrome it runs in a real worker, and the step waits for its answer. A
  program that crashes is `Lost` in both, and the next run works.
- `(expect-pending-effects N)` counts runs still waiting, so a spec can see
  that a run was stopped. `(expect-pending-work "name" N)` counts only the
  runs of one program, by its name.
- A run finishes when the spec runs it, so the order of `run-effect` steps
  is the order runs finish. Running a later run first checks the app against
  an earlier, slower one.

{{ sample(file="workers/specs/find.scm", syntax="scheme") }}

Here the text and the word are both in the box, so editing the text asks for
the summary (job 5) and the search (job 6); the spec answers the search first.

A spec's time only moves when the spec says so, so a deadline never expires
by itself, however long the run takes. Two steps answer a waiting run
without running it:

- `(time-out-work N)` expires its deadline: the run answers `Timeout`. A
  program without a deadline cannot time out, and the step fails.
- `(lose-work N FAULT)` answers `Lost(fault)`, as if its worker had
  crashed (`app_crash`), run out of memory (`out_of_memory`), or there were
  no worker at all (`unavailable`). See [Testing](@/docs/testing.md#effects)
  for every fault.

So the failure branches of a view have specs too:

{{ sample(file="workers/specs/failures.scm", syntax="scheme") }}

The work metrics count runs with the other effects: `effects_issued` for
each run asked for, `effects_cancelled` for each one stopped,
`effects_delivered` for each answer, and `effects_refused` for each one
the in-flight bound turned away (see
[Work assertions](@/docs/testing.md#work-budgets)).

## Which tool

| You want | Use |
|---|---|
| A cheap value computed from state | `Engine.derive` |
| A slow value that follows its input | `Worker.derive` |
| The same, when some inputs ask nothing | `Worker.derive_when` |
| A run the user starts and cancels, with its answer kept in state | `Engine.latest` with `request` and `result` |
| A calculation that fails on some inputs | `Worker.fallible` |
| A run that must not take too long | `with_deadline_ms` |
| Bulk bytes in a payload | `Wire.Bytes` |
| A result that survives the panel that asked for it | A site in a longer-lived scope |
| Where a run's time goes | [Monitoring Workers](@/docs/worker-monitoring.md) |
