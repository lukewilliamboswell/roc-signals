app [main] { pf: platform "../../platform/main.roc" }

import Query
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

group_class = "panel grid gap-3 border-l-4 border-indigo-400 p-4"

cond_class = "panel grid gap-3 border-l-4 border-zinc-300 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

mono_class = "font-mono text-sm text-zinc-900"

note_class = "text-sm text-zinc-600"

value_class = "text-sm font-medium text-zinc-900"

input_class = "w-full max-w-xs rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

stat_at : List(U64), U64 -> Str
stat_at = |values, index|
	match values.get(index) {
		Ok(value) => value.to_str()
		Err(_) => "0"
	}

field_options : List(Elem)
field_options = [
	Html.option("name", "Name"),
	Html.option("dept", "Department"),
	Html.option("level", "Level"),
]

op_options : List(Elem)
op_options = [
	Html.option("eq", "equals"),
	Html.option("ne", "does not equal"),
	Html.option("contains", "contains"),
	Html.option("gt", "greater than"),
	Html.option("lt", "less than"),
]

## One matched dataset row. Keyed by the row name, which is durable identity.
render_match : Str, Signal.Signal(Str) -> Elem
render_match = |name, _row| {
	Html.section(
		"Matched row ${name}",
		[Html.test_id("match-${name}"), Html.class_attr("text-sm text-zinc-800")],
		[Html.paragraph_attrs(name, [Html.class_attr(value_class)])],
	)
}

## Leaf editor: field, operator, value, plus the rendered condition text.
render_cond : Ui.State(Query.QNode), Str, Signal.Signal(Query.QNode) -> Elem
render_cond = |tree, id, node| {
	cond : Signal.Signal(Query.Cond)
	cond = node.map(Query.cond_of)

	Html.section(
		"Condition ${id}",
		[Html.class_attr(cond_class), Html.test_id("node-${id}")],
		[
			Html.heading_c("Condition ${id}", "text-sm font-semibold text-zinc-950"),
			Html.select_c(
				"Field ${id}",
				cond.map(|c| c.field),
				input_class,
				field_options,
				tree.on_str(|current, value| Query.set_field(current, id, value)),
			),
			Html.select_c(
				"Operator ${id}",
				cond.map(|c| c.op),
				input_class,
				op_options,
				tree.on_str(|current, value| Query.set_op(current, id, value)),
			),
			Html.text_input_c(
				"Value ${id}",
				cond.map(|c| c.value),
				input_class,
				tree.on_str(|current, value| Query.set_value(current, id, value)),
			),
			Html.paragraph_s_attrs(
				cond.map(Query.cond_summary),
				[Html.test_id("summary-${id}"), Html.class_attr(mono_class)],
			),
			Html.button_c(
				"Delete ${id}",
				"button",
				tree.on_unit(|current| Query.delete_node(current, id)),
			),
		],
	)
}

## Group editor. The child list is a `Ui.each_str` whose row renderer is
## `render_node`, so the whole editor is one recursive component over the tree.
render_group : Ui.State(Query.QNode), Str, Signal.Signal(Query.QNode), Bool -> Elem
render_group = |tree, id, node, deletable| {
	children : Signal.Signal(List(Query.QNode))
	children = node.map(Query.group_children)

	delete_controls =
		if deletable {
			[
				Html.button_c(
					"Delete ${id}",
					"button",
					tree.on_unit(|current| Query.delete_node(current, id)),
				),
			]
		} else {
			[Html.paragraph_c("Root group cannot be deleted", note_class)]
		}

	Html.section(
		"Group ${id}",
		[Html.class_attr(group_class), Html.test_id("node-${id}")],
		[
			Html.heading_c("Group ${id}", "text-sm font-semibold text-zinc-950"),
			Html.select_c(
				"Mode ${id}",
				node.map(Query.group_mode),
				input_class,
				[Html.option("AND", "AND"), Html.option("OR", "OR")],
				tree.on_str(|current, value| Query.set_mode(current, id, value)),
			),
			Html.checkbox(
				"Negate ${id}",
				node.map(Query.group_negated),
				tree.on_bool(|current, value| Query.set_negated(current, id, value)),
			),
			Html.paragraph_s_attrs(
				node.map(Query.query_text),
				[Html.test_id("summary-${id}"), Html.class_attr(mono_class)],
			),
			Html.div_c(
				toolbar_class,
				[
					Html.button_c(
						"Add condition to ${id}",
						"button-primary",
						tree.on_unit(|current| Query.add_condition(current, id)),
					),
					Html.button_c(
						"Add group to ${id}",
						"button-primary",
						tree.on_unit(|current| Query.add_group(current, id)),
					),
				]
				|> List.concat(delete_controls),
			),
			Ui.each_str(children, Query.node_key, |key, child| render_node(tree, key, child)),
		],
	)
}

