import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Gui
import pf.Signal
import pf.Ui
import Session

## Choosing, reading, and writing each run as one `Files` call inside an
## effect, against the phase as it is after the change committed. A chooser
## blocks that effect until the user answers.
Workflow := [].{
	## Phase is the only request dependency. Editing during Writing never
	## restarts or supersedes the immutable snapshot already being saved.
	bindings : Ui.State(Session.State), Ui.State(Str) -> List(Elem)
	bindings = |session, body| [
		Action.on_change(
			session.read(|state| state.phase),
			|phase| match phase {
				Session.Phase.Idle | Session.Phase.ConfirmDiscard(_) => Action.none
				_ => Action.then([], |current| transfer!(session, body, current))
			},
		),
	]

	## Runs the chooser, read, or write the current phase asks for; a phase
	## that moved on runs nothing.
	transfer! : Ui.State(Session.State), Ui.State(Str), Session.Phase => Action(Session.Phase)
	transfer! = |session, body, phase| match phase {
		Session.Phase.ChoosingOpen => chosen(session, Files.choose_file!())
		Session.Phase.ChoosingSave(choice) => {
			directory = match choice.previous_path {
				None => Home
				Some(path) => At(parent_path(path))
			}
			suggested_name = match choice.previous_path {
				None => "Untitled note.txt"
				Some(path) => Session.file_name(path)
			}
			chosen(session, Files.choose_save_path!({ directory, suggested_name }))
		}
		Session.Phase.Reading(path) => match Files.read_text!(path) {
			Ok(file) => Action.update([
				body.set(file.text),
				session.set(Session.from_file(file)),
			])
			Err(error) => failed(session, error)
		}
		Session.Phase.Writing(write) => match Files.write_text!({ path: write.path, text: write.document.body }) {
			Ok(result) => Action.update([session.write(|state| Session.written(state, result.path))])
			Err(error) => failed(session, error)
		}
		_ => Action.none
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

	chosen : Ui.State(Session.State), Try(Files.Choice, Files.Error) -> Action(a)
	chosen = |session, result| match result {
		Ok(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
		Ok(Files.Choice.Chosen(path)) => Action.update([session.write(|state| Session.choose_path(state, path))])
		Err(error) => failed(session, error)
	}

	failed : Ui.State(Session.State), Files.Error -> Action(a)
	failed = |session, error| match error {
		Files.Error.Canceled => Action.update([session.write(Session.cancel)])
		_ => Action.update([session.write(|state| Session.failed(state, Files.error_text(error)))])
	}
}
