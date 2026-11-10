+++
title = "Files"
description = "Take a file the user chooses, drops or pastes, keep it as a handle, act on it where the browser keeps it, and read its bytes in a worker or, for a small file, on the page."
weight = 11
template = "page.html"
+++

# Files

A user gives your app a file by choosing it in a file input, dropping it on
the page or pasting it. The app receives a `File`: a handle with the file's
name, size and type. It does not receive the bytes on the page: the
browser keeps the file, and the app decides what crosses into its memory.

That is what makes a large file practical. A 64 MiB document never enters the
page's memory unless the app asks for it there: the app can upload it, digest
it or show it where the browser keeps it, and a worker reads it once into
its own memory, so the program gets those bytes without a copy.

## Which tool

| You want to | Use | The bytes |
|---|---|---|
| Upload it, digest it, or preview it in an `<img>` or `<video>` | An operation on the file: `File.upload`, `File.sha256`, `File.object_url` | Never enter the page's memory |
| Process it: parse, convert, search, count | A [worker program](#reading-a-file-in-a-worker) that is sent the file and calls `File.contents` | Read once into the worker, off the page's thread |
| Read a small file in a simple app | A page read: `file.read_bytes({})`, `file.read_utf8({})` | Read on the page's thread and copied into the page's memory |
| Read a large file a chunk at a time, or produce a new file to save or send on | A [task](@/docs/files-in-tasks.md): `file.read!` and `File.build!` in a worker | Read range by range into the worker; a new file never enters the page's memory |
| Download a file, or save one | [`File.fetch`](@/docs/files-in-tasks.md#downloading-into-a-file) and [`File.save`](@/docs/files-in-tasks.md#saving) | Stay in the browser |

This answers two older workarounds. Getting a file's bytes into Roc used to
mean a custom element that read the file, base64-encoded it into an input's
value and dispatched `change`, so the page decoded megabytes of base64 in a
handler; now the file arrives as a handle, a worker reads its bytes, and a
small one can be read on the page as bytes, not text. Sending a file on used
to mean building a `data:` URL; an upload now sends the file itself, and a
preview is an object URL the browser serves from the file.

## Receiving files

`State.on_files` makes a handler for the files an event carries. Its reducer
receives them and how many there were beyond what the app can hold at once:

{{ sample(file="files/Upload.roc", region="state") }}

Attach it to a file input with `Html.file_input`, to a drop target with
`Html.on_drop_files`, or to a paste target with `Html.on_paste_files`:

{{ sample(file="files/Upload.roc", region="view") }}

`Html.file_input` takes a props record: `{}` for one file of any type,
`selection: Multiple` to let the user choose several at once, and
`accept: Types(".txt,text/plain")` for the types its chooser offers first.
The browser opens its own chooser when the user clicks the file input, so
there is nothing to set up for permissions. A drop target lets a dropped
file land there instead of the browser opening it.

## How long a file lasts

A `File` is an ordinary value. Keep it in a state, put it in a list, compare
it, or take a range of it with `File.slice`. It stays available as long as
some value holds it, and the app lets it go when nothing does: write the
state without it, or let the scope holding that state be disposed.

Two things hold a file longer than you might expect:

- A slice of a list (`take_first`, `drop_first`, `sublist`) keeps the whole
  list's files alive. To keep some files and let the rest go, build a new
  list of the ones you keep.
- A `derive` or `Worker.derive` layer keeps its last input, so a file it was
  asked about stays until its input changes.

An app holds at most 64 files at once. Files an event carries beyond that are
not delivered; `refused` counts them, so the app can say so.

## Reading a file in a worker

A worker program's input can hold files, like any other value. In the
program, `File.contents` gives the bytes of the file or of its range:

{{ sample(file="files/Upload.roc", region="program") }}

The page sends only the file's handle. The runtime hands the browser's file
to the worker, which reads it into its own memory before the program runs.
For text, `File.contents_utf8` gives `Err(InvalidUtf8)` when the bytes are
not UTF-8. Calling `File.contents` on the page is a contract error: there
are no bytes there until the app asks for them with a read.

A job whose files cannot be read fails before the program starts, and the
worker survives:

| What happened | `Worker.Error` |
|---|---|
| The file changed or was deleted since the user chose it | `FileFailed(Unreadable)` |
| More than 16 files, or more bytes than `maxFileBytes` (256 MiB unless the mount sets it) | `FileFailed(TooLarge)` |

To read part of a large file, send a range: `file.slice({ start, len })`
reads only those bytes.

## Acting on a file where it lives

An operation on a file is a request, made in an effect site's plan like any
other, which the runtime performs on the browser's own file:

{{ sample(file="file-tools/Tools.roc", region="requests") }}

- `file.upload({ url })` sends the file, or a range of it, as an HTTP
  request's body. `method` (`"POST"` unless you say), `headers` (none) and
  `timeout` (`Unlimited`, or `Ms(ms)`) are optional. The browser streams it
  from the file. Read the answer with `http_text`, as for any HTTP request; like
  one, it is still answered when the site that made it is disposed. A file
  the browser can no longer read fails it as a network failure.
- `File.sha256(file)` answers the SHA-256 digest, 32 bytes, with
  `file_digest`. The browser reads the range into a buffer of its own, not
  the page's memory; more than `maxFileBytes` is `TooLarge`, and a page
  outside a secure context (plain HTTP from another host than localhost)
  has no WebCrypto and answers `Unavailable`.
- `File.object_url(file)` answers a URL for an `<img>`'s or a `<video>`'s
  `src`, with `file_url`. The URL works exactly as long as some value holds
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
and read the answer with `file_bytes` or `file_text`. It is a request, not a
value, because the bytes are not on the page until the browser has read
them. Its cost is honest: the browser reads the file into a buffer on the
page's thread, and the bytes are copied once into the page's memory, where
they stay while the app keeps them.

A read accepts 8 MiB unless the app says otherwise:
`file.read_bytes({ max_bytes: 32 * 1024 * 1024 })`. A larger file or range is
`TooLarge` and is not read. The page's `maxFileBytes` mount option (256 MiB
by default) caps every read whatever it asks, so a deployment can keep the
page's memory smaller than an app would like; send larger files to a
worker.

| What happened | `FileError` |
|---|---|
| The file changed or was deleted since the user chose it | `Unreadable` |
| More bytes than the operation reads | `TooLarge` |
| Text was asked for and the bytes are not UTF-8 | `InvalidUtf8` |
| The browser cannot do it (a digest without WebCrypto) | `Unavailable` |
| Too many requests were in flight | `Refused` |

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
