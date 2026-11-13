+++
title = "Files"
description = "Take a file the user chooses, drops or pastes, keep it as a handle, act on it where the browser keeps it, and read its bytes in a worker task's job or, for a small file, on the page."
weight = 13
template = "page.html"
+++

# Files

A user gives your app a file by choosing it in a file input, dropping it on
the page or pasting it. The app receives a `File`: a handle with the file's
name, size and type. It does not receive the bytes on the page: the
browser keeps the file, and the app decides what crosses into its memory.

That is what makes a large file practical. A 64 MiB document never enters the
page's memory unless the app asks for it there: the app can upload it, digest
it or show it where the browser keeps it, and a worker task's job reads the
ranges it needs straight into the worker's memory.

## Which tool

| You want to | Use | The bytes |
|---|---|---|
| Upload it, digest it, or preview it in an `<img>` or `<video>` | An operation on the file: `File.upload`, `File.sha256`, `File.object_url` | Never enter the page's memory |
| Process it: parse, convert, search, count | A [worker task](#reading-a-file-in-a-worker) that is sent the file and reads it with `file.contents!` or `file.read!` | Read into the worker, off the page's thread, as much as the job asks for |
| Read a small file in a simple app | A page read: `file.read_bytes({})`, `file.read_utf8({})` | Read on the page's thread and copied into the page's memory |
| Produce a new file to save or send on | A task whose job writes it with `Files.build!` (see [Files in Tasks](@/docs/files-in-tasks.md)) | Built in the worker; the new file never enters the page's memory |
| Download a file, or save one | [`File.fetch`](@/docs/files-in-tasks.md#downloading-into-a-file) and [`File.save`](@/docs/files-in-tasks.md#saving) | Stay in the browser |

## Receiving files

`State.set_value` makes a handler for the files an event carries. Its reducer
receives them and how many there were beyond what the app can hold at once:

{{ sample(file="files/Upload.roc", region="state") }}

Attach it to a file input with `Html.file_input`, to a drop target with
`Html.on_drop_files`, or to a paste target with `Html.on_paste_files`:

{{ sample(file="files/Upload.roc", region="view") }}

A reducer writes one state. When the files belong in the store, or one
drop must write several cells that agree, the handler is a decision:
`Engine.handle(decide)` gives `decide` the same `Received` and
applies the list of writes it returns, and `Engine.handle_by(v,
decide)` also gives it the value `v` holds when the files arrive
([Shared State](@/docs/shared-state.md#decisions)). `first.also(second)`
makes one handler of two, so a drop can write local state and run a
decision as one event.

`Html.file_input` takes a props record: `{}` for one file of any type,
`selection: Multiple` to let the user choose several at once, and
`accept: Types(".txt,text/plain")` for the types its chooser offers first.
The browser opens its own chooser when the user clicks the file input, so
there is nothing to set up for permissions. A drop target lets a dropped
file land there instead of the browser opening it.

The handler family is generic over its payload: `FilesHandler(ctx)` is
`HandlerOf(ctx, Received)`, made with the same reducers, decisions and
`also` as a text handler. Attaching a files handler to a text event is a
compile error. For a raw element, `Engine.on_files` takes `Change`, `Drop`
or `Paste`, so an event that cannot carry files cannot be selected.

## How long a file lasts

A `File` is an ordinary value. Keep it in a state, put it in a list, compare
it, or take a range of it with `File.slice`. It stays available as long as
some value holds it, and the app lets it go when nothing does: write the
state without it, or let the scope holding that state be disposed.

Several holders can keep a file longer than you might expect:

- A slice of a list (`take_first`, `drop_first`, `sublist`) keeps the whole
  list's files alive. To keep some files and let the rest go, build a new
  list of the ones you keep.
- A derived signal or worker resource keeps its last input, so a file it was
  asked about stays until its input changes, and its answer holds the
  files it names until the next answer. A request kept in state for an
  effect site holds its files the same way, until the state is written
  without it, and an outbox holds its last post's files until the next
  post.
- A table keeps earlier rows from its last writing turn. Removing a row
  containing a file can leave that file held in the changes until the next
  write of the table or disposal of its holder. Unrelated turns keep it,
  and it still counts against the file bound.

An app holds at most 64 files at once, counting the files a job answered
with and downloaded ones. Files an event carries beyond that are not
delivered; `Received.refused` counts them, so the app can say so. (This
count is not the `Refused` result, which means the in-flight bound turned a
request away.) A job whose answer holds more files than the page has room
for is `Lost(ResourceLimit)`, and a download, or a port's answer or message,
with no room is answered `TooLarge`; either way the page keeps the files it
held and receives none of the new ones.

## Reading a file in a worker

A [worker task](@/docs/workers.md)'s input can hold files, like any other
value. The page sends only the file's handle: the runtime hands the
browser's file to the worker, and nothing is read until the job asks. In
the job, reading is an effect:

{{ sample(file="files/Upload.roc", region="task") }}

`file.contents_utf8!()` reads the whole file, or the whole range of a
slice, as text; `file.contents!()` gives its bytes, and
`file.read!({ start, len })` reads one range, so a job can go through a
large file a chunk at a time and keep its memory to a chunk.
`file.spans(n)` gives those ranges, `n` bytes each and the last shorter,
so the loop is `for span in file.spans(n) { bytes = file.read!(span)? ... }`.
These are
effects, written with `!`, so they exist only in a job: page code is pure
and the compiler refuses one there. On the page there are no bytes until
the app asks for them with a page read (below).

Each read answers a `Try`, and its error is the task's to pass on:

| What happened | The effect answers | The page sees |
|---|---|---|
| The file changed or was deleted since the user chose it | `Err(Unreadable)` | `Failed(Unreadable)` when the task passes it on with `?` |
| Text was asked for and the bytes are not UTF-8 | `Err(InvalidUtf8)` | `Failed(InvalidUtf8)` |

The worker survives either way, and the job decides what to do: answer the
error, as the sample does, or try something else. Nothing is read before a
job starts, so no file is too large to send; how much a job holds at once
is up to the job. [Files in Tasks](@/docs/files-in-tasks.md) covers the
rest: building a new file, appending to one across jobs, saving and
downloading.

## Acting on a file where it lives

An operation on a file is a request, made in an effect site's plan like any
other, which the runtime performs on the browser's own file:

{{ sample(file="file-tools/Tools.roc", region="requests") }}

- `file.upload({ url })` sends the file, or a range of it, as an HTTP
  request's body. `method` (`"POST"` unless you say), `headers` (none) and
  `timeout` (`Unlimited`, or `Ms(ms)`) and `credentials` (`SameOrigin`, or
  `Include`) are optional. The browser streams it
  from the file. Its typed answer is the full response, including status,
  headers and text body. Map it when the app wants a particular status
  policy. Like HTTP, it is still answered when its site is disposed. A file
  the browser can no longer read fails it as a network failure.
  Attach a [progress handler](@/docs/effects-and-browser.md#transfer-progress)
  to its reaction to report sending counts. Cross-origin upload progress
  requires the server to answer a CORS preflight.
- `File.sha256(file)` answers `Ok(digest)`, 32 bytes. The browser reads the range into a buffer of its own, not
  the page's memory; more than `maxFileBytes` is `TooLarge`, and a page
  outside a secure context (plain HTTP from another host than localhost)
  has no WebCrypto and answers `Unavailable`.
- `File.object_url(file)` answers a URL for an `<img>`'s or a `<video>`'s
  `src`, delivered as `Ok(url)`. The URL works exactly as long as some value holds
  the file: keep the file beside the URL. Asking again for the same range
  answers the same URL; one file gives at most 16 ranges URLs.

Each answer is typed:

{{ sample(file="file-tools/Tools.roc", region="answers") }}

A request holds the browser's file until it is answered, so letting the
file go while a request is in flight is safe. Digests, URLs and reads are
cancelled when their site is disposed; an upload is kept.

## Reading a file on the page

For a small file in a simple app, bringing its bytes into the page is
acceptable: ask for them with `file.read_bytes({})` or `file.read_utf8({})`,
and receive `Try(List(U8), FileError)` or `Try(Str, FileError)` in the reaction. It is a request, not a
value, because the bytes are not on the page until the browser has read
them. Its cost is honest: the browser reads the file into a buffer on the
page's thread, and the bytes are copied once into the page's memory, where
they stay while the app keeps them.

A read accepts 8 MiB unless the app says otherwise:
`file.read_bytes({ max_bytes: 32 * 1024 * 1024 })`. A larger file or range is
`TooLarge` and is not read. The page's `maxFileBytes` mount option (256 MiB
by default) caps every page read whatever it asks, so a deployment can keep
the page's memory smaller than an app would like; send larger files to a
worker task. `maxFileBytes` is the page's ceiling only: it also bounds a
digest and a downloaded body, and never what a job reads in a worker.

| What happened | `FileError` |
|---|---|
| The file changed or was deleted since the user chose it | `Unreadable` |
| More bytes than the operation reads | `TooLarge` |
| Text was asked for and the bytes are not UTF-8 | `InvalidUtf8` |
| The browser cannot do it (a digest without WebCrypto) | `Unavailable` |
| Too many requests were in flight | `Refused` |

The effects a job calls on a file answer only what each can produce:
`read!` and `contents!` fail with `[Unreadable]`, `contents_utf8!` with
`[Unreadable, InvalidUtf8]`, and a builder's `append!` with `[TooLarge]`.
`?` widens each into the task's own error, which can be `FileError` or a
union of the app's own that names just these tags beside its others.

## Testing

Specs declare the files they give the app, with their contents written out,
so both runners give it the same bytes:

{{ sample(file="files/specs/count.scm", syntax="scheme") }}

`(file NAME TYPE TEXT [REPEAT])` declares a file whose contents are `TEXT`
repeated; `choose-files`, `drop-files` and `paste-files` give the app named
files; `expect-files N` checks how many files the app holds. In Chrome a
chosen file must get the type the spec declares, which the browser decides
from the file's name.

Operations on a file wait for `run-effect`. `expect-upload N NAME START LEN`
checks which file and range an upload sends, and a digest is computed for
real in both runners, so a spec asserts the digest itself:

{{ sample(file="file-tools/specs/tools.scm", syntax="scheme") }}
