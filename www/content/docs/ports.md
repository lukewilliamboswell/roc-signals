+++
title = "Ports"
description = "Reach a browser service the platform does not model, such as IndexedDB or a save-file picker, through typed messages to JavaScript your page supplies."
weight = 16
template = "page.html"
+++

# Ports

The platform models the browser services most apps need: HTTP, local
and session storage, timers, history, focus, connectivity, workers, files
and clipboard writes. When your
app needs one it does not model, such as IndexedDB, a save-file picker, a
WebSocket or a payment sheet, reach it through a **port**.

A port is a named message channel between your app and a few lines of
JavaScript that your page passes when it mounts the app. Your app sends and
receives ordinary Roc values; the platform turns them into JSON for the
JavaScript and checks what comes back against the type you declared. The
JavaScript never sees your app's state, and your app never holds a
JavaScript object.

The samples on this page come from `www/samples/ports/`, a list of notes kept
in IndexedDB. Its spec runs natively and in Chrome. The
[Reading List](@/examples/reading-list.md) example is a whole app built the
same way: books kept in IndexedDB, still there after a reload, and a change
in one tab shown in every other. Its source shows each side of the line
between your app and its JavaScript: `Store.roc` declares the ports,
`ports.mjs` answers them, and `index.html` mounts the app with them.

## Three shapes

A port has one of three shapes, chosen when you declare it:

