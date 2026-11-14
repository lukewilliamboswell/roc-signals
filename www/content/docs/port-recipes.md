+++
title = "Port Recipes"
description = "Scoped live connections and typed access to browser services the platform does not model."
weight = 17
template = "page.html"
+++

# Port Recipes

Use a [port](@/docs/ports.md) for a browser service the platform does not
model. Each recipe below declares the data Roc sends and receives, supplies
a handler with a bounded lifetime, and has a spec that supplies fake answers.
The source is `www/samples/port-recipes/`. Its `index.html` mounts the compiled
app with `ports.mjs`; a camera preview is outside the engine's mount root,
and the gauge draws inside its own shadow root.

The platform already models HTTP, storage, timers, history, focus, workers,
files, clipboard writes and observations of layout and media queries. Use
those requests for those services. The examples here never bypass the
engine's routing or keep Roc values in JavaScript.

## A gesture reaches the handler

A button posts a small marker to an outbox. Its effect site sends in that
click's turn, while the browser's transient user activation is available.
The shared call view samples the argument only when the marker is posted:

{{ sample(file="port-recipes/CallView.roc") }}

A permission prompt, share sheet or fullscreen request must begin directly
in the handler, before an `await` or another task loses the gesture. An
answer always arrives in a later turn. Sending from a timer or from a
previous call's answer does not preserve the original click's activation.
Browser permissions, secure-context requirements and an embedding page's
permissions policy still apply. A rejected call becomes `Port.Error.Threw`;
a failed command goes to the mount's `onPortFault` callback.

## WebSocket and Server-Sent Events

One subscription owns one connection. It returns `Opened`, then numbered
`Event` messages. It takes the last sequence the app kept as `after`, so a
server can resume from that cursor. This sample expects SSE events whose
`id` is a decimal U64 and whose `data` is text. WebSocket text frames carry
JSON with a decimal-string `seq` and a text `data`. Both endpoints receive
`after` in the URL's query string. A server must keep a bounded history or
report the gap when it cannot replay it; opening a new connection alone
cannot recover lost data.

{{ sample(file="port-recipes/Sockets.roc", region="declaration") }}

The handler closes an `EventSource` on its first error, disabling the
browser's automatic reconnect, and ends the subscription with `Threw`.
A clean WebSocket close gives `Closed`; another close gives `Threw`.
Unsubscribe and abort remove listeners, stop the drain and close the socket.
A command to the named `primary` connection sends only while it is open;
otherwise it is dropped. Declare a call instead when the app needs an
acknowledgement, and make the server's acknowledgement the answer.

The runtime keeps `Every(16)` messages; the handler has its own bounded
queue of at most 64 messages and 64 KiB, and reports a cumulative count
for that connection of older readings it drops when the queue fills. It retries
`emit` when the runtime says the queue is full. Neither layer retains an
unbounded backlog, and malformed frames end the connection rather than
being repaired.

{{ sample(file="port-recipes/sockets.mjs", syntax="js") }}

Reconnect is an app decision in Roc. A pure generator seeded from
`boot.seed` chooses jitter up to a quarter of bases of 1, 2, 4, 8 and 16
seconds. After five failed retries the app gives up. A `Waiting` branch
owns a timer; leaving that branch cancels it. A refused timer gives up
instead of retrying into a full in-flight table.

{{ sample(file="port-recipes/Sockets.roc", region="reconnect") }}

The connection input snapshots the resume cursor only when a connection
opens. Receiving a new event changes the last-kept cursor without reopening
the current connection. A forward jump reports the sequence gap as well as
the handler's drop count; these can describe the same missing readings and
are not added together. The Status Page also disposes its connection and
retry timer while hidden, and demonstrates bounded replay and counted gaps.

{{ sample(file="port-recipes/specs/sockets.scm", syntax="scheme") }}

## IndexedDB

