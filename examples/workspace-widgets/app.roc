app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

increment_i64 : I64 -> I64
increment_i64 = |current| current + 1

traffic_widget : Str
traffic_widget = "Traffic Widget"

queue_widget : Str
queue_widget = "Queue Widget"

initial_components : List(Str)
initial_components = [traffic_widget, queue_widget]

reordered_components : List(Str)
reordered_components = [queue_widget, traffic_widget]

page_class : Str
page_class = "grid gap-5"

hero_class : Str
hero_class = "panel grid gap-2 p-5"

panel_class : Str
panel_class = "panel grid gap-4 p-4"

widget_class : Str
widget_class = "panel grid gap-3 p-4"

toolbar_class : Str
toolbar_class = "flex flex-wrap items-center gap-3"

visible_components : Bool, List(Str) -> List(Str)
visible_components = |show_queue, labels| if show_queue {
	labels
} else {
	[traffic_widget]
}

counter_component : Str -> Elem
counter_component = |label| {
	initial_count : I64
	initial_count = 0

	Ui.component(
		|_| {
			Ui.state(
				initial_count,
				|count| {
					count_label =
						Signal.map(
							count.signal(),
							|value| concat3(label, " refreshes: ", value.to_str()),
						)

					Html.section_c(
						label,
						widget_class,
						[
							Html.heading_c(label, "text-lg font-semibold text-zinc-950"),
							Html.paragraph_s_c(count_label, "text-sm text-zinc-700"),
							Html.button_c(Str.concat("Refresh ", label), "button", count.on_unit(increment_i64)),
						],
					)
				},
			)
		},
	)
}

render_component : Str, Signal.Signal(Str) -> Elem
render_component = |label, _label_signal| counter_component(label)

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_components,
		|order| {
			Ui.state(
				True,
				|show_queue| {
					visible =
						Signal.map2(
							show_queue.signal(),
							order.signal(),
							visible_components,
						)

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Workspace Widgets",
								hero_class,
								[
									Html.heading_c("Workspace Widgets", "text-3xl font-semibold text-zinc-950"),
									Html.paragraph_c("Reorder operational widgets without losing each widget's local refresh state.", "max-w-3xl text-sm text-zinc-700"),
								],
							),
							Html.section_c(
								"Widget controls",
								panel_class,
								[
									Html.div_c(
										toolbar_class,
										[
											Html.button_c("Reorder widgets", "button-primary", order.on_unit(|_| reordered_components)),
											Html.button_c("Reset layout", "button", order.on_unit(|_| initial_components)),
											Html.button_c("Toggle queue widget", "button", show_queue.on_unit(|value| !value)),
										],
									),
								],
							),
							Ui.each_str(visible, |label| label, render_component),
						],
					)
				},
			)
		},
	)
}
