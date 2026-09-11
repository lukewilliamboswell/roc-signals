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
	View : { state : Session.State, body : Str }

	open! : Ui.State(Session.State), Ui.State(Str), Session.Phase => Action(reads)
	open! = |session, body, phase| {
		if phase != Busy(Opening) {
			return Action.none
		}
		match Files.choose_file!() {
			Err(error) => failed(session, error)
			Ok(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
			Ok(Files.Choice.Chosen(path)) => match Files.read_text!(path) {
				Ok(file) => Action.update([
					body.set(file.text),
					session.write(|state| Session.loaded(state, file)),
				])
				Err(error) => failed(session, error)
			}
		}
	}

	## Saves the body the view held when the save began; the destination is
	## the document's path unless one must be chosen.
	save! : Ui.State(Session.State), View, Bool => Action(View)
	save! = |session, view, save_as| {
		if view.state.phase != Busy(Saving) {
			return Action.none
		}
		destination = match view.state.path {
			Some(path) if !save_as => Ok(Files.Choice.Chosen(path))
			_ => Files.choose_save_path!({
				directory: match view.state.path {
					None => Home
					Some(path) => At(parent_path(path))
				},
				suggested_name: match view.state.path {
					None => "Untitled note.txt"
					Some(path) => Session.file_name(path)
				},
			})
		}
		match destination {
			Err(error) => failed(session, error)
			Ok(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
			Ok(Files.Choice.Chosen(path)) => match Files.write_text!({ path, text: view.body }) {
				Ok(_) => Action.update([session.write(|state| Session.written(state, { path, body: view.body }))])
				Err(error) => failed(session, error)
			}
		}
	}

	## A confirmation dialog is dismissed in state; a chooser dialog dismisses
	## itself, and a read or write cannot be interrupted.
	cancel : Ui.State(Session.State), Session.Phase -> Action(a)
	cancel = |session, phase| match phase {
		Session.Phase.ConfirmDiscard(_) => Action.update([session.write(Session.cancel)])
		_ => Action.none
	}

	parent_path : Str -> Str
	parent_path = |path| {
		segments = path.split_on("/")
		parent = Str.join_with(segments.take_first(segments.len() - 1), "/")
		if parent == "" {
			"/"
		} else {
			parent
		}
	}

	failed : Ui.State(Session.State), Files.Error -> Action(a)
	failed = |session, error| Action.update([session.write(|state| Session.failed(state, Files.error_text(error)))])
}