- A **command** sends a value and expects nothing back: log an event, show a
  native notification, write to a socket, or write to a store when the app
  learns the store's state another way. A command's failure never reaches
  the app (see [Keeping the page and a store agreeing](#keeping-the-page-and-a-store-agreeing)).
- A **call** sends a value and waits for one answer, like an HTTP request:
  read or write a record in IndexedDB, ask for a file name in a picker.
- A **subscription** sends an argument once and then receives any number of
  messages until the site that asked for it goes away: messages from a
  socket, changes another tab made to a store.

Declare each port once, in a module, with the types it carries. A port is
made from a props record: `Port.command({ name })`,
`Port.call({ name, timeout })` (the `timeout` is optional) and
`Port.subscription({ name, delivery })`:

{{ sample(file="ports/Notes.roc", region="ports") }}

Port names are global strings, so namespace them (`"example.org/notes/list"`).
List every port's `registration()` in the program:

{{ sample(file="ports/Notes.roc", region="program") }}

And use them from effect sites, like any other request:

{{ sample(file="ports/Notes.roc", region="view") }}

`Port.resource` is to a call what `Worker.resource` is to a worker task: a
resource holding the answer for an input, an `Engine.Remote`, where a newer
input stops the older call. `Port.resource_when` takes `[Run(input), Skip]`
for an input that is sometimes not a question.

Give each port its own effect site. A site's reaction receives every
result of what its plan issued, and a `PortAnswer` does not say which port
it came from, so a site that issued a call on one port and a subscription
on another could not tell their results apart. One outbox whose item's tag
names the port (`[Add(Book), Remove(Str)]`) works too: the reaction is
given the item, so it knows which port answered.

Decode a port's data into the app's own types at the door, in the
reaction, and check the app's invariants there (an id that must be unique,
a list that must be sorted), so nothing deeper takes the raw message on
trust.

### Sending when the user acts

A handler only writes state; requests leave from effect sites. To send
when the user clicks, the click posts what to send to an `Engine.Outbox`
in the state, and an `Engine.on_post` site sends it (see
[Effects and the Browser](@/docs/effects-and-browser.md#sending-when-the-user-acts)).
The Reading List keeps two: `adding`, the books the user asks to add, sent
as calls, and `writes`, each change's writes, sent as commands
(`ReadingList.roc`'s `send`):

- Every post is sent, so moving a book back to the shelf it was on is a
  write the store gets, even though it equals the write before.
- `on_post` never stops an earlier call for a later post, so each add's
  answer arrives, and its reaction is given the book it was posted with.
- A change that writes several things posts them as one list: an outbox
  takes one post per turn.
- A write the app relies on, one whose failure the user must hear of, is
  a call that answers `{}`, not a command: a command's failure never
  reaches the app.
- A record with one field is written with the field named:
  `remove.send({ id: id })`. `{ id }` is a block holding `id`, not a record.

## The JavaScript side

The platform supplies `runtime.mjs`, its `environment.mjs` fact readers,
and `worker.mjs` beside it. They are the same for every app and know nothing of your ports.
You write two things: the handlers, a module of plain functions, and the
page that mounts your app with them. The page passes one handler per
declared port in the `ports` option of `mountRocEngineApp`:

```js
import { mountRocEngineApp } from "./runtime.mjs";
import ports from "./notes-ports.mjs";

await mountRocEngineApp({ wasmUrl: "app.wasm", root: document.getElementById("app"), ports });
```

`maxPortBytes` (4 MiB unless the mount sets it, at most 64 MiB) bounds one
answer or message; see [Errors and bounds](#errors-and-bounds).

A handler is an object with one function, named after the port's shape:

```js
export default {
  // A command: called with the value; what it returns is ignored.
  "example.org/log": { command: (value, { port }) => console.log(value) },

  // A call: return the answer, or a promise of it.
  "example.org/notes/list": {
    call: async ({ prefix }, { signal }) => {
      const all = await readAllNotes();
      signal.throwIfAborted();
      return all.filter((note) => note.title.startsWith(prefix));
    },
  },

  // A subscription: emit messages, and return a function that stops them.
  "example.org/notes/changed": {
    subscribe: (arg, { emit, close, signal }) => {
      listeners.add(emit);
      return () => listeners.delete(emit);
    },
  },
};
```

The sample's complete handlers, IndexedDB included, are
`www/samples/ports/notes-ports.mjs`, and the Reading List's are
`examples/reading-list/ports.mjs`. Keep them with your app: they are your
code, not the platform's. Roc samples a note's time through `Timer(0)`;
the IndexedDB handler stores the record unchanged. Store a record exactly
as it crosses (wide integers as decimal strings, a tag by its name), so what a handler stores is what
it answers and no conversion between them can drift.

The runtime checks the handlers against the app's declarations before
anything runs. A declared port without a handler of its shape, or a handler
for a port the app does not declare, is an error from `mountRocEngineApp`
naming the port, so a misspelt name never becomes a feature that silently
does nothing.

What each handler can count on:

- **Every handler may be synchronous or `async`.** An answer is always
  delivered as a turn of its own, after the turn that sent the request.
- **A call's `signal` aborts** when the app no longer wants the answer: a
  `watch_latest` or `resource` site moved on to a newer value (`AbortError`), the
  call's timeout expired (`TimeoutError`), or the app stopped. Disposing
  the site that made the call does not abort it: a call usually has an
  effect worth finishing (a write), so, like an HTTP request, it is answered
  to the nearest surviving part of the app.
- **A subscription's `emit`** returns `true` when the message was taken and
  `false` when it was not (the subscription has ended, or its buffer is
  full). `close()` ends the subscription with `Closed`, and `close(error)`
  with `Threw`. Messages are delivered in order, each as its own turn, and
  never inside the call to `emit`.
- **A subscription's unsubscribe function** runs when the site that asked
  for it is disposed, when a `watch_latest` site moves on, or when the app stops.
- **Failures are values.** A call whose handler throws or rejects answers
  `Threw(message)`. A command handler's failure is reported to the console
  and to the `onPortFault` mount option. Nothing a handler does stops the
  app.

`runtime.emitPort(name, value)` feeds a subscription port whose handler is
`{ push: true }` from anywhere in the page, and returns how many live
subscriptions took the value.

## What crosses

Values cross as JSON in the platform's `PortJson` format, derived from your
types. The JavaScript receives plain data and answers plain data:

| Roc | JavaScript |
|---|---|
| `Bool`, `Str` | boolean, string |
| `U8` to `U32`, `I8` to `I32`, `F32`, `F64` | number |
| `U64`, `I64`, `U128`, `I128`, `Dec` | string of digits (use `BigInt(text)`); an answer may be a `BigInt`, or a number that is a safe integer |
| record | object with the field names as written in Roc; unknown keys in an answer are ignored |
| optional field `Try(a, [Missing])` | absent or `null` |
| `{}` | anything: `undefined`, `null` and `{}` all answer a call whose answer is `{}` |
| list, tuple | array |
| tag | `"Tag"`, `{"Tag": payload}` or `{"Tag": [a, b]}` |
| `Dict(Str, v)` | object |
| `Wire.Bytes` | `Uint8Array` (an answer may also be an `ArrayBuffer`) |
| `Engine.File` | the browser's `File`; an answer may be a `File` or `Blob` |

Bytes and files are never turned into text. Bytes are copied once in each
direction, and a file's contents never cross at all: the JavaScript
receives the browser's own `File` and can store it in IndexedDB, upload it
or hash it where it is, and a `File` or `Blob` it answers becomes a handle
in your app, released when your app lets it go (see
[Files](@/docs/files.md)).

An answer that is not JSON data, such as a `Map`, a function, a cycle or a
`NaN`, answers `Threw` with a message naming where it was. An answer that is
JSON data of the wrong shape is the typed `Undecodable(why)` error: your app
decides what to show, and `why` names the port and the place.

The type is all that is checked. A rule of your own that the type cannot
state is yours to check where the value arrives: the Reading List keys its
rows by book id, and an `Engine.each` given two rows with one key is a
contract error that stops the app, so it refuses a list of books with an
id twice as it refuses one of the wrong shape.

## Errors and bounds

`call.result(res)` and `subscription.message(res)` give `Ok(value)` or one
of `Port.Error`:

| Error | Means |
|---|---|
| `Refused` | The app had too many requests in flight (see `max_inflight`) |
| `Timeout` | The call's `timeout` expired |
| `Threw(message)` | The JavaScript threw, rejected, or answered something that is not JSON data |
| `TooLarge` | The answer was larger than the page's `maxPortBytes` (default 4 MiB, at most 64 MiB), or carried more files than the app can hold |
| `Closed` | The JavaScript ended the subscription |
| `Undecodable(why)` | The answer is not of the type the port declares |

`Closed` and `Threw` end a subscription; after them no more messages come.
Every other error reports one message, and the subscription goes on.

A subscription declares how its messages wait:
`Latest` keeps the newest waiting report and delivers at the next animation
frame, which suits a value whose newest state is all that matters (a
revision, a position, a status). A newer message replaces the waiting
report in place. An occurrence such as a click first delivers reports
queued before it. Hidden pages drain at the end of the reporting task;
visible pages given no frames drain within 100 ms.

`Every(n)` keeps up to `n` (1 to 1024) in order, and `emit` returns `false`
beyond them, so the JavaScript can slow down or drop. A port never lets a
busy page's queue grow without bound.

`Closed` and `Threw` are occurrences: a waiting latest message is delivered
before them. A message refused as `TooLarge` is itself a report and can
replace or be replaced by another waiting message. Test this delivery with
[`hold-reports` and `expect-reports-replaced`](@/docs/testing.md#reports).

Declaring a port twice, more than 64 ports, a request on a port the program
does not declare, or using a port as another shape than its declaration
are contract errors that name the port and the site.

## A stream of messages

A subscription that carries a stream (readings of a sensor, metrics,
prices) has to agree with the page on pace. The
[Status Page](@/examples/status-page.md) streams a reading of four
services' p95 latency every 250 ms from its own `ports.mjs`, and shows
how:

- **Choose `Every(n)` when every message is data.** Each reading is a
  point of a series, so one replaced before the page saw it would be a hole
  nobody reports; `Latest` is for a value whose newest state is all that
  matters. Pick `n` as the backlog worth keeping while the page is busy
  (the Status Page keeps 16, four seconds of readings).
- **Each message is a turn, and a backlog drains with no paint between
  them.** Sixteen waiting readings are sixteen turns in a row before the
  browser draws again, so keep what one message costs small. Draw an
  expensive view, such as a chart, from a copy the page brings up to date on
  an `Interval`, read through a `derive`, rather than from every message:
  the Status Page's chart follows a 250 ms redraw tick, whatever backlog
  drains between two of them.
- **Let the JavaScript set the pace, and listen when `emit` says no.**
  The handler measures on its own clock and emits one message per reading.
  When `emit` returns `false` the page is full: it keeps the rest and offers
  them again on the next animation frame, so a burst reaches the page as
  fast as the page takes it. What its own bounded buffer cannot hold it
  drops, and says so in the next message (`dropped`), because the app
  cannot see what never arrived.
- **Number the messages, and check the numbers at the door.** A sequence
  number lets the app tell a gap (draw a break in the line) from a reading
  that does not belong (refuse and count it). A stream the page joins again
  after a pause carries on its numbering; one that restarted it would be
  refused.
- **Stop when the subscription ends.** Mount the subscription's site where
  it is wanted, inside a branch for a visible page and a reader who has not
  paused, and return a function from `subscribe` that stops the timer:
  disposing the branch calls it.

The runtime's monitor counts each port's `messages`, `refusedEmits` and
`coalesced`, and its `backlog` now (see
[Monitoring Workers](@/docs/worker-monitoring.md)); the Status Page's
`feed-monitor.mjs` shows them beside the app's own counts.

## Keeping the page and a store agreeing

An app that keeps its data in a store the JavaScript owns, such as
IndexedDB, holds a copy of it in its state. The Reading List shows how the
copy and the store stay in agreement, across a reload and across tabs:

- **The page changes its copy in the turn of the click** and sends the
  write as a command. It never waits on the store to show a change.
- **The store's copy comes back as a subscription.** After any write, the
  handlers read the whole store afresh and emit it on a
  `Latest` subscription, and the app replaces its copy with it. A write in
  another tab is announced over a `BroadcastChannel`, and the tabs that
  hear it read and emit the same way.
- **A tab's own writes come back too.** A read another tab's write started
  may still be in flight when this tab writes; delivered after the write,
  it would undo it on the page. IndexedDB orders these reads and writes on one store as they were made, so the read that follows this tab's
  write sees it, and the last copy any tab receives is the store as it is.
- **A failed command is undone by the copy that follows.** The handler
  emits the store's copy whether or not its write succeeded, so the app
  never needs to hear of the failure to show the truth. When the user must
  be told, make the write a call that answers `{}`, and show its `Err`.
- **The first answer is a call.** `load` answers the store's books at
  start. A `stored` message that arrives first is newer, so the app takes
  `load`'s answer only while it is still loading.

The Reading List holds each of these with an `expect` on its decisions: a
`load` answered after a `stored` message changes nothing, and a book the
store added joins the copy once, even when `stored` brought it first.

## Testing

Specs never call your JavaScript: ports are answered by the spec, as HTTP
requests are, and the steps mean the same natively and in Chrome. A call
counts in the same numbering as `run-effect`:

| Step | Meaning |
|---|---|
| `(expect-port-call N "port" "json")` | Occurrence N is a pending call on `port` whose message is exactly `json` |
| `(answer-port N reply "json")` | Answer it with `json`, as written (so a spec can answer what your type does not accept) |
| `(answer-port N throw "message")`, `(answer-port N too-large)`, `(answer-port N timeout)` | Answer it `Threw`, `TooLarge` or, for a call with a timeout, `Timeout` |
| `(emit-port "port" "json")` | Deliver a message to every live subscription on `port` |
| `(close-port "port")`, `(fail-port "port" "message")` | End every live subscription on `port` with `Closed` or `Threw` |
| `(expect-port-subscriptions "port" n)` | Exactly `n` subscriptions on `port` are live |
| `(expect-port-sent "port" k "json")`, `(expect-port-sends "port" n)` | The `k`-th command sent on `port` carried `json`; `n` were sent |

Commands are not awaited, so `expect-pending-effects` does not count them.
To show what a reload does, `(navigate "/elsewhere")` mounts the app in a
new document: it asks the store again, and its calls are counted from 1.

Specs show what your app does with any answer; they cannot show that your
JavaScript gives the right ones. Test the handlers in a browser, against
the real service, with the page that mounts them: the Reading List's test
opens its own page in two tabs on one IndexedDB, and checks the records
the handlers wrote, a reload, and each tab seeing the other's changes. A
handler that needs no browser service can also be tested as the plain
function it is, for example with `node:test`.

## A port, an effect or a worker?

- **The platform models it:** use its effect. HTTP, storage, timers,
  history, focus and files need no JavaScript, and specs model them fully.
- **Your own Roc code off the page's thread** (a slow calculation, or
  reading and building files): use a [worker](@/docs/workers.md) task. It
  needs no JavaScript.
- **A browser service the platform does not model:** use a port.
- **Something that needs an answer inside a turn** (preventing a default,
  measuring layout before rendering): neither; a port's answer is always a
  later turn.
- **A widget with its own DOM:** a custom element, with attributes out and
  events in; a port has no DOM.

## Downloads

To let the user save a file your app made, prefer the platform's own file
effects where they fit (see [Files](@/docs/files.md)): they need no
JavaScript, specs model them, and the runtime handles the browser's rules
for user activation and object URLs. Use a port for what they do not cover,
such as `showSaveFilePicker` with a suggested directory: a call carrying the
bytes as `Wire.Bytes`, or a `File` your app holds, whose handler makes a
`Blob` and writes it.
