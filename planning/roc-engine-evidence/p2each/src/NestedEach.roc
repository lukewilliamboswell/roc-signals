import Engine exposing [Elem, Root, In, Row, State, RowRef, Val]

## The 0b nested-each app on the unified engine (ported from
## p1b/api/NestedEach.roc; `Row` replaces `Site`).
NestedEach := [].{
	Item : { id : Str, name : Str, qty : U64 }

	Group : { id : Str, title : Str, items : List(Item) }

	Model : { groups : List(Group), next : U64 }

	ModelCtx : In(Root, Model)

	GroupCtx : Row(ModelCtx, Group)

	ItemCtx : Row(GroupCtx, Item)

	edit_group : Model, Str, (List(Item) -> List(Item)) -> Model
	edit_group = |model, group_id, edit| {
		{ groups, next } = model
		{ groups: groups.map(|g| if g.id == group_id { id: g.id, title: g.title, items: edit(g.items) } else g), next }
	}

	add_item : Model, Str -> Model
	add_item = |model, group_id| {
		id = "item-${model.next.to_str()}"
		next_model = NestedEach.edit_group(model, group_id, |items| items.append({ id, name: "New", qty: 1 }))
		{ groups: next_model.groups, next: model.next + 1 }
	}

	## Both keys arrive together as one context value read when the event fires.
	remove_item : Model, { group : Str, item : Str } -> Model
	remove_item = |model, { group, item }| NestedEach.edit_group(model, group, |items| items.keep_if(|i| i.id != item))

	## The state handle, the group key and the group title all cross the inner
	## row boundary with `lift_row`.
	item_view : State(GroupCtx, Model), RowRef(GroupCtx, Item), Val(GroupCtx, Str), Val(GroupCtx, Str) -> Elem(ItemCtx)
	item_view = |model, item, group_key, group_title| {
		keys = Val.map2(group_key.lift_row(), item.key(), |group, it| { group, item: it })
		Engine.element(
			"li",
			[],
			[
				Engine.text_v(item.field(|value| value.name)),
				Engine.text(" in "),
				Engine.text_v(group_title.lift_row()),
				Engine.text_v(item.field(|value| " x${value.qty.to_str()}")),
				Engine.button("Remove", model.lift_row().update_by(keys, NestedEach.remove_item)),
			],
		)
	}

	group_view : State(ModelCtx, Model), RowRef(ModelCtx, Group) -> Elem(GroupCtx)
	group_view = |model, group| {
		in_group = model.lift_row()
		Engine.element(
			"section",
			[],
			[
				Engine.element("h2", [], [Engine.text_v(group.field(|value| value.title))]),
				Engine.button("Add item", in_group.update_by(group.key(), NestedEach.add_item)),
				Engine.element("ul", [], [Engine.each(group.field(|value| value.items), |i| i.id, |item| NestedEach.item_view(in_group, item, group.key(), group.field(|value| value.title)))]),
			],
		)
	}

	main : {} -> Elem(Root)
	main = |_| {
		groups = [{ id: "g1", title: "Fruit", items: [] }, { id: "g2", title: "Tools", items: [] }]
		Engine.state(
			{ groups, next: 0 },
			|model| Engine.element("div", [], [Engine.each(model.val().map(|value| value.groups), |g| g.id, |group| NestedEach.group_view(model, group))]),
		)
	}
}
