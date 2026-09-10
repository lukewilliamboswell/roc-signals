import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Signal
import pf.Ui
import Session

## The log chooser stays a scope-owned task because it needs the window's
## event loop. Reads run inside actions: entering the Reading phase runs one
## synchronous `Files.read_log!`, and caught-up files use a scoped timer to
## re-enter that phase.
Workflow := [].{
	Tasks : { choose : Signal.Task(Files.Choice, Files.Error) }

	create : () -> Tasks
	create = || { choose: Files.choose_file_task("activity-open") }

	bindings : Ui.State(Session.Accepted), Tasks -> List(Elem)
	bindings = |model, tasks| [
		Action.on_change(
			model.read(|value| value.session.phase),
			|phase| match phase {
				Session.Phase.Choosing => Files.choose_file(tasks.choose)
				Session.Phase.Reading(_) => Action.then([], |current| read_chunk!(model, current))
				_ => Action.none
			},
		),
		Action.on_change(
			Signal.from_task(tasks.choose),
			|status| match status {
				Signal.TaskStatus.Loading => Action.none
				Signal.TaskStatus.Done(choice) => Action.update([model.write(|value| { ..value, session: Session.chosen(value.session, choice) })])
				Signal.TaskStatus.Failed(error) => failed(model, error)
			},
		),
		Ui.when(model.read(|value| value.session.phase == Session.Phase.Waiting), || Action.every(500, |_| Action.update([model.write(|value| { ..value, session: Session.read_next(value.session) })])), || Elem.text("")),
	]

	## Runs the read the current phase asks for, against the phase as it is
	## after the change committed; a phase that moved on reads nothing.
	read_chunk! : Ui.State(Session.Accepted), Session.Phase => Action(Session.Phase)
	read_chunk! = |model, phase| match phase {
		Session.Phase.Reading(request) => match Files.read_log!(request) {
			Ok(chunk) => Action.update([model.write(|value| Session.accept(value.session, value.history, chunk))])
			Err(error) => failed(model, error)
		}
		_ => Action.none
	}

	cancel : Ui.State(Session.Accepted), Tasks, Session.Phase -> Action(a)
	cancel = |model, tasks, phase| match phase {
		Session.Phase.Choosing => Files.cancel(tasks.choose)
		_ => Action.update([model.write(|value| { ..value, session: Session.pause(value.session) })])
	}

	failed : Ui.State(Session.Accepted), Files.Error -> Action(a)
	failed = |model, error| match error {
		Files.Error.Canceled => Action.update([model.write(|value| { ..value, session: Session.pause(value.session) })])
		_ => Action.update([model.write(|value| { ..value, session: Session.failed(value.session, Files.error_text(error)) })])
	}
}
