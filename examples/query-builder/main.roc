app [main] { pf: platform "../../platform/main.roc" }

import Query
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# --- classes -----------------------------------------------------------------

page_class : Str
page_class = "app-shell app-shell-wide"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

input_class : Str
input_class = "input"

note_class : Str
note_class = "muted"

hint_class : Str
hint_class = "hint"

## The one dark surface in this example: the generated query is the payoff, so
## it gets console treatment rather than another line of body text.
query_block_class : Str
query_block_class = "overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm leading-6 text-zinc-100"

## A group's own preview line, one step quieter than the top-level query.
summary_class : Str
summary_class = "min-w-0 break-words font-mono text-xs text-zinc-500"

cond_card_class : Str
cond_card_class = "grid gap-2 rounded-md border border-zinc-200 bg-white p-3 shadow-sm"

## Nested groups are boxed; the root group is not, because the panel around it
## already is the box.
group_box_class : Bool -> Str
group_box_class = |is_root|
	if is_root {
		"grid gap-3"
	} else {
		"grid gap-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3"
	}

## Every level of nesting draws its children behind a left rule, and the rule
## colour cycles so three levels of `AND` inside `OR` inside `AND` stay legible.
rule_class : U64 -> Str
rule_class = |depth| {
	bucket = depth - (depth / 3) * 3
	colour =
		if bucket == 0 {
			"border-indigo-300"
		} else if bucket == 1 {
			"border-emerald-300"
		} else {
			"border-amber-300"
		}
	"grid gap-3 border-l-2 pl-4 ${colour}"
}

segment_group_class : Str
segment_group_class = "inline-flex items-center gap-0.5 rounded-md border border-zinc-300 bg-zinc-100 p-0.5"

## The active operator has to be unmistakable: it is the only thing that says
## whether these conditions are ANDed or ORed together.
segment_class : Bool -> Str
segment_class = |active|
	if active {
		"rounded border border-zinc-200 bg-white px-2.5 py-1 text-xs font-semibold text-zinc-950 shadow-sm"
	} else {
		"rounded border border-transparent px-2.5 py-1 text-xs font-medium text-zinc-500 transition hover:text-zinc-900"
	}

## An empty group constrains nothing, which is worth saying where it happens
## rather than leaving the reader to decode `(ALL)`.
empty_group_class : Bool -> Str
empty_group_class = |empty|
	if empty {
		"notice notice-warn"
	} else {
		"hidden"
	}

## Same idea for a leaf with no value typed into it yet.
incomplete_class : Bool -> Str
incomplete_class = |empty|
	if empty {
		"badge badge-warn"
	} else {
		"hidden"
	}

empty_matches_class : Bool -> Str
empty_matches_class = |empty|
	if empty {
		"empty-state"
	} else {
		"hidden"
	}

# --- content -----------------------------------------------------------------

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

## The value box is sized and hinted for whatever the chosen field holds, so a
## level comparison does not offer a wide free-text box.
value_placeholder : Str -> Str
value_placeholder = |field|
	if field == "dept" {
		"Platform"
	} else if field == "level" {
		"3"
	} else {
		"Ada"
	}

value_mode : Str -> Str
value_mode = |field|
	if field == "level" {
		"numeric"
	} else {
		"text"
	}

## One metric tile. Every number in the header is one of these, so none of them
## is a sentence.
stat : Str, Signal.Signal(Str), Str -> Elem
stat = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value numeric")]),
		],
	)

## A labelled control. `Html.select_c`'s first argument is only the accessible
## name, so the visible caption is drawn here.
field_box : Str, Str, Elem -> Elem
field_box = |label, extra, control|
	Html.div_c(
		"field ${extra}",
		[Html.paragraph_c(label, "field-label"), control],
	)

## One matched dataset row. Keyed by the row name, which is durable identity,
## so the department and level can be looked up once at row construction.
render_match : Str, Signal.Signal(Str) -> Elem
render_match = |name, _row| {
	Html.section(
		"Matched row ${name}",
		[Html.test_id("match-${name}"), Html.class_attr("flex items-center justify-between gap-3 rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2")],
		[
			Html.paragraph_c(name, "value"),
			Html.paragraph_c(Query.row_detail(name), "hint numeric"),
		],
	)
}

