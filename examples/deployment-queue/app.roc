app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

row_label : Str, I64 -> Str
row_label = |label, count| concat3(label, " checks: ", count.to_str())

row_a : Str
row_a = "Edge Gateway"

row_b : Str
row_b = "API Workers"

row_c : Str
row_c = "Search Index"

row_d : Str
row_d = "Billing Hotfix"

initial_rows : List(Str)
initial_rows = [row_a, row_b, row_c]

inserted_rows : List(Str)
inserted_rows = [row_a, row_d, row_b, row_c]

reordered_rows : List(Str)
reordered_rows = [row_c, row_a, row_b]

inserted_reordered_rows : List(Str)
inserted_reordered_rows = [row_c, row_a, row_d, row_b]

initial_filtered_rows : List(Str)
initial_filtered_rows = [row_a, row_c]

inserted_filtered_rows : List(Str)
inserted_filtered_rows = [row_a, row_d, row_c]

reordered_filtered_rows : List(Str)
reordered_filtered_rows = [row_c, row_a]

inserted_reordered_filtered_rows : List(Str)
inserted_reordered_filtered_rows = [row_c, row_a, row_d]

page_class : Str
page_class = "grid gap-5"

hero_class : Str
hero_class = "panel grid gap-2 p-5"

panel_class : Str
panel_class = "panel grid gap-4 p-4"

row_class : Str
row_class = "panel grid gap-3 p-4"

toolbar_class : Str
toolbar_class = "flex flex-wrap items-center gap-3"

rows_for_shape : I64, Bool -> List(Str)
rows_for_shape = |shape, hide_workers| {
	if hide_workers {
		if shape == 0 {
			initial_filtered_rows
		} else if shape == 1 {
			inserted_filtered_rows
		} else if shape == 2 {
			reordered_filtered_rows
		} else {
			inserted_reordered_filtered_rows
		}
	} else {
		if shape == 0 {
			initial_rows
		} else if shape == 1 {
			inserted_rows
		} else if shape == 2 {
			reordered_rows
		} else {
			inserted_reordered_rows
		}
	}
}

render_row : Str, Signal.Signal(Str) -> Elem
render_row = |label, _row_signal| {
	Ui.state(
		0,
		|count| {
			count_signal = count.signal()
			count_label = Signal.map(count_signal, |n| row_label(label, n))
			has_count = Signal.map(count_signal, |n| n > 0)

			Html.section_c(
				label,
				row_class,
				[
					Html.heading_c(label, "text-lg font-semibold text-zinc-950"),
					Html.button_c(Str.concat("Check ", label), "button", count.on_unit(|n| n + 1)),
					Ui.when(
						has_count,
						|_| Html.paragraph_s_c(count_label, "text-sm font-medium text-emerald-700"),
						|_| Html.paragraph_c(Str.concat(label, " awaiting verification"), "text-sm text-zinc-600"),
					),
				],
			)
		},
	)
}

main : {} -> Elem
main = |_| {
	initial_reordered : Bool
	initial_reordered = False
	initial_inserted : Bool
	initial_inserted = False
	initial_filtered : Bool
	initial_filtered = False
	initial_active : Bool
	initial_active = True

	Ui.state(
		initial_reordered,
		|reordered| {
			Ui.state(
				initial_inserted,
				|inserted| {
					Ui.state(
						initial_filtered,
						|filtered| {
							Ui.state(
								initial_active,
								|active| {
									shape : Signal.Signal(I64)
									shape =
										Signal.map2(
											reordered.signal(),
											inserted.signal(),
											|is_reordered, has_hotfix| if is_reordered {
												if has_hotfix {
													3
												} else {
													2
												}
											} else {
												if has_hotfix {
													1
												} else {
													0
												}
											},
										)
									rows =
										Signal.map2(
											shape,
											filtered.signal(),
											|shape_code, hide_workers| rows_for_shape(shape_code, hide_workers),
										)

									Html.div_c(
										page_class,
										[
											Html.section_c(
												"Deployment Queue",
												hero_class,
												[
													Html.heading_c("Deployment Queue", "text-3xl font-semibold text-zinc-950"),
													Html.paragraph_c("Prioritize releases, insert a hotfix, filter paused work, and keep row-local verification state with each deployment.", "max-w-3xl text-sm text-zinc-700"),
												],
											),
											Html.section_c(
												"Queue controls",
												panel_class,
												[
													Html.div_c(
														toolbar_class,
														[
															Html.button_c("Prioritize queue", "button-primary", reordered.on_unit(|flag| !flag)),
															Html.button_c("Insert hotfix", "button-primary", inserted.on_unit(|flag| !flag)),
															Html.button_c("Hide API Workers", "button", filtered.on_unit(|flag| !flag)),
															Html.button_c("Pause queue", "button", active.on_unit(|flag| !flag)),
														],
													),
												],
											),
											Ui.when(
												active.signal(),
												|_| {
													Html.section_c(
														"Deployments active",
														panel_class,
														[
															Ui.each_str(rows, |label| label, render_row),
														],
													)
												},
												|_| {
													Html.section_c(
														"Deployments paused",
														panel_class,
														[
															Html.paragraph("Queue paused"),
														],
													)
												},
											),
										],
									)
								},
							)
						},
					)
				},
			)
		},
	)
}
