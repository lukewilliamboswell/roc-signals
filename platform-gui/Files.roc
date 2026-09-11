## Native file dialogs and bounded filesystem work as effectful functions,
## called from an action's effect. Paths are absolute UTF-8 strings of at most
## 4096 bytes. A chooser blocks the effect until the user answers; at most 16
## native operations may be retained, and saturation returns ResourceLimit.
Files := [].{
	Choice := [Canceled, Chosen(Str)].{
		is_eq : _
	}
	Error := [
		Canceled,
		NotFound(Str),
		PermissionDenied(Str),
		InvalidUtf8(Str),
		InvalidPath(Str),
		ResourceLimit(Str),
		Io(Str),
		Unavailable(Str),
	].{
		is_eq : _
	}
	Kind := [File, Directory, SymbolicLink, Other].{
		is_eq : _
	}
	TextFile : { path : Str, text : Str }
	Written : { path : Str, bytes : U64 }
	Entry : { path : Str, kind : Kind, bytes : U64 }
	Scan : { root : Str, entries : List(Entry) }
	Directory : { path : Str, entries : List(Entry) }
	Opened : { path : Str }
	Preview : { path : Str, text : Str, truncated : Bool }
	LogCursor : { device : U64, inode : U64, offset : U64 }
	LogPosition := [Start, End, After(LogCursor)].{
		is_eq : _
	}
	LogChange := [Initial, Continued, Rotated, Truncated].{
		is_eq : _
	}
	LogState := [More, AtEnd, PartialUtf8].{
		is_eq : _
	}
	LogChunk : { path : Str, text : Str, cursor : LogCursor, change : LogChange, state : LogState }
	SaveOptions : { directory : [Home, At(Str)], suggested_name : Str }
	AssetStatus := [Ok, Missing, Mismatch].{
		is_eq : _
	}
	AssetEntry : { name : Str, sha256 : Str }
	AssetCheck : { name : Str, status : AssetStatus }

	## Open the platform's single-file chooser and wait for the user's answer.
	## Dismissing the dialog is the successful `Canceled` choice.
	choose_file! : () => Try(Choice, Error)

	## Open the platform's single-folder chooser and wait for the user's answer.
	choose_directory! : () => Try(Choice, Error)

	## Ask for a save path at the user's home or an absolute initial directory
	## and wait for the user's answer. Home returns Unavailable if the native
	## environment has no UTF-8 HOME value. The suggestion is one nonempty file
	## name of at most 255 UTF-8 bytes.
	choose_save_path! : SaveOptions => Try(Choice, Error)

	## Read a complete UTF-8 file of at most one MiB.
	read_text! : Str => Try(TextFile, Error)

	## Write the text through a temporary file and an atomic rename; at most one
	## MiB. Replacement is atomic, but parent-directory durability across power
	## loss is not guaranteed.
	write_text! : { path : Str, text : Str } => Try(Written, Error)

	## Scan a folder recursively: at most 10,000 entries and 64 levels, symlinks
	## reported but never traversed, four MiB of paths including the root.
	scan! : Str => Try(Scan, Error)

	## List a folder's direct children.
	list_directory! : Str => Try(Directory, Error)

	## Hand a regular file to its associated application.
	open_path! : Str => Try(Opened, Error)

	## Read a bounded text preview; the result reports truncation.
	read_preview! : Str => Try(Preview, Error)

	## Read the next chunk of a log from a position: at most 64 KiB, with the
	## cursor to continue from and whether the file was rotated or truncated.
	read_log! : { path : Str, position : LogPosition } => Try(LogChunk, Error)

	## Verify a manifest of 1 to 256 assets against the host's assets root.
	verify_assets! : List(AssetEntry) => Try(List(AssetCheck), Error)

	## Describe a native failure without losing its typed case.
	error_text : Error -> Str
	error_text = |error| match error {
		Canceled => "Canceled"
		NotFound(path) => "Not found: ${path}"
		PermissionDenied(path) => "Permission denied: ${path}"
		InvalidUtf8(path) => "Not valid UTF-8: ${path}"
		InvalidPath(path) => "Invalid path: ${path}"
		ResourceLimit(detail) => "Resource limit: ${detail}"
		Io(detail) => "File operation failed: ${detail}"
		Unavailable(detail) => "Native service unavailable: ${detail}"
	}
}