## Leaf editor: field, operator and value on one line, each labelled, with the
## rendered condition text underneath.
render_cond : Ui.State(Query.QNode), Str, Signal.Signal(Query.QNode) -> Elem
render_cond = |tree, id, node| {
	cond : Signal.Signal(Query.Cond)
	cond = node.map(Query.cond_of)

	field_signal : Signal.Signal(Str)
	field_signal = cond.map(|c| c.field)

	Html.section(
		"Condition ${id}",
		[Html.class_attr(cond_card_class), Html.test_id("node-${id}")],
		[
			Html.div_c(
				"grid gap-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,12rem)_minmax(0,1fr)_auto] sm:items-end",
				[
					field_box(
						"Field",
						"min-w-0",
						Html.select_c(
							"Field ${id}",
							field_signal,
							input_class,
							field_options,
							tree.on_str(|current, value| Query.set_field(current, id, value)),
						),
					),
					field_box(
						"Operator",
						"min-w-0",
						Html.select_c(
							"Operator ${id}",
							cond.map(|c| c.op),
							input_class,
							op_options,
							tree.on_str(|current, value| Query.set_op(current, id, value)),
						),
					),
					field_box(
						"Value",
						"min-w-0",
						Html.text_input_attrs(
							"Value ${id}",
							cond.map(|c| c.value),
							[
								Html.class_attr(input_class),
								Html.attr_s("placeholder", field_signal.map(value_placeholder)),
								Html.attr_s("inputmode", field_signal.map(value_mode)),
							],
							tree.on_str(|current, value| Query.set_value(current, id, value)),
						),
					),
					Html.button_attrs(
						"Remove",
						[
							Html.attr("type", "button"),
							Html.aria_label("Delete ${id}"),
							Html.class_attr("button-ghost button-sm sm:mb-0.5"),
						],
						tree.on_unit(|current| Query.delete_node(current, id)),
					),
				],
			),
			Html.div_c(
				"flex flex-wrap items-center gap-2",
				[
					Html.paragraph_s_attrs(
						cond.map(Query.cond_summary),
						[Html.test_id("summary-${id}"), Html.class_attr(summary_class)],
					),
					Html.paragraph_attrs(
						"Empty value — matches every row",
						[Html.class_attr_s(cond.map(|c| incomplete_class(c.value.is_empty())))],
					),
				],
			),
		],
	)
}

## The AND/OR segmented control. Two buttons, not a select: the operator is the
## structure of the group and reads better as a visible pair with one of them
## obviously on. The accessible name carries the node id the specs address.
mode_segment : Ui.State(Query.QNode), Str, Signal.Signal(Str), Str -> Elem
mode_segment = |tree, id, mode, value|
	Html.button_attrs(
		value,
		[
			Html.attr("type", "button"),
			Html.aria_label("Set ${value} for ${id}"),
			Html.attr_s("aria-pressed", mode.map(|current| if current == value { "true" } else { "false" })),
			Html.class_attr_s(mode.map(|current| segment_class(current == value))),
		],
		tree.on_unit(|current| Query.set_mode(current, id, value)),
	)

## Group editor. The child list is a `Ui.each_str` whose row renderer is
## `render_node`, so the whole editor is one recursive component over the tree.
render_group : Ui.State(Query.QNode), Str, U64, Bool, Signal.Signal(Query.QNode) -> Elem
render_group = |tree, id, depth, is_root, node| {
	children : Signal.Signal(List(Query.QNode))
	children = node.map(Query.group_children)

	mode : Signal.Signal(Str)
	mode = node.map(Query.group_mode)

	add_condition_class =
		if is_root {
			"button-primary button-sm"
		} else {
			"button button-sm"
		}

	trailing_controls =
		if is_root {
			[Html.paragraph_c("Root group", "badge badge-neutral")]
		} else {
			[
				Html.button_attrs(
					"Remove group",
					[
						Html.attr("type", "button"),
						Html.aria_label("Delete ${id}"),
						Html.class_attr("button-ghost button-sm"),
					],
					tree.on_unit(|current| Query.delete_node(current, id)),
				),
			]
		}

	Html.section(
		"Group ${id}",
		[Html.class_attr(group_box_class(is_root)), Html.test_id("node-${id}")],
		[
			Html.div_c(
				"flex flex-wrap items-center gap-x-3 gap-y-2",
				[
					Html.div(
						[Html.class_attr(segment_group_class), Html.attr("role", "group"), Html.attr("aria-label", "Combine ${id} with")],
						[
							mode_segment(tree, id, mode, "AND"),
							mode_segment(tree, id, mode, "OR"),
						],
					),
					Html.div_c(
						"check-row",
						[
							Html.checkbox_c(
								"Negate ${id}",
								node.map(Query.group_negated),
								"checkbox",
								tree.on_bool(|current, value| Query.set_negated(current, id, value)),
							),
							Html.text("NOT"),
						],
					),
					Html.paragraph_s_attrs(
						node.map(Query.query_text),
						[Html.test_id("summary-${id}"), Html.class_attr("${summary_class} grow")],
					),
				]
				|> List.concat(trailing_controls),
			),
			Html.paragraph_attrs(
				"This group is empty, so it constrains nothing and matches every row.",
				[Html.class_attr_s(children.map(|list| empty_group_class(list.is_empty())))],
			),
			Html.div_c(
				rule_class(depth),
				[Ui.each_str(children, Query.node_key, |key, child| render_node(tree, depth + 1, key, child))],
			),
			Html.div_c(
				"flex flex-wrap items-center gap-2",
				[
					Html.button_attrs(
						"Add group",
						[
							Html.attr("type", "button"),
							Html.aria_label("Add group to ${id}"),
							Html.class_attr("button button-sm"),
						],
						tree.on_unit(|current| Query.add_group(current, id)),
					),
					Html.button_attrs(
						"Add condition",
						[
							Html.attr("type", "button"),
							Html.aria_label("Add condition to ${id}"),
							Html.class_attr(add_condition_class),
						],
						tree.on_unit(|current| Query.add_condition(current, id)),
					),
				],
			),
		],
	)
}