The [Ports guide](@/docs/ports.md) contains the complete notes recipe:
[typed declarations](@/docs/ports.md#three-shapes), its
[IndexedDB handlers](@/docs/ports.md#the-javascript-side), and a
[fake-store spec](@/docs/ports.md#testing). The
[Reading List](@/examples/reading-list.md) adds cross-tab updates and shows
how optimistic commands and a `Latest` store subscription agree. Use a call
for a write whose failure the reader must hear; a command cannot acknowledge
that write.

## Notifications

Permission is a gesture-driven call answering `Granted`, `Denied` or
`Dismissed`. Showing a notification is a command. An app that must report a
failure to show one should make that operation a call instead. The handler
keeps at most one permission request pending.

{{ sample(file="port-recipes/Notifications.roc", region="declaration") }}

{{ sample(file="port-recipes/notifications.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/notifications.scm", syntax="scheme") }}

## Web Share

Start `navigator.share` in the click's turn. User cancellation answers
`Cancelled`; successful completion answers `Shared`. Other rejections remain
port failures. The native sheet cannot be aborted, so the handler keeps one
pending operation until it settles and refuses a second. Aborting the call
stops delivery of its answer, rather than pretending to close the sheet.

{{ sample(file="port-recipes/Share.roc", region="declaration") }}

{{ sample(file="port-recipes/share.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/share.scm", syntax="scheme") }}

## Reading the clipboard

Reading the clipboard needs permission and may need a gesture. It is a
call returning text or a port failure; the handler never keeps a second
pending read. Writing the clipboard uses the platform's
[`Clipboard.text` and `Clipboard.html`](@/docs/effects-and-browser.md#copying-and-pasting-text),
and text the user pastes arrives through `Html.on_paste_text`.

{{ sample(file="port-recipes/ClipboardRead.roc", region="declaration") }}

{{ sample(file="port-recipes/clipboard-read.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/clipboard-read.scm", syntax="scheme") }}

## Geolocation

A call asks for one fix; a `Latest` subscription follows the newest one.
Both handlers use a watch so abort and unsubscribe can call `clearWatch`.
The one-fix call clears its watch as soon as it answers or fails. The
subscription reports only plain coordinates and accuracy, never a browser
object. Permission denial ends it with `Threw`.

{{ sample(file="port-recipes/Geolocation.roc", region="declaration") }}

{{ sample(file="port-recipes/geolocation.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/geolocation.scm", syntax="scheme") }}

## Media capture

A `Latest` subscription reports `Starting`, `Active` or `Ended`. The
`recipe-camera` custom element owns the stream and preview in its shadow
root. Roc receives only device state. Unsubscribe stops every track; if a
permission request completes after abort, its late stream is stopped too.
There is at most one pending device request and one live stream. Removing
the element also releases both its preview and any eventual late stream.

{{ sample(file="port-recipes/Media.roc", region="declaration") }}

{{ sample(file="port-recipes/media.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/media.scm", syntax="scheme") }}

## Fullscreen and wake lock

Commands ask, state subscriptions report what the browser actually did.
Request fullscreen in the click's turn. Wake lock availability also depends
on the browser, permission and visibility. A release is reported; this
handler does not decide to reacquire it. The app must choose whether and
when to send another command. One pending acquisition and one held sentinel
bound the handler, and teardown releases it.

{{ sample(file="port-recipes/Display.roc", region="declaration") }}

{{ sample(file="port-recipes/display.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/display.scm", syntax="scheme") }}

## Browser locale formatting

Simple date patterns can be pure Roc. When the app needs the browser's CLDR
formatting, send a batch of instants, `boot.languages` and the chosen zone
through a call, and render the answered strings. No hole calls `Intl`
synchronously. This sample explicitly chooses UTC when boot has no zone
name; the handler never guesses a replacement for an invalid zone or locale.

I64 milliseconds cross as decimal strings. The handler checks the exact
integer against the browser's date range before converting it to a Number,
and refuses a batch of more than 256 dates. A date outside that range is
a failure, rather than a rounded or substituted instant.

{{ sample(file="port-recipes/Dates.roc", region="declaration") }}

{{ sample(file="port-recipes/dates.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/dates.scm", syntax="scheme") }}

## Canvas drawing belongs to an element

Canvas drawing needs no port. Roc renders a custom element with ordinary
attributes; that element owns its canvas and animation frame. Disconnecting
it cancels the frame. The app decides whether reduced motion disables the
animation, using its declared boot media query. No per-frame callbacks enter
Roc, and the JavaScript makes no reactive decisions.

{{ sample(file="port-recipes/Canvas.roc", region="element") }}

{{ sample(file="port-recipes/gauge.mjs", syntax="js") }}

{{ sample(file="port-recipes/specs/canvas.scm", syntax="scheme") }}

## What the specs prove

These specs use the same fake-port steps natively and in Chrome. They prove
what the Roc app sends, how it handles answers, and when subscriptions go
away. They do not exercise browser permission prompts or a real socket
server. Test handlers against their actual services too; the recipe's
handler tests cover cleanup, bounded queues and late browser answers
without showing permission prompts in the spec runner.
