## The hosted functions a worker task calls (design.md, "Workers"): the
## platform's closed vocabulary of synchronous effects on handles. They are
## not an app-extensible import table, and apps never call them directly:
## `File` and `Builder` wrap them as `!` methods, and decide every verdict
## from the facts these report.
##
## Each one is bound in both platform roots: the Wasm host (`host/host.zig`)
## performs it through an import of the worker script, which owns the
## browser objects behind the tokens, and the native spec host
## (`host/spec.zig`) performs it in a job's child process against the files
## a spec declares. A module that never reaches them imports nothing. Both
## hosts refuse every one of them outside a job (a task's `run!`, or a
## preparation's `prepare!`), with a classified contract error: page code
## is pure and cannot call them. The `append!`, `append_file!` and
## `finish!` statuses are 0 done, 1 over the job's output bound (`append!`
## only), 2 not an open builder, and 3 a builder the call that opened it
## has left behind.
##
## A token names a handle in the instance's own heap; it is read from a
## `Box(U64)` the caller holds for the length of the call, so the handle
## cannot be released during it.
Hosted := [].{

	## The `len` bytes at `start` of the file behind `token`: exactly `len`
	## bytes, or none when the browser can no longer read the file. The list
	## is fresh and owned by Roc.
	read! : U64, U64, U64 => List(U8)

	## The size in bytes of the file behind `token` (a file the job was
	## sent, or one a builder finished).
	size! : U64 => U64

	## A fresh handle in the instance's heap, with no object behind it yet:
	## `open!` makes it a builder and `finish!` a file. More live handles than
	## the heap holds is a `resource_limit` fault of the job's instance.
	mint! : () => Box(U64)

	## Make the handle `token` a builder of a file named `name` (UTF-8) of
	## media type `mime`, starting with the range `start`, `len` of the file
	## behind `from` (by reference, no copy), or empty when `from` is 0.
	## Answers 0.
	open! : U64, List(U8), List(U8), U64, U64, U64 => U8

	## Append a copy of `bytes` to the builder `token`. Answers 0 when it
	## did, 1 when the job's output would exceed its bound (nothing was
	## appended), 2 when `token` is not an open builder, 3 when the call that
	## opened it has returned.
	append! : U64, List(U8) => U8

	## Append the range `start`, `len` of the file behind `file` to the
	## builder `token`, by reference. Answers as `append!`, never 1.
	append_file! : U64, U64, U64, U64 => U8

	## Finish the builder `token` into an immutable file behind the fresh
	## handle `file` (from `mint!`). Answers 0, 2 when `token` is not an
	## open builder, or 3 when the call that opened it has returned. A
	## finished builder takes nothing more.
	finish! : U64, U64 => U8
}
