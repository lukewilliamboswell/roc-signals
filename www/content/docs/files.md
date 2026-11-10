+++
title = "Files"
description = "Take a file the user chooses, drops or pastes, keep it as a handle, and read its bytes in a worker without ever copying them through the page."
weight = 11
template = "page.html"
+++

# Files

A user gives your app a file by choosing it in a file input, dropping it on
the page or pasting it. The app receives a `File`: a handle with the file's
name, size and type. It never receives the bytes on the page. To read them,
send the file to a [worker](@/docs/workers.md) program, which reads them
there.

That is what makes a large file practical. A 64 MiB document never enters the
page's memory: the browser keeps the file, the worker reads it once into its
own memory, and the program gets those bytes without a copy. The page stays
responsive while the worker reads.

## Receiving files

`State.on_files` makes a handler for the files an event carries. Its reducer
receives them and how many there were beyond what the app can hold at once:

{{ sample(file="files/Upload.roc", region="state") }}

Attach it to a file input with `Html.file_input`, to a drop target with
`Html.on_drop_files`, or to a paste target with `Html.on_paste_files`:

{{ sample(file="files/Upload.roc", region="view") }}

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
Reading a file's contents on the page is a contract error: there are no
bytes there.

A run whose files cannot be read fails before the program starts, and the
worker survives:

| What happened | `Worker.Error` |
|---|---|
| The file changed or was deleted since the user chose it | `FileFailed(Unreadable)` |
| More than 16 files, or more bytes than `maxFileBytes` (256 MiB unless the mount sets it) | `FileFailed(TooLarge)` |

To read part of a large file, send a range: `file.slice({ start, len })`
reads only those bytes.

## Testing

Specs declare the files they give the app, with their contents written out,
so both runners give it the same bytes:

{{ sample(file="files/specs/count.scm", syntax="scheme") }}

`(file NAME TYPE TEXT [REPEAT])` declares a file whose contents are `TEXT`
repeated; `choose-files`, `drop-files` and `paste-files` give the app named
files; `expect-files N` checks how many files the app holds. In Chrome a
chosen file must get the type the spec declares, which the browser decides
from the file's name.
