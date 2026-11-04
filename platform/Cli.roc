## Host services for command-line targets (`Target.cli`): the spec runner
## reads `.scm` files and reports one JSON line per spec.
##
## These are a roc-signals addition to the roc-fuzz platform. They are served
## by `host/cli.zig`, which is linked into every executable built against this
## platform, fuzz targets included. A failed read or write ends the process
## with a message: a runner that cannot read its input or report its result
## has nothing correct left to do.
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
