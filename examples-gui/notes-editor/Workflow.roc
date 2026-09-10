import pf.Elem exposing [Elem]
import pf.Files
import pf.Gui
import pf.Signal
import pf.Ui
import Session

## Task identities are constructed once for this document's owning scope.
Workflow := [].{
	Tasks : {
		choose_open : Signal.Task(Files.Choice, Files.Error),
		choose_save : Signal.Task(Files.Choice, Files.Error),
		read : Signal.Task(Files.TextFile, Files.Error),
		write : Signal.Task(Files.Written, Files.Error),
	}

	create_tasks : () -> Tasks
	create_tasks = || {
		choose_open: Files.choose_file_task("notes-open"),
		choose_save: Files.choose_save_path_task("notes-save-path"),
		read: Files.read_text_task("notes-read"),
		write: Files.write_text_task("notes-write"),
	}

	## Phase is the only request dependency. Editing during Writing never
	## restarts or supersedes the immutable snapshot already being saved.
	bindings : Ui.State(Session.State), Ui.State(Str), Tasks -> List(Elem)
	bindings = |session, body, tasks| [
		Ui.on_change(
			session.read(|state| state.phase),
			|phase| match phase {
				Session.Phase.ChoosingOpen => Files.choose_file(tasks.choose_open)
				Session.Phase.Reading(path) => Files.read_text(tasks.read, path)
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
				Session.Phase.Writing(write) => Files.write_text(tasks.write, { path: write.path, text: write.document.body })
				_ => Signal.noop
			},
		),
		Ui.on_change(Signal.from_task(tasks.choose_open), |status| choice_result(session, status)),
		Ui.on_change(Signal.from_task(tasks.choose_save), |status| choice_result(session, status)),
		Ui.on_change(
			Signal.from_task(tasks.read),
			|status| match status {
				Signal.TaskStatus.Loading => Signal.noop
				Signal.TaskStatus.Done(file) => Ui.update_states([
					body.write(file.text),
					session.write(Session.from_file(file)),
				])
				Signal.TaskStatus.Failed(error) => failed(session, error)
			},
		),
		Ui.on_change(
			Signal.from_task(tasks.write),
			|status| match status {
				Signal.TaskStatus.Loading => Signal.noop
				Signal.TaskStatus.Done(result) => session.update_cmd(|state| Session.written(state, result.path))
				Signal.TaskStatus.Failed(error) => failed(session, error)
			},
		),
	]

	## Cancel the active task through its scope-owned engine registration.
	cancel : Ui.State(Session.State), Tasks, Session.Phase -> Gui.Cmd
	cancel = |session, tasks, phase| match phase {
		Session.Phase.ChoosingOpen => Signal.cancel(tasks.choose_open)
		Session.Phase.ChoosingSave(_) => Signal.cancel(tasks.choose_save)
		Session.Phase.Reading(_) => Signal.cancel(tasks.read)
		Session.Phase.Writing(_) => Signal.cancel(tasks.write)
		Session.Phase.ConfirmDiscard(_) => session.update_cmd(Session.cancel)
		Session.Phase.Idle => Signal.noop
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

	choice_result : Ui.State(Session.State), Signal.TaskStatus(Files.Choice, Files.Error) -> Gui.Cmd
	choice_result = |session, status| match status {
		Signal.TaskStatus.Loading => Signal.noop
		Signal.TaskStatus.Done(Files.Choice.Canceled) => session.update_cmd(Session.cancel)
		Signal.TaskStatus.Done(Files.Choice.Chosen(path)) => session.update_cmd(|state| Session.choose_path(state, path))
		Signal.TaskStatus.Failed(error) => failed(session, error)
	}

	failed : Ui.State(Session.State), Files.Error -> Gui.Cmd
	failed = |session, error| match error {
		Files.Error.Canceled => session.update_cmd(Session.cancel)
		_ => session.update_cmd(|state| Session.failed(state, Files.error_text(error)))
	}
}
