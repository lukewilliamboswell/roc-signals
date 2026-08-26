Query :: [].{
	## A row in the sample dataset the query is evaluated against.
	Row : { name : Str, dept : Str, level : U64 }

	## A single leaf condition: `field op value`.
	Cond : { id : Str, field : Str, op : Str, value : Str }

	## The recursive filter tree. A `Group` holds an ordered list of child nodes and
	## combines them with `AND` or `OR`, optionally negated. A `Cond` is a leaf.
	##
	## Semantics locked by `spec.txt`:
	## - a condition whose value is empty imposes no constraint and matches every row
	##   (rendered as `ANY` in the query text);
	## - an empty group imposes no constraint and matches every row in both `AND` and
	##   `OR` mode (rendered as `ALL`), so a negated empty group matches nothing;
	## - `>` and `<` only apply to the numeric `level` field; on a text field they
	##   match nothing.
	QNode := [
		Cond(Cond),
		Group({ id : Str, mode : Str, negated : Bool, children : List(QNode) }),
	].{
		is_eq : QNode, QNode -> Bool
		is_eq = |left, right|
			match left {
				Cond(l) => match right {
					Cond(r) => l.id == r.id and l.field == r.field and l.op == r.op and l.value == r.value
					Group(_) => False
				}
				Group(l) => match right {
					Cond(_) => False
					Group(r) =>
						l.id == r.id
						and l.mode == r.mode
						and l.negated == r.negated
						and children_eq(l.children, r.children)
				}
			}
	}

	children_eq : List(QNode), List(QNode) -> Bool
	children_eq = |left, right| {
		if left.len() != right.len() {
			False
		} else {
			var $index = 0
			var $same = True
			while $index < left.len() {
				l = list_at(left, $index)
				r = list_at(right, $index)
				if !l.is_eq(r) {
					$same = False
				} else {
					$same = $same
				}
				$index = $index + 1
			}
			$same
		}
	}

	placeholder_cond : QNode
	placeholder_cond = QNode.Cond({ id: "", field: "name", op: "eq", value: "" })

	list_at : List(QNode), U64 -> QNode
	list_at = |items, index|
		match items.get(index) {
			Ok(item) => item
			Err(_) => placeholder_cond
		}

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
				mode: "AND",
				negated: False,
				children: [QNode.Cond({ id: "n2", field: "dept", op: "eq", value: "Platform" })],
			},
		)

	## Stable list key that also encodes the node kind, so a row renderer can choose
	## its leaf or group shape without an eagerly-evaluated `Ui.when`.
	node_key : QNode -> Str
	node_key = |node|
		match node {
			Cond(c) => "cond:${c.id}"
			Group(g) => "group:${g.id}"
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

	## `AND` or `OR` for a group; `AND` for a leaf.
	group_mode : QNode -> Str
	group_mode = |node|
		match node {
			Cond(_) => "AND"
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
			Group(g) => { id: g.id, field: "name", op: "eq", value: "" }
		}

	## Human label for a field id.
	field_label : Str -> Str
	field_label = |field|
		if field == "name" {
			"Name"
		} else if field == "dept" {
			"Department"
		} else {
			"Level"
		}

	## Human label for an operator id.
	op_label : Str -> Str
	op_label = |op|
		if op == "eq" {
			"equals"
		} else if op == "ne" {
			"does not equal"
		} else if op == "contains" {
			"contains"
		} else if op == "gt" {
			"greater than"
		} else {
			"less than"
		}

	op_symbol : Str -> Str
	op_symbol = |op|
		if op == "eq" {
			"="
		} else if op == "ne" {
			"!="
		} else if op == "contains" {
			"~"
		} else if op == "gt" {
			">"
		} else {
			"<"
		}

	## One-line rendering of a single leaf condition.
	cond_summary : Cond -> Str
	cond_summary = |c|
		if c.value.is_empty() {
			"ANY"
		} else {
			"${c.field} ${op_symbol(c.op)} '${c.value}'"
		}

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
						Str.join_with(g.children.map(query_text), " ${g.mode} ")
					}
				if g.negated {
					"NOT (${inner})"
				} else {
					"(${inner})"
				}
			}
		}

	field_text : Row, Str -> Str
	field_text = |row, field|
		if field == "name" {
			row.name
		} else if field == "dept" {
			row.dept
		} else {
			row.level.to_str()
		}

	str_contains : Str, Str -> Bool
	str_contains = |haystack, needle|
		if needle.is_empty() {
			True
		} else {
			haystack.split_on(needle).len() > 1
		}

	parse_u64 : Str -> [Number(U64), NotANumber]
	parse_u64 = |text| {
		bytes = text.to_utf8()
		if bytes.is_empty() {
			NotANumber
		} else {
			var $index = 0
			var $total = 0
			var $ok = True
			while $index < bytes.len() {
				byte =
					match bytes.get($index) {
						Ok(b) => b
						Err(_) => 0
					}
				if byte >= 48 and byte <= 57 {
					$total = $total * 10 + U8.to_u64(byte) - 48
				} else {
					$ok = False
				}
				$index = $index + 1
			}
			if $ok {
				Number($total)
			} else {
				NotANumber
			}
		}
	}

	cond_matches : Cond, Row -> Bool
	cond_matches = |c, row| {
		if c.value.is_empty() {
			True
		} else {
			text = field_text(row, c.field)
			if c.op == "eq" {
				text == c.value
			} else if c.op == "ne" {
				text != c.value
			} else if c.op == "contains" {
				str_contains(text, c.value)
			} else {
				if c.field != "level" {
					False
				} else {
					match parse_u64(c.value) {
						NotANumber => False
						Number(target) =>
							if c.op == "gt" {
								row.level > target
							} else {
								row.level < target
							}
					}
				}
			}
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
						if g.mode == "AND" {
							hits == g.children.len()
						} else {
							hits > 0
						}
					}
				if g.negated {
					!base
				} else {
					base
				}
			}
		}

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
	max_depth = |children| {
		var $best = 0
		var $index = 0
		while $index < children.len() {
			depth = tree_depth(list_at(children, $index))
			if depth > $best {
				$best = depth
			} else {
				$best = $best
			}
			$index = $index + 1
		}
		$best
	}

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

	## Change the field of one leaf condition.
	set_field : QNode, Str, Str -> QNode
	set_field = |tree, target, value| map_cond(tree, target, |c| { ..c, field: value })

	## Change the operator of one leaf condition.
	set_op : QNode, Str, Str -> QNode
	set_op = |tree, target, value| map_cond(tree, target, |c| { ..c, op: value })

	## Change the compared value of one leaf condition.
	set_value : QNode, Str, Str -> QNode
	set_value = |tree, target, value| map_cond(tree, target, |c| { ..c, value: value })

	## Switch one group between `AND` and `OR`.
	set_mode : QNode, Str, Str -> QNode
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
	id_number = |id|
		match parse_u64(suffix_after(id, "n")) {
			Number(value) => value
			NotANumber => 0
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
			Group(g) => {
				var $best = own
				var $index = 0
				while $index < g.children.len() {
					child = highest_id(list_at(g.children, $index))
					if child > $best {
						$best = child
					} else {
						$best = $best
					}
					$index = $index + 1
				}
				$best
			}
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

	## Append a fresh `name contains ""` condition to one group. The new id is
	## derived from the tree, so no separate id counter has to be kept in sync.
	add_condition : QNode, Str -> QNode
	add_condition = |tree, target| {
		fresh = "n${(highest_id(tree) + 1).to_str()}"
		append_child(tree, target, QNode.Cond({ id: fresh, field: "name", op: "contains", value: "" }))
	}

	## Append a fresh empty `AND` group to one group.
	add_group : QNode, Str -> QNode
	add_group = |tree, target| {
		fresh = "n${(highest_id(tree) + 1).to_str()}"
		append_child(tree, target, QNode.Group({ id: fresh, mode: "AND", negated: False, children: [] }))
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
}
