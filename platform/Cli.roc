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

	## Run one worker job in a child process, as a browser runs it in a Web
	## Worker (design.md, "Workers"). The child mints a handle for each file
	## of `prepare_files` and runs the preparation `prepare` (`prep:str
	## init:rest`) on them when it is not empty, then mints a handle for each
	## file of `files` and runs the job `payload` (`name:str input:rest`):
	## on the prepared state, or as a task of its own when there is none.
	## Each file is the whole file the request names, and the child performs
	## the job's hosted effects against those bytes and builders of its own,
	## which may append at most `max_output` bytes. A builder the preparation
	## opened is closed when it returns, as in the browser.
	##
	## The result is the runner's own record of the answer: tag 10, `n:u32
	## (size:u64 name:str type:str)*`, the output's length (`u64`) and bytes,
	## then each answer file's bytes in order; or tag 11 and the fault class
	## when the job's instance faulted; or empty when the job did not finish
	## within the runner's bound (30 s). The child's crash ends only the
	## child.
	work! : List(U8), List(List(U8)), List(U8), List(List(U8)), U64 => List(U8)

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
