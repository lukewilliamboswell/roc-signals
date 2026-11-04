import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

TaskPanel := {}.{
	Task : { title : Str, done : Bool, labels : List(Str) }

	## An ordinary reusable component; the platform cannot know its state type.
	view : Str -> Elem
	view = |name| Ui.component(||
		Ui.state({ title: "a heap-backed title from an independently defined component", done: False, labels: ["a nested heap-backed label owned by this task"] }, |state| {
			source : Signal.Signal(Task)
			source = state.signal()
			caption = Signal.map(source, |t| "${name}: ${t.title}")
			status = Signal.map(source, |t| if t.done { "done" } else { "open" })
			combined = Signal.map2(caption, status, |text, mode| "${text} (${mode})")
			Html.div([], [
				Html.text_s(combined),
				Html.button("Toggle ${name}", state.update(|t| { ..t, done: !t.done })),
			])
		})
	)
}
