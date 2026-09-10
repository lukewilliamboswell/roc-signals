import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Gui
import pf.Signal
import pf.Ui
import Session

## The choosers stay scope-owned tasks because they need the window's event
## loop. Reading and writing run as one synchronous `Files` call inside an
## effect, against the phase as it is after the change committed.
Workflow := [].{
	Tasks : {
		choose_open : Signal.Task(Files.Choice, Files.Error),
		choose_save : Signal.Task(Files.Choice, Files.Error),
	}

	create_tasks : () -> Tasks
	create_tasks = || {
		choose_open: Files.choose_file_task("notes-open"),
		choose_save: Files.choose_save_path_task("notes-save-path"),
	}

	## Phase is the only request dependency. Editing during Writing never
	## restarts or supersedes the immutable snapshot already being saved.
	bindings : Ui.State(Session.State), Ui.State(Str), Tasks -> List(Elem)
	bindings = |session, body, tasks| [
		Action.on_change(
			session.read(|state| state.phase),
			|phase| match phase {
				Session.Phase.ChoosingOpen => Files.choose_file(tasks.choose_open)
				Session.Phase.ChoosingSave(choice) => {
					directory = match choice.previous_path {
						None => Home
						Some(path) => At(parent_path(path))
					}
					suggested_name = match choice.previous_path {
						None => "Untitled note.txt"
						Some(path) => Session.file_name(path)
					}
					Files.choose_save_path(tasks.choose_save, { directory, suggested_name })
				}
				Session.Phase.Reading(_) | Session.Phase.Writing(_) => Action.then([], |current| transfer!(session, body, current))
				_ => Action.none
			},
		),
		Action.on_change(Signal.from_task(tasks.choose_open), |status| choice_result(session, status)),
		Action.on_change(Signal.from_task(tasks.choose_save), |status| choice_result(session, status)),
	]

	## Runs the read or write the current phase asks for; a phase that moved
	## on runs nothing.
	transfer! : Ui.State(Session.State), Ui.State(Str), Session.Phase => Action(Session.Phase)
	transfer! = |session, body, phase| match phase {
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

	## Cancel the active chooser through its scope-owned engine registration;
	## a confirmation dialog is dismissed in state.
	cancel : Ui.State(Session.State), Tasks, Session.Phase -> Action(a)
	cancel = |session, tasks, phase| match phase {
		Session.Phase.ChoosingOpen => Files.cancel(tasks.choose_open)
		Session.Phase.ChoosingSave(_) => Files.cancel(tasks.choose_save)
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

	choice_result : Ui.State(Session.State), Signal.TaskStatus(Files.Choice, Files.Error) -> Action(a)
	choice_result = |session, status| match status {
		Signal.TaskStatus.Loading => Action.none
		Signal.TaskStatus.Done(Files.Choice.Canceled) => Action.update([session.write(Session.cancel)])
		Signal.TaskStatus.Done(Files.Choice.Chosen(path)) => Action.update([session.write(|state| Session.choose_path(state, path))])
		Signal.TaskStatus.Failed(error) => failed(session, error)
	}

	failed : Ui.State(Session.State), Files.Error -> Action(a)
	failed = |session, error| match error {
		Files.Error.Canceled => Action.update([session.write(Session.cancel)])
		_ => Action.update([session.write(|state| Session.failed(state, Files.error_text(error)))])
	}
}
