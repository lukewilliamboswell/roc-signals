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
}
