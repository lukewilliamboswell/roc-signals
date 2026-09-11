import pf.Action exposing [Action]
import pf.Http
import pf.Ui

Poll := [].{

	## A service's last published value and newest admitted refresh generation.
	State(a) : { generation : U64, value : a }

	## Keep the previous value visible while admitting a new refresh occurrence.
	refresh : Ui.State(State(a)), Str, (Try(Str, Http.Error) -> a), State(a) -> Action(State(a))
		where [a.is_eq : a, a -> Bool]
	refresh = |state, uri, decode, current| {
		generation = current.generation + 1
		Action.then([state.write(|latest| { ..latest, generation })], |_| fetch!(state, uri, decode, generation))
	}

	fetch! : Ui.State(State(a)), Str, (Try(Str, Http.Error) -> a), U64 => Action(State(a))
		where [a.is_eq : a, a -> Bool]
	fetch! = |state, uri, decode, generation| {
		value = decode(Http.get_text!(uri))
		Action.update([
			state.write(
				|current| if current.generation == generation {
					{ ..current, value }
				} else {
					current
				},
			),
		])
	}
}
