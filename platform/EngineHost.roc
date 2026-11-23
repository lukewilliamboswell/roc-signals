import Core
import Engine

## Turn entry points for a platform that supplies its own host. Pass
## wire records for the declared protocol version and apply the returned
## command batch only after the call succeeds.
EngineHost := [].{

	## The engine instance. Move it into each turn and keep only the returned instance.
	App(st) : Core.App(st)

	## The site tree, separate from the store while a platform holds its opaque box.
	Sites(st) : Core.Sites(st)

	## A worker's prepared state, held by a worker instance between jobs.
	Kept : Core.Kept

	## The closed set of hosted operations for a worker job. Each operation
	## must refuse outside its job. A platform supplies these as callbacks.
	JobEffects : Core.JobEffects

	## The file builder's name, media type and optional source file.
	BuildProps : Core.BuildProps

	## Move the store and sites into the platform's opaque handle.
	split : App(st) -> (st, Sites(st))
	split = Core.split

	## Reunite the store and sites after the host returns the handle.
	join : st, Sites(st) -> App(st)
	join = Core.join

	## The declarations are the engine's sections before any platform-specific
	## declaration sections. Each turn returns the instance, command bytes and
	## work bytes in that order. Move the previous command and work buffers
	## into the next turn for reuse. Teardown releases the state and buffers in Roc.
	Driver(st) : {
		version : U32,
		keys : () -> List(U8),
		init : List(U8) -> (App(st), List(U8), List(U8)),
		event : App(st), List(U8), List(U8), U32, U32, List(U8) -> (App(st), List(U8), List(U8)),
		files : App(st), List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (App(st), List(U8), List(U8)),
		key : App(st), List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (App(st), List(U8), List(U8)),
	}

	## Bind the host's ingress to the app's program without mounting it.
	driver : Engine.Program(st) -> Driver(st)
	driver = |program| {
		{ version, keys, init, event, files, key, .. } = Core.driver(program)
		{ version, keys, init, event, files, key }
	}

	## Run a registered job with its payload and freshly minted file handles.
	work! : Engine.Program(st), JobEffects, List(U8), List(Box(U64)) => List(U8)
	work! = Core.work!

	## Prepare a worker's state from its input and files.
	work_prepare! : Engine.Program(st), JobEffects, List(U8), List(Box(U64)) => Kept
	work_prepare! = Core.work_prepare!

	## Run a task of the held preparation. The platform returns the same
	## prepared state to the worker host with the answer.
	work_ask! : Kept, List(U8), List(Box(U64)) => List(U8)
	work_ask! = Core.work_ask!

	## Open a builder in the current job using the platform's hosted operations.
	open_builder! : JobEffects, BuildProps => Engine.Builder
	open_builder! = Core.open_builder!
}
