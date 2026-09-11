import Document
import pf.Action exposing [Action]
import pf.Files
import pf.Ui
import Session

## Each document operation is one effect started by the handler that began
## it: opening chooses a file and reads it, saving chooses a destination when
## it needs one and writes the draft it was given. A chooser blocks the effect
## until the user answers, and an operation the session did not start runs
## nothing.
Workflow := [].{
	## Open a document: the chooser, then the read, as one effect. The result
	## installs the decoded text under a fresh lifetime in the same commit.
	open! : Ui.State(Session.State), Session.Phase => Action(a)
	open! = |session, phase| {
		if phase != Busy(Opening) {
			return Action.none
		}
		match Files.choose_file!() {
			Err(error) => failed(session, error)
			Ok(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
			Ok(Files.Choice.Chosen(path)) => match Files.read_text!(path) {
				Ok(file) => Action.update([session.write(|state| Session.loaded(state, file))])
				Err(error) => failed(session, error)
			}
		}
	}

	## Save the body as it was when the save began, spelled the way the file
	## was: the session's format encodes line endings and a byte-order mark.
	save! : Ui.State(Session.State), Session.State, Bool => Action(a)
	save! = |session, state, save_as| {
		if state.phase != Busy(Saving) {
			return Action.none
		}
		destination = match state.path {
			Some(path) if !save_as => Ok(Files.Choice.Chosen(path))
			_ => Files.choose_save_path!({
				directory: match state.path {
					None => Home
					Some(path) => save_directory(path)
				},
				suggested_name: match state.path {
					None => "Untitled note.txt"
					Some(path) => Session.file_name(path)
				},
			})
		}
		match destination {
			Err(error) => failed(session, error)
			Ok(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
			Ok(Files.Choice.Chosen(path)) => match Files.write_text!({ path, text: Document.encode(state.body, state.format) }) {
				Ok(_) => Action.update([session.write(|current| Session.written(current, { path, body: state.body }))])
				Err(error) => failed(session, error)
			}
		}
	}

	cancel : Ui.State(Session.State), Session.Phase -> Action(a)
	cancel = |session, phase| match phase {
		Session.Phase.ConfirmDiscard(_) => Action.update([session.write(Session.cancel)])
		_ => Action.none
	}

	## Reopen the save dialog beside the document's current file. The parent is
	## taken through the typed `Files.Path` boundary, so a Windows path keeps its
	## own root and separators; a path with no parent falls back to the home
	## directory rather than naming a root the operating system may not have.
	save_directory : Str -> [Home, At(Str)]
	save_directory = |path| {
		parent = Files.parse_path(path).parent().to_str()
		if parent.is_empty() {
			Home
		} else {
			At(parent)
		}
	}

	failed : Ui.State(Session.State), Files.Error -> Action(a)
	failed = |session, error| Action.update([session.write(|state| Session.failed(state, Files.error_text(error)))])
}

expect {
	Workflow.save_directory("C:\\Users\\Lee\\Ideas.txt") == At("C:\\Users\\Lee") and
	Workflow.save_directory("/home/lee/ideas.txt") == At("/home/lee") and
	Session.file_name("C:\\Users\\Lee\\Ideas.txt") == "Ideas.txt"
}
