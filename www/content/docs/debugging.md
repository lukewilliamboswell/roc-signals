+++
title = "Debugging"
description = "Inspect a value in page code or a worker task with Roc’s dbg."
weight = 17
template = "page.html"
+++

# Debugging

Write `dbg` where the value matters. The browser prints its inspected text
on the page’s console after the call, prefixed with `[dbg]`. A string is quoted;
a record shows its fields. The compiler passes no expression or source location,
so include a label in the value:

{{ sample(file="debugging/Debugging.roc", region="add-one") }}

Clicking the sample’s button prints `[dbg] { at: "add_one", count: 0 }`.
The handler still returns 1. A reader’s `dbg` prints when that reader really
runs, including its first evaluation at mount. Printing is passive: a console
that throws disables printing for that mount, even after recovery, while the
app’s turn still completes.

## Tasks and faults

A worker job prints on the page’s console when its answer or fault arrives,
with `[dbg task "name"]` in place of `[dbg]`. A preparation’s text comes before
its task’s. A cancelled job allowed to finish still prints; its answer is
unwanted, but its observations are useful. A stopped, timed-out or lost worker
sends no text: ending it destroys the memory holding that text. While debugging,
give the task a longer timeout or exercise its function from an `expect`.

A call that traps retains what it said. Its text prints before the fault line,
and `onFault` receives `dbg: { dropped, entries: [{ text, bytes }] }`. `bytes`
is the full UTF-8 length before truncation. A fault after a call has returned
has `dbg: null`, since that call’s output already printed. `onWorkerFault`
likewise receives a reported failed job’s observations. These fields can contain
application values: consider what an error-reporting service forwards.

## Bounds

Each call retains its newest 4096 bytes of entries, with an eight-byte header
per entry, and at most 1024 bytes of one entry’s text. Truncation stops at a
Unicode code-point boundary and displays the full byte length. If a call fills
the buffer, older whole entries are dropped and a line says how many; the
U32 count saturates and says “at least” at its maximum. A job carries at most
two call buffers, one for preparation and one for the task.

The native spec runner prints every entry immediately. It mutes the speculative
reader evaluations of its settle check. A preparation prints for every native
job, since that runner prepares afresh, and only when Chrome actually prepares.
A `dbg` reached while constructing a top-level constant or checking the default
mount can print during compilation. Do not rely on a fixed number of declaration
evaluations in either runner. See [Testing](@/docs/testing.md) for these
observation differences.

## Before deploying

Remove every `dbg` from production code. Optimized builds keep it; the compiler
warns of each, and `signals.roc build` shows that warning. A shipped `dbg` prints
for every user unless the deployment passes `dbg: "off"` to
`mountRocEngineApp`. The default is `"console"`; another value refuses mount.
The init template does not infer whether it is deployed.

With `"off"`, values are neither read for printing nor put on faults. The first
call or completed job that ran a `dbg` logs one value-free informational line
explaining that this mount chose `dbg: "off"`; later ones log nothing. Turning
output off cannot remove formatting: Roc inspects the whole value before the
host sees it. The original probe measured about0.2ms to inspect1000 records in
an optimized build; that is illustrative, not a performance guarantee for your
value or machine. Avoid debugging large values in a frequently evaluated reader.
