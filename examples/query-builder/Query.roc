Query :: [].{
	## A row in the sample dataset the query is evaluated against.
	Row : { name : Str, dept : Str, level : U64 }

	## Which row attribute a condition tests.
	##
	## The `<select>` on the page hands back a `Str`, so this type has exactly one
	## encode point (`to_str`) and one decode point (`from_str`); everything
	## between them works in tags.
	Field := [Name, Dept, Level].{
		is_eq : Field, Field -> Bool
		is_eq = |left, right|
			match left {
				Name => match right {
					Name => True
					_ => False
				}
				Dept => match right {
					Dept => True
					_ => False
				}
				Level => match right {
					Level => True
					_ => False
				}
			}

		## The option value, and the identifier the query text prints.
		to_str : Field -> Str
		to_str = |field|
			match field {
				Name => "name"
				Dept => "dept"
				Level => "level"
			}

		## Human label for the option list.
		label : Field -> Str
		label = |field|
			match field {
				Name => "Name"
				Dept => "Department"
				Level => "Level"
			}

		from_str : Str -> Field
		from_str = |text|
			if text == "dept" {
				Dept
			} else if text == "level" {
				Level
			} else {
				Name
			}
	}

	## How a leaf condition compares the field against the typed value. Same
	## shape as `Field`: a `Str` on the select wire, a tag everywhere else.
	Op := [Eq, Ne, Contains, Gt, Lt].{
		is_eq : Op, Op -> Bool
		is_eq = |left, right|
			match left {
				Eq => match right {
					Eq => True
					_ => False
				}
				Ne => match right {
					Ne => True
					_ => False
				}
				Contains => match right {
					Contains => True
					_ => False
				}
				Gt => match right {
					Gt => True
					_ => False
				}
				Lt => match right {
					Lt => True
					_ => False
				}
			}

		to_str : Op -> Str
		to_str = |op|
			match op {
				Eq => "eq"
				Ne => "ne"
				Contains => "contains"
				Gt => "gt"
				Lt => "lt"
			}

		label : Op -> Str
		label = |op|
			match op {
				Eq => "equals"
				Ne => "does not equal"
				Contains => "contains"
				Gt => "greater than"
				Lt => "less than"
			}

		## The compact form the generated query prints.
		symbol : Op -> Str
		symbol = |op|
			match op {
				Eq => "="
				Ne => "!="
				Contains => "~"
				Gt => ">"
				Lt => "<"
			}

		from_str : Str -> Op
		from_str = |text|
			if text == "ne" {
				Ne
			} else if text == "contains" {
				Contains
			} else if text == "gt" {
				Gt
			} else if text == "lt" {
				Lt
			} else {
				Eq
			}
	}

	## How a group combines its children. Never crosses a wire — the segmented
	## control is a pair of buttons, so this stays a tag end to end.
	Mode := [And, Or].{
		is_eq : Mode, Mode -> Bool
		is_eq = |left, right|
			match left {
				And => match right {
					And => True
					_ => False
				}
				Or => match right {
					Or => True
					_ => False
				}
			}

		to_str : Mode -> Str
		to_str = |mode|
			match mode {
				And => "AND"
				Or => "OR"
			}
	}

	## Every field, in the order the option list shows them.
	all_fields : List(Field)
	all_fields = [Name, Dept, Level]

	## Every operator, in the order the option list shows them.
	all_ops : List(Op)
	all_ops = [Eq, Ne, Contains, Gt, Lt]

	## Both combinators, in the order the segmented control shows them.
	all_modes : List(Mode)
	all_modes = [And, Or]

	## A single leaf condition: `field op value`.
	Cond : { id : Str, field : Field, op : Op, value : Str }

	## The recursive filter tree. A `Group` holds an ordered list of child nodes and
	## combines them with `AND` or `OR`, optionally negated. A `Cond` is a leaf.
	##
	## Semantics locked by the `specs/` suite:
	## - a condition whose value is empty imposes no constraint and matches every row
	##   (rendered as `ANY` in the query text);
	## - an empty group imposes no constraint and matches every row in both `AND` and
	##   `OR` mode (rendered as `ALL`), so a negated empty group matches nothing;
	## - `>` and `<` only apply to the numeric `level` field; on a text field they
	##   match nothing.
	QNode := [
		Cond(Cond),
		Group({ id : Str, mode : Mode, negated : Bool, children : List(QNode) }),
	].{
		is_eq : QNode, QNode -> Bool
		is_eq = |left, right|
			match left {
				Cond(l) => match right {
					Cond(r) =>
						l.id == r.id
						and l.field.is_eq(r.field)
						and l.op.is_eq(r.op)
						and l.value == r.value
					Group(_) => False
				}
				Group(l) => match right {
					Cond(_) => False
					Group(r) =>
						l.id == r.id
						and l.mode.is_eq(r.mode)
						and l.negated == r.negated
						and children_eq(l.children, r.children)
				}
			}
	}

	children_eq : List(QNode), List(QNode) -> Bool
	children_eq = |left, right|
		left.len() == right.len()
		and List.map2(left, right, |l, r| l.is_eq(r)).all(|same| same)

	## The five always-present sample rows.
	base_rows : List(Row)
	base_rows = [
		{ name: "Ada", dept: "Platform", level: 5 },
		{ name: "Bo", dept: "Platform", level: 2 },
		{ name: "Cy", dept: "Design", level: 4 },
		{ name: "Dee", dept: "Support", level: 1 },
		{ name: "Eli", dept: "Design", level: 3 },
	]

	## The sample rows plus the archived row.
	archived_rows : List(Row)
	archived_rows = base_rows.concat([{ name: "Fay", dept: "Platform", level: 3 }])

	## Root group with a single `dept = "Platform"` condition.
	initial_tree : QNode
	initial_tree =
		QNode.Group(
			{
				id: "n1",
				mode: And,
				negated: False,
				children: [QNode.Cond({ id: "n2", field: Dept, op: Eq, value: "Platform" })],
			},
		)

	## Which of the two shapes a node has. `Ui.each_str` keys rows by text, so the
	## kind has to survive a round trip through a `Str`; `node_key` is the only
	## place one is written and `key_kind`/`key_id` are the only places one is
	## read, which keeps the row renderer matching on a tag.
	NodeKind : [Leaf, Branch]

	kind_to_str : NodeKind -> Str
	kind_to_str = |kind|
		match kind {
			Leaf => "cond"
			Branch => "group"
		}

	## Stable list key that also encodes the node kind.
	node_key : QNode -> Str
	node_key = |node|
		match node {
			Cond(c) => "${kind_to_str(Leaf)}:${c.id}"
			Group(g) => "${kind_to_str(Branch)}:${g.id}"
		}

	## The kind a list key was built from.
	key_kind : Str -> NodeKind
	key_kind = |key|
		if prefix_before(key, ":") == kind_to_str(Branch) {
			Branch
		} else {
			Leaf
		}

	## The node id a list key was built from.
	key_id : Str -> Str
	key_id = |key| suffix_after(key, ":")

	## A group's list key round-trips back to the branch kind.
	expect {
		key = node_key(QNode.Group({ id: "n7", mode: Or, negated: True, children: [] }))
		key_kind(key) == Branch
	}

	## A group's list key carries its node id unchanged.
	expect {
		key = node_key(QNode.Group({ id: "n7", mode: Or, negated: True, children: [] }))
		key_id(key) == "n7"
	}

	## A condition's list key round-trips back to the leaf kind.
	expect {
		key = node_key(QNode.Cond({ id: "n7", field: Name, op: Eq, value: "" }))
		key_kind(key) == Leaf
	}

	## A condition's list key carries its node id unchanged, even though a leaf
	## and a group can share the same id text.
	expect {
		key = node_key(QNode.Cond({ id: "n7", field: Name, op: Eq, value: "" }))
		key_id(key) == "n7"
	}

	## The node id on its own.
	node_id : QNode -> Str
	node_id = |node|
		match node {
			Cond(c) => c.id
			Group(g) => g.id
		}

	## Child nodes of a group; a leaf has none.
	group_children : QNode -> List(QNode)
	group_children = |node|
		match node {
			Cond(_) => []
			Group(g) => g.children
		}

	## How a group combines its children; `AND` for a leaf.
	group_mode : QNode -> Mode
	group_mode = |node|
		match node {
			Cond(_) => Mode.And
			Group(g) => g.mode
		}

	## Whether a group is negated.
	group_negated : QNode -> Bool
	group_negated = |node|
		match node {
			Cond(_) => False
			Group(g) => g.negated
		}

	## Leaf payload, with a neutral fallback so a signal transform stays total.
	cond_of : QNode -> Cond
	cond_of = |node|
		match node {
			Cond(c) => c
			Group(g) => { id: g.id, field: Name, op: Eq, value: "" }
		}

	## One-line rendering of a single leaf condition.
	cond_summary : Cond -> Str
	cond_summary = |c|
		if c.value.is_empty() {
			"ANY"
		} else {
			"${c.field.to_str()} ${c.op.symbol()} '${c.value}'"
		}

	## Every field option value the page can send back decodes to the tag it came from.
	expect all_fields.all(|field| Field.from_str(field.to_str()).is_eq(field))

	## Every operator option value the page can send back decodes to the tag it came from.
	expect all_ops.all(|op| Op.from_str(op.to_str()).is_eq(op))

	## The generated query string for a whole subtree.
	query_text : QNode -> Str
	query_text = |node|
		match node {
			Cond(c) => cond_summary(c)
			Group(g) => {
				inner =
					if g.children.is_empty() {
						"ALL"
					} else {
						Str.join_with(g.children.map(query_text), " ${g.mode.to_str()} ")
					}
				if g.negated {
					"NOT (${inner})"
				} else {
					"(${inner})"
				}
			}
		}

	## The starting tree renders as a single parenthesised condition.
	expect query_text(initial_tree) == "(dept = 'Platform')"

	## A negated empty group renders as `NOT (ALL)`, since it constrains nothing.
	expect query_text(QNode.Group({ id: "n1", mode: And, negated: True, children: [] })) == "NOT (ALL)"

	## A condition with no value typed in renders as `ANY` rather than a comparison.
	expect query_text(QNode.Cond({ id: "n2", field: Level, op: Gt, value: "" })) == "ANY"

	field_text : Row, Field -> Str
	field_text = |row, field|
		match field {
			Name => row.name
			Dept => row.dept
			Level => row.level.to_str()
		}

	str_contains : Str, Str -> Bool
	str_contains = |haystack, needle|
		if needle.is_empty() {
			True
		} else {
			haystack.split_on(needle).len() > 1
		}

	## `>` and `<` apply only to the numeric `level` field, and only when the typed
	## value parses as a number; anything else matches nothing.
	level_compare : Cond, Row, (U64, U64 -> Bool) -> Bool
	level_compare = |c, row, keep|
		match c.field {
			Level =>
				match U64.from_str(c.value) {
					Ok(target) => keep(row.level, target)
					Err(_) => False
				}
			_ => False
		}

	cond_matches : Cond, Row -> Bool
	cond_matches = |c, row|
		if c.value.is_empty() {
			True
		} else {
			text = field_text(row, c.field)
			match c.op {
				Eq => text == c.value
				Ne => text != c.value
				Contains => str_contains(text, c.value)
				Gt => level_compare(c, row, |level, target| level > target)
				Lt => level_compare(c, row, |level, target| level < target)
			}
		}

	node_matches : QNode, Row -> Bool
	node_matches = |node, row|
		match node {
			Cond(c) => cond_matches(c, row)
			Group(g) => {
				base =
					if g.children.is_empty() {
						True
					} else {
						hits = g.children.keep_if(|child| node_matches(child, row)).len()
						match g.mode {
							And => hits == g.children.len()
							Or => hits > 0
						}
					}
				if g.negated {
					!base
				} else {
					base
				}
			}
		}

	## `>` compares `level` numerically, so level 5 satisfies `level > 3`.
	expect cond_matches({ id: "n2", field: Level, op: Gt, value: "3" }, { name: "Ada", dept: "Platform", level: 5 })

	## A numeric operator on a text field never matches, rather than comparing text.
	expect !cond_matches({ id: "n2", field: Name, op: Gt, value: "3" }, { name: "Ada", dept: "Platform", level: 5 })

	## A numeric operator with an unparseable value never matches.
	expect !cond_matches({ id: "n2", field: Level, op: Lt, value: "three" }, { name: "Bo", dept: "Platform", level: 2 })

	## Rows from `rows` that satisfy the tree.
	matching_rows : QNode, List(Row) -> List(Row)
	matching_rows = |tree, rows| rows.keep_if(|row| node_matches(tree, row))

	## Number of leaf conditions in the tree.
	count_conditions : QNode -> U64
	count_conditions = |node|
		match node {
			Cond(_) => 1
			Group(g) => g.children.map(count_conditions).sum()
		}

	## Number of groups in the tree, including the root.
	count_groups : QNode -> U64
	count_groups = |node|
		match node {
			Cond(_) => 0
			Group(g) => 1 + g.children.map(count_groups).sum()
		}

	## Nesting depth: the root group alone is depth 1.
	tree_depth : QNode -> U64
	tree_depth = |node|
		match node {
			Cond(_) => 0
			Group(g) => 1 + max_depth(g.children)
		}

	max_depth : List(QNode) -> U64
	max_depth = |children|
		children.map(tree_depth).fold(0, U64.max)

	map_node : QNode, Str, (QNode -> QNode) -> QNode
	map_node = |node, target, f|
		if node_id(node) == target {
			f(node)
		} else {
			match node {
				Cond(_) => node
				Group(g) => QNode.Group({ ..g, children: g.children.map(|child| map_node(child, target, f)) })
			}
		}

	map_cond : QNode, Str, (Cond -> Cond) -> QNode
	map_cond = |node, target, f|
		map_node(
			node,
			target,
			|found| match found {
				Cond(c) => QNode.Cond(f(c))
				Group(_) => found
			},
		)

	## Change the field of one leaf condition. The value arrives from a `<select>`
	## as text, so this is the decode point for `Field`.
	set_field : QNode, Str, Str -> QNode
	set_field = |tree, target, value| map_cond(tree, target, |c| { ..c, field: Field.from_str(value) })

	## Change the operator of one leaf condition; the decode point for `Op`.
	set_op : QNode, Str, Str -> QNode
	set_op = |tree, target, value| map_cond(tree, target, |c| { ..c, op: Op.from_str(value) })

	## Change the compared value of one leaf condition.
	set_value : QNode, Str, Str -> QNode
	set_value = |tree, target, value| map_cond(tree, target, |c| { ..c, value: value })

	## Switch one group between `AND` and `OR`.
	set_mode : QNode, Str, Mode -> QNode
	set_mode = |tree, target, value|
		map_node(
			tree,
			target,
			|found| match found {
				Cond(_) => found
				Group(g) => QNode.Group({ ..g, mode: value })
			},
		)

	## Set the negation flag of one group.
	set_negated : QNode, Str, Bool -> QNode
	set_negated = |tree, target, value|
		map_node(
			tree,
			target,
			|found| match found {
				Cond(_) => found
				Group(g) => QNode.Group({ ..g, negated: value })
			},
		)

	id_number : Str -> U64
	id_number = |id| U64.from_str(suffix_after(id, "n")) ?? 0

	## Prefix of `text` before the first occurrence of `sep`.
	prefix_before : Str, Str -> Str
	prefix_before = |text, sep|
		match text.split_on(sep).first() {
			Ok(value) => value
			Err(_) => text
		}

	## Suffix of `text` after the first occurrence of `sep`.
	suffix_after : Str, Str -> Str
	suffix_after = |text, sep|
		match text.split_on(sep).get(1) {
			Ok(value) => value
			Err(_) => text
		}

	highest_id : QNode -> U64
	highest_id = |node| {
		own = id_number(node_id(node))
		match node {
			Cond(_) => own
			Group(g) => g.children.fold(own, |best, child| U64.max(best, highest_id(child)))
		}
	}

	append_child : QNode, Str, QNode -> QNode
	append_child = |tree, target, child|
		map_node(
			tree,
			target,
			|found| match found {
				Cond(_) => found
				Group(g) => QNode.Group({ ..g, children: g.children.append(child) })
			},
		)

	## The highest id in the starting tree is the one on its single condition,
	## which is what a freshly added node numbers itself from.
	expect highest_id(initial_tree) == 2

	## Append a fresh `name contains ""` condition to one group. The new id is
	## derived from the tree, so no separate id counter has to be kept in sync.
	add_condition : QNode, Str -> QNode
	add_condition = |tree, target| {
		fresh = "n${(highest_id(tree) + 1).to_str()}"
		append_child(tree, target, QNode.Cond({ id: fresh, field: Name, op: Contains, value: "" }))
	}

	## Append a fresh empty `AND` group to one group.
	add_group : QNode, Str -> QNode
	add_group = |tree, target| {
		fresh = "n${(highest_id(tree) + 1).to_str()}"
		append_child(tree, target, QNode.Group({ id: fresh, mode: And, negated: False, children: [] }))
	}

	## Remove one node by id. The root is never removed.
	delete_node : QNode, Str -> QNode
	delete_node = |node, target|
		match node {
			Cond(_) => node
			Group(g) =>
				QNode.Group(
					{
						..g,
						children: g.children
						|> List.keep_if(|child| node_id(child) != target)
						|> List.map(|child| delete_node(child, target)),
					},
				)
		}

	## The active dataset: the five base rows, plus the archived row when asked.
	rows_for : Bool -> List(Row)
	rows_for = |include_archived|
		if include_archived {
			archived_rows
		} else {
			base_rows
		}

	## Names of the dataset rows the tree matches.
	matching_names : QNode, Bool -> List(Str)
	matching_names = |tree, include_archived|
		matching_rows(tree, rows_for(include_archived)).map(|row| row.name)

	## Display line for one matched row.
	row_line : Row -> Str
	row_line = |row| "${row.name} - ${row.dept} - level ${row.level.to_str()}"

	## Display line for a matched row name.
	name_line : Str, Bool -> Str
	name_line = |name, include_archived| {
		hits = rows_for(include_archived).keep_if(|row| row.name == name)
		match hits.first() {
			Ok(row) => row_line(row)
			Err(_) => name
		}
	}

	## Department and level for a matched row name, looked up in the full dataset
	## so a matched-row card can show more than a bare name.
	row_detail : Str -> Str
	row_detail = |name| {
		hits = archived_rows.keep_if(|row| row.name == name)
		match hits.first() {
			Ok(row) => "${row.dept} / level ${row.level.to_str()}"
			Err(_) => ""
		}
	}
}
