import pf.Elem exposing [Elem]
import pf.Files
import pf.Gui
import pf.Signal
import pf.Ui
import Session

## Files stay on the shared, scope-owned task path. At most one read is active;
## complete chunks drain sequentially and caught-up files use a scoped timer.
Workflow := [].{
	Tasks : { choose : Signal.Task(Files.Choice, Files.Error), read : Signal.Task(Files.LogChunk, Files.Error) }

	create : () -> Tasks
	create = || { choose: Files.choose_file_task("activity-open"), read: Files.read_log_task("activity-read") }

	bindings : Ui.State(Session.Accepted), Tasks -> List(Elem)
	bindings = |model, tasks| [
		Ui.on_change(
			model.read(|value| value.session.phase),
			|phase| match phase {
				Session.Phase.Choosing => Files.choose_file(tasks.choose)
				Session.Phase.Reading(request) => Files.read_log(tasks.read, request)
				_ => Signal.noop
			},
		),
		Ui.on_change(
			Signal.from_task(tasks.choose),
			|status| match status {
				Signal.TaskStatus.Loading => Signal.noop
				Signal.TaskStatus.Done(choice) => model.update_cmd(|value| { ..value, session: Session.chosen(value.session, choice) })
				Signal.TaskStatus.Failed(error) => failed(model, error)
			},
		),
		Ui.on_change(
			Signal.from_task(tasks.read),
			|status| match status {
				Signal.TaskStatus.Loading => Signal.noop
				Signal.TaskStatus.Done(chunk) => model.update_cmd(|value| Session.accept(value.session, value.history, chunk))
				Signal.TaskStatus.Failed(error) => failed(model, error)
			},
		),
		Ui.when(model.read(|value| value.session.phase == Session.Phase.Waiting), || Ui.on_change(Signal.interval(500), |_| model.update_cmd(|value| { ..value, session: Session.read_next(value.session) })), || Gui.text("")),
	]

	cancel : Ui.State(Session.Accepted), Tasks, Session.Phase -> Gui.Cmd
	cancel = |model, tasks, phase| match phase {
		Session.Phase.Choosing => Signal.cancel(tasks.choose)
		Session.Phase.Reading(_) => Signal.cancel(tasks.read)
		_ => model.update_cmd(|value| { ..value, session: Session.pause(value.session) })
	}

	failed : Ui.State(Session.Accepted), Files.Error -> Gui.Cmd
	failed = |model, error| match error {
		Files.Error.Canceled => model.update_cmd(|value| { ..value, session: Session.pause(value.session) })
		_ => model.update_cmd(|value| { ..value, session: Session.failed(value.session, Files.error_text(error)) })
	}
}
