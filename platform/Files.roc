import Core
import Effects

## Building a file in a worker task's job (design.md, "Workers"). A job
## reads the files it was sent, and writes to a builder, with methods
## (`file.read!(...)`, `out.append!(...)`, `out.finish!()`): those files
## and builders carry the job's effects. Opening a builder has no file to
## carry them, so it is the one effect a task calls through this module.
##
## `Files` is part of the platform alone. An app module that imports it
## builds for the browser and as the native spec runner, which serve the
## effects, but not into a fuzz target, which depends on the engine as a
## package: a target fuzzes such an app's pure parts instead.
Files := [].{

	## How a builder starts: the new file's `name`, its media `mime` type
	## (`Auto`: the type of the file it starts from, or none), and what it
	## starts with: nothing (`Empty`), or the bytes of a file the job holds
	## (`From(file)`), by reference, without copying them.
	BuildProps : Core.BuildProps

	## In a task's job: a new builder for a file the job writes. Append to
	## it with `append!` and `append_file!`, then `finish!` it into an
	## immutable file the job can return in its answer. The bytes it holds
	## are private to the job until its answer is delivered: a job that is
	## stopped, times out or fails leaves nothing anyone can see. A builder
	## never outlives the call that opened it (a job, or a preparation's
	## `prepare!`): one kept in a prepared state and used later is a
	## contract error. Keep the file it finishes instead.
	##
	## To append to the output of an earlier job, start from it:
	## `Files.build!({ name, start_from: From(previous) })` gives a new file
	## that is the previous one followed by what this job appends, and the
	## previous file is unchanged whatever happens to this job.
	build! : Core.BuildProps => Core.Builder
	build! = |props| Core.open_builder!(Effects.job, props)
}
