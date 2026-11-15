import Engine

## The transparent bodies behind `PortJson.Out` and `PortJson.Entries`, in a
## module the platform does not expose, so an application can neither name
## them nor build an encoder state from one. `PortJson` wraps each in its
## opaque type rather than making the opaque type a record itself, because an
## opaque record holding a file loses its unique hold on its lists
## (https://github.com/roc-lang/roc/issues/13081).
PortJsonBody := [].{

	## The body of `PortJson.Out`: JSON text so far, the blobs and files it
	## has written, how many containers enclose what it writes next, and
	## whether a container was met at the nesting bound, which makes the
	## encode a refusal.
	Out := { text : List(U8), blobs : List(List(U8)), files : List(Engine.File), depth : U64, over : Bool }

	## The body of `PortJson.Entries`: each entry's key and value text, the
	## blobs and files written so far, and whether a container in it was met
	## at the nesting bound.
	Entries := { items : List((List(U8), List(U8))), blobs : List(List(U8)), files : List(Engine.File), over : Bool }
}
