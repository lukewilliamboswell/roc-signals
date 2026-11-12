## A value only the engine can make.
##
## An exposed type sometimes has to offer the engine an operation that an
## app must not call. A table is the case: its cell gives the table its
## identity and clears its record when a turn ends, and an app that gave
## another table that identity would pass it off as the cell's own, leaving
## every view of the cell showing rows the table no longer has. Roc has no
## visibility between a module's own and everyone's, so such an operation
## takes an `EngineOnly` as its last argument. The type is opaque and this
## module is not one the platform exposes, so an app can neither build the
## value nor name the function that gives it: the operation is listed with
## its type, and an app cannot call it.
EngineOnly :: [Engine].{

	## The value. Only a module of the platform can name this function.
	witness : {} -> EngineOnly
	witness = |_| Engine
}