## Recursive dispatch. The list key carries the node kind, so this picks the
## group or leaf shape with a plain Roc `if` at row-construction time rather
## than a `Ui.when`, whose arms are both evaluated eagerly and would therefore
## never terminate on a recursive structure.
render_node : Ui.State(Query.QNode), Str, Signal.Signal(Query.QNode) -> Elem
render_node = |tree, key, node| {
	id = Query.suffix_after(key, ":")
	if key.starts_with("group:") {
		render_group(tree, id, node, True)
	} else {
		render_cond(tree, id, node)
	}
}

main : () -> Elem
main = || {
	include_archived_initial : Bool
	include_archived_initial = False

	Ui.state(
		include_archived_initial,
		|archived| {
			Ui.state(
				Query.initial_tree,
				|tree| {
					tree_signal : Signal.Signal(Query.QNode)
					tree_signal = tree.signal()
					archived_signal : Signal.Signal(Bool)
					archived_signal = archived.signal()

					# Fan-in: the tree and the dataset toggle are independent sources.
					matched_names : Signal.Signal(List(Str))
					matched_names = Signal.map2(tree_signal, archived_signal, Query.matching_names)

					matched_count : Signal.Signal(U64)
					matched_count = matched_names.map(|names| names.len())

					total_count : Signal.Signal(U64)
					total_count = archived_signal.map(|flag| Query.rows_for(flag).len())

					# Second fan-in, two hops downstream of the tree source.
					match_state = { matched: matched_count, total: total_count }.Signal
					match_text : Signal.Signal(Str)
					match_text =
						match_state.map(
							|state| "Matching rows: ${state.matched.to_str()} of ${state.total.to_str()}",
						)

					dataset_text : Signal.Signal(Str)
					dataset_text = total_count.map(|n| "Dataset rows: ${n.to_str()}")

					query_signal : Signal.Signal(Str)
					query_signal = tree_signal.map(Query.query_text)

					# Wide fan-in over three same-shaped tree statistics.
					shape_stats : Signal.Signal(List(U64))
					shape_stats =
						Signal.combine(
							[
								tree_signal.map(Query.count_conditions),
								tree_signal.map(Query.count_groups),
								tree_signal.map(Query.tree_depth),
							],
						)
					shape_text : Signal.Signal(Str)
					shape_text =
						shape_stats.map(
							|stats|
								"Conditions ${stat_at(stats, 0)} / Groups ${stat_at(stats, 1)} / Depth ${stat_at(stats, 2)}",
						)

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Query Builder",
								hero_class,
								[
									Html.heading_c("Query Builder", "text-3xl font-semibold text-zinc-950"),
									Html.paragraph_c("Build a nested AND/OR filter tree, negate groups, and watch the generated query and the live match count follow every edit.", "max-w-3xl text-sm text-zinc-700"),
									Html.paragraph_c("An empty group and a condition with an empty value both impose no constraint and match every row.", note_class),
								],
							),
							Html.section_c(
								"Dataset",
								panel_class,
								[
									Html.heading_c("Dataset", "text-lg font-semibold text-zinc-950"),
									Html.checkbox(
										"Include archived rows",
										archived_signal,
										archived.on_bool(|_current, value| value),
									),
									Html.paragraph_s_attrs(dataset_text, [Html.test_id("dataset-summary"), Html.class_attr(value_class)]),
								],
							),
							Html.section_c(
								"Generated query",
								panel_class,
								[
									Html.heading_c("Generated query", "text-lg font-semibold text-zinc-950"),
									Html.paragraph_s_attrs(query_signal, [Html.test_id("query-text"), Html.class_attr(mono_class)]),
									Html.paragraph_s_attrs(shape_text, [Html.test_id("shape-stats"), Html.class_attr(note_class)]),
								],
							),
							Html.section_c(
								"Matches",
								panel_class,
								[
									Html.heading_c("Matches", "text-lg font-semibold text-zinc-950"),
									Html.paragraph_s_attrs(match_text, [Html.test_id("match-summary"), Html.class_attr(value_class)]),
									Ui.each_str(matched_names, |name| name, render_match),
								],
							),
							Html.section_c(
								"Filter tree",
								panel_class,
								[
									Html.heading_c("Filter tree", "text-lg font-semibold text-zinc-950"),
									render_group(tree, "n1", tree_signal, False),
								],
							),
						],
					)
				},
			)
		},
	)
}
