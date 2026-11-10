## Host services for the native spec runner (`roc build --target=x64musl`
## of an app): it reads `.scm` files and reports one JSON line per spec.
##
## They are served by the native host, `host/spec.zig`. The browser module
## never calls them, and the Wasm link drops them. A failed read or write ends
## the process with a message: a runner that cannot read its input or report
## its result has nothing correct left to do.
Cli := [].{

	## The bytes of the file at `path`. A file that cannot be read ends the
	## process with exit code 2 and a message naming the path.
	read_file! : Str => List(U8)

	## Whether `path` names a readable regular file.
	file_exists! : Str => Bool

	## Write text to standard output, unbuffered.
	stdout! : Str => {}

	## Write text to standard error, unbuffered.
	stderr! : Str => {}

	## Monotonic time in nanoseconds, for the `duration_ns` of a result.
	now_ns! : () => U64

	## Run one worker job (`name:str input:rest`) in a child process, as a
	## browser runs it in a Web Worker, and return the result payload the
	## runtime would deliver (design.md, Appendix B): tag 10 and the program's
	## output, or tag 11 and the fault class when the program's instance
	## faulted. The child's crash ends only the child. An empty list means the
	## job did not finish within the runner's bound (30 s) and was killed.
	##
	## `files` are the bytes of the files the job names, which the child
	## passes beside the payload, as a worker's host passes the files it read.
	work! : List(U8), List(List(U8)) => List(U8)

	## Mint up to `n` file handles in the host's handle heap, as the page's
	## host does for an event's files: fewer when the heap is nearly full.
	## Each is a `Box(U64)` whose last release the host observes.
	mint_files! : U64 => List(Box(U64))

	## How many file handles are live in the host's heap, after letting go of
	## those Roc has released since the last call.
	live_files! : () => U64

	## The SHA-256 digest of `bytes` (32 bytes), as the browser's WebCrypto
	## computes it for a file's digest, so a spec gets the same digest in
	## both runners.
	sha256! : List(U8) => List(U8)
}
