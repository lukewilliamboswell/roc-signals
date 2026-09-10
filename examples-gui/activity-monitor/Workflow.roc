import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Signal
import pf.Ui
import Session

## Every native step runs as one `Files` call inside an action's effect,
## against the phase as it is after the change committed: entering Choosing
## opens the log chooser and waits for its answer, entering Reading reads one
## chunk with `Files.read_log!`, and caught-up files use a scoped timer to
## re-enter Reading.
Workflow := [].{
	bindings : Ui.State(Session.Accepted) -> List(Elem)
	bindings = |model| [
		Action.on_change(
			model.read(|value| value.session.phase),
			|phase| match phase {
				Session.Phase.Choosing | Session.Phase.Reading(_) => Action.then([], |current| advance!(model, current))
				_ => Action.none
			},
		),
		Ui.when(model.read(|value| value.session.phase == Session.Phase.Waiting), || Action.every(500, |_| Action.update([model.write(|value| { ..value, session: Session.read_next(value.session) })])), || Elem.text("")),
	]

	## Runs the chooser or read the current phase asks for; a phase that moved
	## on runs nothing.
	advance! : Ui.State(Session.Accepted), Session.Phase => Action(Session.Phase)
	advance! = |model, phase| match phase {
		Session.Phase.Choosing => match Files.choose_file!() {
			Ok(choice) => Action.update([model.write(|value| { ..value, session: Session.chosen(value.session, choice) })])
			Err(error) => failed(model, error)
		}
		Session.Phase.Reading(request) => match Files.read_log!(request) {
			Ok(chunk) => Action.update([model.write(|value| Session.accept(value.session, value.history, chunk))])
			Err(error) => failed(model, error)
		}
		_ => Action.none
	}

	## The chooser dialog dismisses itself; every other phase pauses.
	cancel : Ui.State(Session.Accepted), Session.Phase -> Action(a)
	cancel = |model, phase| match phase {
		Session.Phase.Choosing => Action.none
		_ => Action.update([model.write(|value| { ..value, session: Session.pause(value.session) })])
	}

	failed : Ui.State(Session.Accepted), Files.Error -> Action(a)
	failed = |model, error| match error {
		Files.Error.Canceled => Action.update([model.write(|value| { ..value, session: Session.pause(value.session) })])
		_ => Action.update([model.write(|value| { ..value, session: Session.failed(value.session, Files.error_text(error)) })])
	}
}