## Recursive dispatch. The list key carries the node kind, so this picks the
## group or leaf shape with a plain Roc `if` at row-construction time rather
## than a `Ui.when`, whose arms are both evaluated eagerly and would therefore
## never terminate on a recursive structure.
render_node : Ui.State(Query.QNode), U64, Str, Signal.Signal(Query.QNode) -> Elem
render_node = |tree, depth, key, node| {
	id = Query.suffix_after(key, ":")
	if key.starts_with("group:") {
		render_group(tree, id, depth, False, node)
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
							|state| "${state.matched.to_str()} of ${state.total.to_str()}",
						)

					dataset_text : Signal.Signal(Str)
					dataset_text = total_count.map(|n| n.to_str())

					query_signal : Signal.Signal(Str)
					query_signal = tree_signal.map(Query.query_text)

					# Wide fan-in over three same-shaped tree statistics. One
					# combine feeds three tiles, so the shape of the tree is read
					# off the header instead of a slash-separated sentence.
					shape_stats : Signal.Signal(List(U64))
					shape_stats =
						Signal.combine(
							[
								tree_signal.map(Query.count_conditions),
								tree_signal.map(Query.count_groups),
								tree_signal.map(Query.tree_depth),
							],
						)

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Query Builder",
								"app-header",
								[
									Html.heading_c("Query Builder", "app-title"),
									Html.paragraph_c(
										"Build a nested AND/OR filter over the team directory. The generated query, the shape of the tree and the matching rows all follow every edit.",
										"app-subtitle",
									),
								],
							),
							Html.div_c(
								"stat-grid",
								[
									stat("Matching rows", match_text, "match-summary"),
									stat("Dataset rows", dataset_text, "dataset-summary"),
									stat("Conditions", shape_stats.map(|stats| stat_at(stats, 0)), "shape-stats"),
									stat("Groups", shape_stats.map(|stats| stat_at(stats, 1)), "group-count"),
									stat("Depth", shape_stats.map(|stats| stat_at(stats, 2)), "tree-depth"),
								],
							),
							Html.section_c(
								"Generated query",
								"panel grid gap-0",
								[
									Html.div_c(
										"panel-head",
										[
											Html.heading_c("Generated query", "panel-title"),
											Html.paragraph_c("Recomputed on every edit", hint_class),
										],
									),
									Html.div_c(
										"panel-body",
										[
											Html.paragraph_s_attrs(
												query_signal,
												[Html.test_id("query-text"), Html.class_attr(query_block_class)],
											),
											Html.paragraph_c(
												"An empty group and a condition with an empty value both impose no constraint and match every row.",
												hint_class,
											),
										],
									),
								],
							),
							Html.div_c(
								"grid gap-5 lg:grid-cols-3 lg:items-start",
								[
									Html.section_c(
										"Filter tree",
										"panel grid gap-0 lg:col-span-2",
										[
											Html.div_c(
												"panel-head",
												[
													Html.heading_c("Filter tree", "panel-title"),
													Html.paragraph_c("Each level of nesting sits behind its own rule", hint_class),
												],
											),
											Html.div_c(
												"panel-body",
												[render_group(tree, "n1", 0, True, tree_signal)],
											),
										],
									),
									Html.div_c(
										"grid gap-5",
										[
											Html.section_c(
												"Dataset",
												panel_class,
												[
													Html.heading_c("Dataset", "panel-title"),
													Html.div_c(
														"check-row",
														[
															Html.checkbox_c(
																"Include archived rows",
																archived_signal,
																"checkbox",
																archived.on_bool(|_current, value| value),
															),
															Html.text("Include archived rows"),
														],
													),
													Html.paragraph_c(
														"The dataset toggle is a second, independent source: flipping it re-evaluates the same tree against more rows.",
														note_class,
													),
												],
											),
											Html.section_c(
												"Matches",
												panel_class,
												[
													Html.heading_c("Matches", "panel-title"),
													Html.paragraph_attrs(
														"No rows match this filter.",
														[Html.class_attr_s(matched_names.map(|names| empty_matches_class(names.is_empty())))],
													),
													Html.div_c(
														"grid gap-2",
														[Ui.each_str(matched_names, |name| name, render_match)],
													),
												],
											),
										],
									),
								],
							),
						],
					)
				},
			)
		},
	)
}
