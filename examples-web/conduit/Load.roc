## A page-owned HTTP result. New requests supersede publication, not execution.
import Api
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Http
import pf.Signal
import pf.Ui

Load := [].{
	State(a) : { generation : U64, value : Api.Remote(a) }
	Read(a) : { uri : Str, current : Load.State(a) }

	watch : Ui.State(Load.State(a)), Signal.Signal(Str), (Str -> Api.Remote(a)) -> Elem
		where [a.is_eq : a, a -> Bool]
	watch = |state, uri, decode|
		Action.on_change_initial(
			Action.sampled(uri, { uri, current: state.signal() }.Signal),
			|read| Load.start(state, decode, read),
		)

	start : Ui.State(Load.State(a)), (Str -> Api.Remote(a)), Load.Read(a) -> Action(Load.Read(a))
		where [a.is_eq : a, a -> Bool]
	start = |state, decode, read| if read.uri.is_empty() {
		Action.none
	} else {
		generation = read.current.generation + 1
		Action.then(
			[state.set({ generation, value: Loading })],
			|_| Load.fetch!(state, read.uri, decode, generation),
		)
	}

	fetch! : Ui.State(Load.State(a)), Str, (Str -> Api.Remote(a)), U64 => Action(Load.Read(a))
		where [a.is_eq : a, a -> Bool]
	fetch! = |state, uri, decode, generation| {
		value = match Http.get_text!(uri) {
			Ok(body) => decode(body)
			Err(err) => Api.request_failed(Str.inspect(err))
		}
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
