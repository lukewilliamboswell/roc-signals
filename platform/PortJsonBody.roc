import Engine

## The transparent bodies behind PortJson's opaque codec states, in a
## module the platform does not expose, so an application can neither name
## them nor build an encoder state from one. `PortJson` wraps each in its
## opaque type rather than making Out or Entries an opaque record holding a
## file, which loses its unique hold on its lists
## (https://github.com/roc-lang/roc/issues/13081). The reader's State uses a
## private box around its body to preserve unique name-set ownership; its
## separate cursor-copying defect also reproduces without files.
PortJsonBody := [].{

	## The reader's cursor, attachment lists, container depth, null-record
	## flag and only the decoded names of its currently open dictionaries.
	State := { text : List(U8), pos : U64, blobs : List(List(U8)), files : List(Engine.File), depth : U64, null_record : Bool, dicts : DictKeys }

	## Only dictionaries push a frame. Recording a key edits the innermost
	## set without touching the boxed outer frames; records, arrays and tags
	## move them unchanged. Retained decoded names occupy at most the input's
	## key bytes, and at most 512 dictionaries can be open. Closing one releases
	## its set; any error drops every remaining frame with the cursor.
	DictKeys := [Outside, Inside({ names : Set(Str), outer : Box(DictKeys) })]

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
